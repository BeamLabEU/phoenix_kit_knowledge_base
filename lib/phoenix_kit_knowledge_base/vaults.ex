defmodule PhoenixKitKnowledgeBase.Vaults do
  @moduledoc """
  Vault CRUD, membership, and the access model the whole module funnels through.

  ## Who can see what

  Reaching any knowledge-base page at all requires the `knowledge_base`
  permission — that is core's job, enforced by the admin tab. What this module
  decides is which *vaults* you then see, and what you may do inside each one.

  Access resolves to one of four values, computed by `role_for/2`:

  | Role | May |
  |---|---|
  | `"owner"`  | everything, including membership and deleting the vault |
  | `"editor"` | create, edit, move and delete notes and folders |
  | `"viewer"` | read |
  | `nil`      | not see the vault exists |

  Two roles are implicit, held without a membership row:

    * a personal vault's `owner_uuid` is always its `"owner"` — so a vault can
      never end up with nobody able to administer it;
    * anyone holding `knowledge_base.manage_system_vaults` (and any org Owner)
      is `"owner"` of every **system** vault.

  That second rule stops at system vaults on purpose. An admin does not get
  implicit access to other people's *personal* vaults: a private notebook that
  silently isn't private is worse than no private notebook. To read someone's
  personal vault, they add you as a member.
  """

  # `except: [update: 2, update: 3]` — this module exposes its own `update/2`
  # for vaults, and the imported query macro would shadow it.
  import Ecto.Query, except: [update: 2, update: 3]

  use Gettext, backend: PhoenixKitKnowledgeBase.Gettext

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitKnowledgeBase.Schemas.{Vault, VaultMember}
  alias PhoenixKitKnowledgeBase.Storage

  @manage_system_key "knowledge_base.manage_system_vaults"

  @roles_by_power %{"owner" => 3, "editor" => 2, "viewer" => 1}

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @doc "The sub-permission key that confers ownership of every system vault."
  @spec manage_system_permission() :: String.t()
  def manage_system_permission, do: @manage_system_key

  # ── Access ────────────────────────────────────────────────────────────────

  @doc """
  The role `scope`'s user holds on `vault`, or `nil` if they cannot see it.

  Takes the highest of the implicit roles and any membership row, so being
  added as a `viewer` of a system vault you already administer does not
  *reduce* your access.
  """
  @spec role_for(Vault.t(), Scope.t() | nil) :: String.t() | nil
  def role_for(%Vault{} = vault, scope) do
    case user_uuid(scope) do
      nil ->
        nil

      user_uuid ->
        highest_role([implicit_role(vault, scope, user_uuid), member_role(vault, user_uuid)])
    end
  end

  @doc """
  Whether a role permits an action.

    * `:read`   — viewer and up
    * `:write`  — editor and up (notes, folders)
    * `:manage` — owner only (membership, vault settings, deletion)
  """
  @spec can?(String.t() | nil, :read | :write | :manage) :: boolean()
  def can?(nil, _action), do: false
  def can?(role, :read), do: Map.has_key?(@roles_by_power, role)
  def can?(role, :write), do: Map.get(@roles_by_power, role, 0) >= 2
  def can?(role, :manage), do: Map.get(@roles_by_power, role, 0) >= 3

  @doc """
  Whether this user may create system vaults (as opposed to personal ones).
  """
  @spec can_manage_system_vaults?(Scope.t() | nil) :: boolean()
  def can_manage_system_vaults?(nil), do: false

  def can_manage_system_vaults?(scope) do
    Scope.can?(scope, @manage_system_key) or Scope.superadmin?(scope) or Scope.owner?(scope)
  end

  # ── Reads ─────────────────────────────────────────────────────────────────

  @doc """
  Every vault this user may open, system vaults first, then alphabetical.

  Runs as one query rather than a filter over all vaults, so a host with many
  personal vaults doesn't load them all to throw most away.
  """
  @spec list_visible(Scope.t() | nil) :: [Vault.t()]
  def list_visible(scope) do
    case user_uuid(scope) do
      nil ->
        []

      user_uuid ->
        member_vault_uuids =
          from(m in VaultMember, where: m.user_uuid == ^user_uuid, select: m.vault_uuid)

        base =
          from(v in Vault,
            where: v.owner_uuid == ^user_uuid or v.uuid in subquery(member_vault_uuids),
            order_by: [asc: v.scope, asc: v.name]
          )

        query =
          if can_manage_system_vaults?(scope) do
            from(v in base, or_where: v.scope == "system")
          else
            base
          end

        repo().all(query)
    end
  end

  @doc """
  `list_visible/1` with each vault's role resolved, as `{vault, role}`.

  One membership query for the whole list rather than `role_for/2` per vault —
  the list page would otherwise issue a query per card.
  """
  @spec list_visible_with_roles(Scope.t() | nil) :: [{Vault.t(), String.t()}]
  def list_visible_with_roles(scope) do
    case user_uuid(scope) do
      nil ->
        []

      user_uuid ->
        vaults = list_visible(scope)

        member_roles =
          from(m in VaultMember,
            where: m.user_uuid == ^user_uuid,
            select: {m.vault_uuid, m.role}
          )
          |> repo().all()
          |> Map.new()

        Enum.map(vaults, fn vault ->
          role =
            highest_role([
              implicit_role(vault, scope, user_uuid),
              Map.get(member_roles, vault.uuid)
            ])

          {vault, role}
        end)
    end
  end

  @doc "Fetch a vault by its URL slug, or `nil`."
  @spec get_by_slug(String.t()) :: Vault.t() | nil
  def get_by_slug(slug) when is_binary(slug), do: repo().get_by(Vault, slug: slug)

  @doc "Fetch a vault by uuid, or `nil`. Returns `nil` for a malformed uuid rather than raising."
  @spec get(String.t()) :: Vault.t() | nil
  def get(uuid) when is_binary(uuid) do
    repo().get(Vault, uuid)
  rescue
    Ecto.Query.CastError -> nil
  end

  @doc """
  Fetch a vault for a user, resolving their role in the same step.

  `{:error, :not_found}` covers both "no such slug" and "you may not see it" —
  telling those apart would leak the existence of other people's vaults.
  """
  @spec fetch_for(String.t(), Scope.t() | nil) ::
          {:ok, Vault.t(), String.t()} | {:error, :not_found}
  def fetch_for(slug, scope) do
    with %Vault{} = vault <- get_by_slug(slug),
         role when not is_nil(role) <- role_for(vault, scope) do
      {:ok, vault, role}
    else
      _ -> {:error, :not_found}
    end
  end

  # ── Writes ────────────────────────────────────────────────────────────────

  @doc """
  Create a vault owned by this user.

  `scope_kind` is `:user` for a personal vault or `:system` for an org-wide
  one; `:system` is rejected without `knowledge_base.manage_system_vaults`,
  here rather than only in the UI, so the check can't be skipped by a crafted
  form submission.
  """
  # `{:error, term()}`: the vault's directory is made before the row, and a
  # filesystem refusal (`Storage.ensure_vault/1`) comes back as it is. The
  # narrower spec this had told dialyzer that callers' fallback clauses were
  # dead, and deleting one would have turned a disk error into a crash.
  @spec create(map(), Scope.t() | nil, :user | :system) ::
          {:ok, Vault.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :unauthorized}
          | {:error, term()}
  def create(attrs, scope, scope_kind \\ :user)

  def create(attrs, scope, :system) do
    if can_manage_system_vaults?(scope) do
      attrs
      |> normalize()
      |> Map.merge(%{"scope" => "system", "owner_uuid" => nil, "created_by" => user_uuid(scope)})
      |> insert_vault(:system, nil)
    else
      {:error, :unauthorized}
    end
  end

  def create(attrs, scope, :user) do
    case user_uuid(scope) do
      nil ->
        {:error, :unauthorized}

      user_uuid ->
        attrs
        |> normalize()
        |> Map.merge(%{
          "scope" => "user",
          "owner_uuid" => user_uuid,
          "created_by" => user_uuid
        })
        |> insert_vault(:user, owner_email(scope))
    end
  end

  @doc false
  # `Places`' door. Whether this person may create the vault is the notes
  # panel's question — its `:authorize` hook, already asked — not the admin
  # permission `create/3` checks for a system vault.
  @spec create_for_place(map(), :user | :system, String.t() | nil, String.t()) ::
          {:ok, Vault.t()} | {:error, Ecto.Changeset.t()} | {:error, term()}
  def create_for_place(attrs, kind, owner_email, path_key) do
    attrs
    |> normalize()
    |> insert_vault(kind, owner_email, &Vault.put_path_key(&1, path_key))
  end

  @doc "Update a vault's name, slug, description or icon. Scope and owner are fixed at creation."
  @spec update(Vault.t(), map()) :: {:ok, Vault.t()} | {:error, Ecto.Changeset.t()}
  def update(%Vault{} = vault, attrs) do
    # `directory` is immutable: changing it would orphan every file the vault
    # already has. Moving a vault means moving it on disk and rescanning.
    attrs =
      attrs |> normalize() |> Map.drop(["scope", "owner_uuid", "created_by", "directory"])

    vault
    |> Vault.changeset(attrs)
    |> repo().update()
    |> retry_on_slug_conflict(fn attrs -> update(vault, attrs) end, attrs)
  end

  @doc """
  Remove a vault from the app.

  Deletes the vault row and, by FK cascade, its members and its whole index —
  but **not the files**. Notes are the durable artifact here; a mis-click in a
  web UI should not be able to `rm -rf` somebody's writing. The directory stays
  on disk, and re-creating a vault with the same slug and pressing Rescan brings
  every note back.
  """
  @spec delete(Vault.t()) :: {:ok, Vault.t()} | {:error, Ecto.Changeset.t()}
  def delete(%Vault{} = vault), do: repo().delete(vault)

  @doc "Absolute path to a vault's directory, for showing the operator where its files are."
  @spec absolute_path(Vault.t()) :: String.t()
  def absolute_path(%Vault{directory: directory}), do: Storage.vault_path(directory)

  @doc "A blank changeset for the create/edit form."
  @spec change(Vault.t(), map()) :: Ecto.Changeset.t()
  def change(%Vault{} = vault \\ %Vault{}, attrs \\ %{}) do
    Vault.changeset(vault, normalize(attrs))
  end

  # ── Membership ────────────────────────────────────────────────────────────

  @doc """
  Members of a vault with their user records, owners first.

  The user is loaded by a join rather than a preload because
  `PhoenixKit.Users.Auth.User` belongs to core: joining on `uuid` uses the
  documented schema contract without this module declaring an association into
  another package's schema.
  """
  @spec list_members(Vault.t()) :: [%{member: VaultMember.t(), user: map() | nil}]
  def list_members(%Vault{uuid: vault_uuid}) do
    members =
      repo().all(
        from(m in VaultMember,
          where: m.vault_uuid == ^vault_uuid,
          order_by: [asc: fragment("array_position(ARRAY['owner','editor','viewer'], ?)", m.role)]
        )
      )

    users_by_uuid = users_by_uuid(Enum.map(members, & &1.user_uuid))

    Enum.map(members, fn member ->
      %{member: member, user: Map.get(users_by_uuid, member.user_uuid)}
    end)
  end

  @doc "Add a user to a vault, or change their role if already a member."
  @spec put_member(Vault.t(), String.t(), String.t()) ::
          {:ok, VaultMember.t()} | {:error, Ecto.Changeset.t()}
  def put_member(%Vault{uuid: vault_uuid}, user_uuid, role) do
    attrs = %{"vault_uuid" => vault_uuid, "user_uuid" => user_uuid, "role" => role}

    case repo().get_by(VaultMember, vault_uuid: vault_uuid, user_uuid: user_uuid) do
      nil -> %VaultMember{} |> VaultMember.changeset(attrs) |> repo().insert()
      existing -> existing |> VaultMember.changeset(attrs) |> repo().update()
    end
  end

  @doc "Remove a membership row. The implicit owner of a personal vault is unaffected."
  @spec remove_member(VaultMember.t()) :: {:ok, VaultMember.t()} | {:error, Ecto.Changeset.t()}
  def remove_member(%VaultMember{} = member), do: repo().delete(member)

  @doc "Fetch a membership row scoped to its vault, or `nil`."
  @spec get_member(Vault.t(), String.t()) :: VaultMember.t() | nil
  def get_member(%Vault{uuid: vault_uuid}, member_uuid) do
    repo().get_by(VaultMember, uuid: member_uuid, vault_uuid: vault_uuid)
  rescue
    Ecto.Query.CastError -> nil
  end

  @doc """
  Users matching `term` who are not already members, for the "add member"
  picker. Delegates the search to core so it stays consistent with the rest of
  the admin.
  """
  @spec search_candidates(Vault.t(), String.t()) :: [map()]
  def search_candidates(%Vault{} = vault, term) do
    existing =
      vault
      |> list_members()
      |> Enum.map(& &1.member.user_uuid)
      |> MapSet.new()
      |> then(fn set ->
        if vault.owner_uuid, do: MapSet.put(set, vault.owner_uuid), else: set
      end)

    term
    |> Auth.search_users()
    |> Enum.reject(&MapSet.member?(existing, &1.uuid))
  end

  @doc "A display label for a user record from `search_candidates/2` or `list_members/1`."
  @spec user_label(map() | nil) :: String.t()
  def user_label(nil), do: gettext("Unknown user")

  def user_label(user) do
    name =
      [Map.get(user, :first_name), Map.get(user, :last_name)]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" ")

    case name do
      "" -> Map.get(user, :username) || Map.get(user, :email) || gettext("Unknown user")
      name -> name
    end
  end

  @doc "A role, for showing — the stored value stays English (`owner` / `editor` / `viewer`)."
  @spec role_label(String.t() | nil) :: String.t()
  def role_label("owner"), do: gettext("owner")
  def role_label("editor"), do: gettext("editor")
  def role_label("viewer"), do: gettext("viewer")
  def role_label(other), do: to_string(other)

  # ── internals ─────────────────────────────────────────────────────────────

  # The directory is derived from the slug the changeset settled on, so a slug
  # that had to be uniquified carries its directory with it. The directory is
  # created before the row is inserted: a vault row pointing at a directory that
  # does not exist would fail on the first read, whereas a directory with no
  # vault row is inert and gets adopted if the vault is created again.
  defp insert_vault(attrs, kind, owner_email, decorate \\ & &1) do
    changeset = Vault.changeset(%Vault{}, attrs)
    slug = Ecto.Changeset.get_field(changeset, :slug)

    with {:ok, attrs} <- put_directory(attrs, kind, owner_email, slug),
         :ok <- ensure_directory(attrs),
         changeset <- %Vault{} |> Vault.changeset(attrs) |> decorate.(),
         {:ok, vault} <- repo().insert(changeset) do
      {:ok, vault}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        retry_on_slug_conflict(
          {:error, changeset},
          &insert_vault(&1, kind, owner_email, decorate),
          attrs
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  # No slug means no directory to build, and the changeset is about to reject the
  # vault for exactly that. Let it, rather than failing here with a path error
  # that says nothing about the missing name.
  defp ensure_directory(%{"directory" => directory}) when is_binary(directory) do
    Storage.ensure_vault(directory)
  end

  defp ensure_directory(_attrs), do: :ok

  defp put_directory(attrs, _kind, _owner_email, nil), do: {:ok, attrs}

  defp put_directory(attrs, kind, owner_email, slug) do
    {:ok, Map.put(attrs, "directory", Storage.build_directory(kind, slug, owner_email))}
  end

  # Two vaults named "Research" produce the same slug. Rather than making the
  # user invent a unique one, append a short suffix and try again — but only
  # once, so a genuinely broken slug can't loop.
  defp retry_on_slug_conflict({:error, changeset}, retry, attrs) do
    slug_taken? =
      Enum.any?(changeset.errors, fn
        {:slug, {_msg, opts}} -> opts[:constraint] == :unique
        _ -> false
      end)

    if slug_taken? and not Map.has_key?(attrs, "__slug_retried__") do
      base = Ecto.Changeset.get_field(changeset, :slug)

      attrs
      |> Map.put("slug", "#{base}-#{unique_suffix()}")
      # Drop the stale directory too — it was derived from the taken slug, and
      # keeping it would trade a slug collision for a directory collision.
      |> Map.delete("directory")
      |> Map.put("__slug_retried__", true)
      |> retry.()
    else
      {:error, changeset}
    end
  end

  defp retry_on_slug_conflict(result, _retry, _attrs), do: result

  defp unique_suffix do
    4 |> :crypto.strong_rand_bytes() |> Base.encode32(case: :lower, padding: false)
  end

  defp implicit_role(%Vault{scope: "user", owner_uuid: owner_uuid}, _scope, user_uuid)
       when not is_nil(owner_uuid) do
    if owner_uuid == user_uuid, do: "owner", else: nil
  end

  defp implicit_role(%Vault{scope: "system"}, scope, _user_uuid) do
    if can_manage_system_vaults?(scope), do: "owner", else: nil
  end

  defp implicit_role(_vault, _scope, _user_uuid), do: nil

  defp member_role(%Vault{uuid: vault_uuid}, user_uuid) do
    repo().one(
      from(m in VaultMember,
        where: m.vault_uuid == ^vault_uuid and m.user_uuid == ^user_uuid,
        select: m.role
      )
    )
  end

  defp highest_role(roles) do
    roles
    |> Enum.reject(&is_nil/1)
    |> Enum.max_by(&Map.get(@roles_by_power, &1, 0), fn -> nil end)
  end

  defp users_by_uuid([]), do: %{}

  defp users_by_uuid(uuids) do
    from(u in Auth.User,
      where: u.uuid in ^uuids,
      select: %{
        uuid: u.uuid,
        email: u.email,
        username: u.username,
        first_name: u.first_name,
        last_name: u.last_name
      }
    )
    |> repo().all()
    |> Map.new(&{&1.uuid, &1})
  end

  defp user_uuid(%Scope{user: %{uuid: uuid}}), do: uuid
  defp user_uuid(_), do: nil

  defp owner_email(%Scope{user: %{email: email}}), do: email
  defp owner_email(_), do: nil

  # Accept both atom-keyed maps (internal callers) and string-keyed ones (form
  # params). Mixing the two in one changeset raises, so normalise at the edge.
  defp normalize(attrs) when is_map(attrs) do
    Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
  end
end
