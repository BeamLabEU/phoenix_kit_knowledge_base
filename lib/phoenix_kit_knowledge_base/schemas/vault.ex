defmodule PhoenixKitKnowledgeBase.Schemas.Vault do
  @moduledoc """
  A vault — one self-contained space of notes, folders and links.

  Two scopes:

    * `"system"` — created and owned by the organisation. `owner_uuid` is nil;
      admins holding `knowledge_base.manage_system_vaults` administer them.
    * `"user"` — someone's personal vault. `owner_uuid` is the creator, and
      nobody else sees it unless they are added as a member.

  Membership (`PhoenixKitKnowledgeBase.Schemas.VaultMember`) applies to both
  scopes: it is what grants a specific person `viewer` / `editor` / `owner`
  access to a specific vault.

  `[[wiki-links]]` never cross a vault boundary — a vault is the resolution
  namespace, exactly as an Obsidian vault is.
  """
  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  import Ecto.Changeset

  alias PhoenixKitKnowledgeBase.Schemas.{Folder, Note, VaultMember}

  @type t :: %__MODULE__{}

  @scopes ~w(system user)

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  schema "phoenix_kit_kb_vaults" do
    field(:name, :string)
    field(:slug, :string)
    field(:description, :string)
    field(:icon, :string, default: "hero-book-open")
    field(:scope, :string, default: "user")
    field(:owner_uuid, UUIDv7)
    field(:created_by, UUIDv7)
    # Where this vault's files live, relative to `Storage.root/0`. Assigned
    # once at creation and never recomputed — a personal vault's path embeds a
    # slug of its owner's email, and relocating someone's notes because they
    # changed their email address would be a fine way to lose a vault.
    field(:directory, :string)
    field(:last_scanned_at, :utc_datetime_usec)
    # Set only on vaults a notes panel created: the slugified first segment of
    # its path. Not cast from params — `Places` writes it.
    field(:path_key, :string)

    has_many(:members, VaultMember, foreign_key: :vault_uuid, references: :uuid)
    has_many(:notes, Note, foreign_key: :vault_uuid, references: :uuid)
    has_many(:folders, Folder, foreign_key: :vault_uuid, references: :uuid)

    # Must match the migration's `timestamps(type: :utc_datetime_usec)` —
    # `:utc_datetime` against timestamptz(6) columns silently truncates.
    timestamps(type: :utc_datetime_usec)
  end

  @doc "The scopes a vault may have."
  @spec scopes() :: [String.t()]
  def scopes, do: @scopes

  @doc """
  Changeset for creating or renaming a vault.

  `:slug` is derived from the name when absent. `:scope` and `:owner_uuid` are
  castable but the context — not the form — decides them, because "may this
  person create a system vault?" is a permission question.
  """
  def changeset(vault, attrs) do
    vault
    |> cast(attrs, [
      :name,
      :slug,
      :description,
      :icon,
      :scope,
      :owner_uuid,
      :created_by,
      :directory,
      :last_scanned_at
    ])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 120)
    |> validate_length(:description, max: 2000)
    |> validate_inclusion(:scope, @scopes)
    |> put_slug()
    |> validate_required([:slug])
    |> validate_format(:slug, ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/,
      message: "must be lowercase letters, numbers and single hyphens"
    )
    |> validate_length(:slug, min: 1, max: 120)
    |> unique_constraint(:slug)
    # Two vaults sharing a directory would each see the other's writes as
    # external edits and fight over the index forever.
    |> unique_constraint(:directory, message: "is already used by another vault")
    |> validate_owner_matches_scope()
  end

  @doc """
  Marks a vault as the one a notes panel's path names (`Places`). Never cast:
  the key is derived from the path, not taken from a form.

  Both partial unique indexes are declared, so two people creating the same
  place's vault at once get a changeset error to recover from — not a raise.
  """
  def put_path_key(changeset, path_key) do
    changeset
    |> put_change(:path_key, path_key)
    |> unique_constraint(:path_key, name: :phoenix_kit_kb_vaults_shared_path_key_index)
    |> unique_constraint(:path_key, name: :phoenix_kit_kb_vaults_private_path_key_index)
  end

  # A system vault with an owner, or a personal vault without one, would make
  # every access check ambiguous — reject at the edge rather than defending
  # against it in five query functions.
  defp validate_owner_matches_scope(changeset) do
    case {get_field(changeset, :scope), get_field(changeset, :owner_uuid)} do
      {"system", nil} -> changeset
      {"system", _} -> add_error(changeset, :owner_uuid, "must be blank for a system vault")
      {"user", nil} -> add_error(changeset, :owner_uuid, "is required for a personal vault")
      _ -> changeset
    end
  end

  defp put_slug(changeset) do
    case {get_change(changeset, :slug), get_field(changeset, :slug)} do
      {nil, nil} -> put_change(changeset, :slug, derive_slug(changeset))
      {nil, _existing} -> changeset
      {slug, _} -> put_change(changeset, :slug, slugify(slug) || derive_slug(changeset))
    end
  end

  # A name written entirely in a script this naive transliteration drops ("日本語")
  # slugifies to nothing. Falling back to a generated slug beats rejecting the
  # vault: the slug is a URL token, not a label — the name is what people read.
  defp derive_slug(changeset) do
    case slugify(get_field(changeset, :name)) do
      nil ->
        "vault-" <>
          (4 |> :crypto.strong_rand_bytes() |> Base.encode32(case: :lower, padding: false))

      slug ->
        slug
    end
  end

  @doc """
  Turns free text into a URL-safe slug.

  Returns `nil` for input that has no slug-able characters at all (e.g. a
  name written entirely in a script this naive transliteration drops), so the
  caller's `validate_required(:slug)` reports a real error instead of the
  changeset quietly persisting `""`.
  """
  @spec slugify(String.t() | nil) :: String.t() | nil
  def slugify(nil), do: nil

  def slugify(value) when is_binary(value) do
    slug =
      value
      |> String.downcase()
      # Split accented characters into base + combining mark, then drop the
      # marks — "Café" becomes "cafe" rather than "caf".
      |> String.normalize(:nfd)
      |> String.replace(~r/[^a-z0-9\s-]/u, "")
      |> String.replace(~r/[\s-]+/u, "-")
      |> String.trim("-")

    if slug == "", do: nil, else: slug
  end
end
