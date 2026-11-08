defmodule PhoenixKitKnowledgeBase.Places do
  @moduledoc """
  Where a drop-in notes panel's notes live.

  A panel is given a **path** — `["CRM", "Clients", "Acme"]`. The first segment
  names the vault, the rest the folder chain inside it, and the panel shows that
  folder and everything under it. Nothing exists until it is needed: the first
  note or folder creates the vault and the chain (`ensure/2`).

  Two kinds of place share a path:

    * `:shared` ("everyone here") — an **organisation vault** of that name, so
      the admin pages, its managers and its members work on it as on any other.
      Who may use it through a panel is the host's call: the `:authorize` hook.
    * `:private` ("only me") — the person's own **personal vault** of that
      name. Only they can reach it; the hook is not asked and cannot widen it.

  A vault is found by `path_key` (the slugified first segment), which only a
  vault created here carries — an organisation vault that merely happens to be
  called "CRM" is not adopted. Names are not unique and slugs are unique across
  everyone's vaults, so neither could say which vault a path means.

  Notes are kept by path: a path built from something that changes (a client's
  name) points at a new, empty folder after the change, and the old notes stay
  where they were. Hosts should put something stable in the path.

  ## Access

      config :phoenix_kit_knowledge_base, :authorize, {MyApp.Notes, :can?}

  `can?(action, user, path)`, with `action` `:view` or `:edit` and `path` the
  panel's path, is asked about shared places only. Unconfigured, any signed-in
  user may use a shared place, as with boards. A hook that raises, throws, exits
  or answers anything but a boolean is a **no** — logged without its arguments.
  It grants access through a panel, under its path; the admin pages keep their
  own rules.
  """

  import Ecto.Query, except: [update: 2, update: 3]

  require Logger

  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitKnowledgeBase.{Notes, Storage, Vaults}
  alias PhoenixKitKnowledgeBase.Schemas.Vault

  @type visibility :: :shared | :private
  @type action :: :view | :edit

  @typedoc "A parsed panel path. `folder` is `\"\"` for the vault root."
  @type t :: %__MODULE__{
          path: [String.t()],
          vault_name: String.t(),
          folder: String.t(),
          key: String.t(),
          visibility: visibility()
        }

  @enforce_keys [:path, :vault_name, :folder, :key, :visibility]
  defstruct @enforce_keys

  @visibilities [:shared, :private]

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @doc """
  Validates a panel's path and visibility.

  Every segment must be usable as a file or directory name (`Storage.validate_filename/1`):
  a segment is user-visible text *and* a directory on disk. An invalid one is a
  developer error, reported, never written.
  """
  @spec parse(term(), term()) :: {:ok, t()} | {:error, term()}
  def parse(path, visibility) when visibility in @visibilities and is_list(path) and path != [] do
    with {:ok, segments} <- validate_segments(path),
         [vault_name | folders] = segments,
         {:ok, key} <- key_for(vault_name) do
      {:ok,
       %__MODULE__{
         path: segments,
         vault_name: vault_name,
         folder: Enum.join(folders, "/"),
         key: key,
         visibility: visibility
       }}
    end
  end

  def parse(path, visibility) when visibility in @visibilities,
    do: {:error, {:invalid_path, path}}

  def parse(_path, visibility), do: {:error, {:invalid_visibility, visibility}}

  defp validate_segments(path) do
    Enum.reduce_while(path, {:ok, []}, fn segment, {:ok, acc} ->
      case Storage.validate_filename(segment_string(segment)) do
        {:ok, name} -> {:cont, {:ok, [name | acc]}}
        {:error, reason} -> {:halt, {:error, {:invalid_segment, segment, reason}}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  # Ids are often integers or atoms; a host should not have to stringify them.
  defp segment_string(segment) when is_binary(segment), do: segment
  defp segment_string(segment) when is_integer(segment), do: Integer.to_string(segment)

  defp segment_string(segment)
       when is_atom(segment) and not is_nil(segment) and not is_boolean(segment),
       do: Atom.to_string(segment)

  defp segment_string(_segment), do: nil

  # A name with no slug-able characters ("日本語") still needs a key; hashing it
  # keeps two such names apart, where a shared fallback would merge them.
  defp key_for(vault_name) do
    case Vault.slugify(vault_name) do
      nil ->
        {:ok,
         "p-" <>
           (:crypto.hash(:sha256, vault_name)
            |> Base.encode16(case: :lower)
            |> binary_part(0, 16))}

      key ->
        {:ok, key}
    end
  end

  @doc """
  The vault a place lives in, if it has been created. No side effects — this is
  what a panel shows before anyone has written anything.
  """
  @spec locate(t(), User.t() | nil) :: Vault.t() | nil
  def locate(%__MODULE__{}, nil), do: nil

  def locate(%__MODULE__{visibility: :shared, key: key}, _user) do
    repo().one(from(v in Vault, where: v.scope == "system" and v.path_key == ^key))
  end

  def locate(%__MODULE__{visibility: :private, key: key}, %{uuid: user_uuid}) do
    repo().one(
      from(v in Vault,
        where: v.scope == "user" and v.owner_uuid == ^user_uuid and v.path_key == ^key
      )
    )
  end

  @doc """
  The place's vault and folder chain, created as needed. Asks `authorize/3` for
  `:edit` first.

  Two people writing the first note at once both reach the insert; the second
  loses on the unique index, re-reads, and uses the first one's vault.
  """
  @spec ensure(t(), User.t() | nil) :: {:ok, Vault.t()} | {:error, term()}
  def ensure(%__MODULE__{} = place, user) do
    with true <- authorize(:edit, user, place) || {:error, :unauthorized},
         {:ok, vault} <- locate_or_create(place, user),
         :ok <- ensure_folder(vault, place.folder) do
      {:ok, vault}
    end
  end

  defp locate_or_create(place, user) do
    case locate(place, user) do
      %Vault{} = vault -> {:ok, vault}
      nil -> create(place, user)
    end
  end

  defp create(%__MODULE__{visibility: :shared} = place, user) do
    %{
      "name" => place.vault_name,
      "scope" => "system",
      "owner_uuid" => nil,
      "created_by" => user.uuid
    }
    |> Vaults.create_for_place(:system, nil, place.key)
    |> settle_race(place, user)
  end

  defp create(%__MODULE__{visibility: :private} = place, user) do
    %{
      "name" => place.vault_name,
      "scope" => "user",
      "owner_uuid" => user.uuid,
      "created_by" => user.uuid
    }
    |> Vaults.create_for_place(:user, user.email, place.key)
    |> settle_race(place, user)
  end

  defp settle_race({:ok, vault}, _place, _user), do: {:ok, vault}

  defp settle_race({:error, %Ecto.Changeset{} = changeset} = error, place, user) do
    if path_key_taken?(changeset) do
      case locate(place, user) do
        %Vault{} = winner ->
          remove_unused_directory(changeset, winner)
          {:ok, winner}

        nil ->
          error
      end
    else
      error
    end
  end

  defp settle_race(error, _place, _user), do: error

  defp path_key_taken?(changeset) do
    Enum.any?(changeset.errors, fn
      {:path_key, {_message, opts}} -> opts[:constraint] == :unique
      _ -> false
    end)
  end

  # The losing insert made its directory before the database refused it. When
  # that is not the winner's own directory, it is an empty leftover: `rmdir`
  # removes it only while it is empty, so nothing that holds a file can go.
  defp remove_unused_directory(changeset, %Vault{directory: winner_directory}) do
    case Ecto.Changeset.get_field(changeset, :directory) do
      directory when is_binary(directory) and directory != winner_directory ->
        _ = File.rmdir(Storage.vault_path(directory))
        :ok

      _ ->
        :ok
    end
  end

  defp ensure_folder(_vault, ""), do: :ok

  defp ensure_folder(vault, folder) do
    parent = Path.dirname(folder)
    parent = if parent == ".", do: "", else: parent

    case Notes.create_folder(vault, parent, Path.basename(folder)) do
      {:ok, _folder} -> :ok
      {:error, reason} -> {:error, {:folder, reason}}
    end
  end

  @doc """
  Whether `user` may `action` (`:view` / `:edit`) the place. See "Access".
  """
  @spec authorize(action(), User.t() | nil, t()) :: boolean()
  def authorize(_action, nil, _place), do: false
  def authorize(_action, _user, %__MODULE__{visibility: :private}), do: true

  def authorize(action, user, %__MODULE__{visibility: :shared, path: path}) do
    case Application.get_env(:phoenix_kit_knowledge_base, :authorize) do
      nil -> true
      {module, function} -> ask_host(module, function, action, user, path)
      other -> refuse("is not {module, function}: #{inspect(other)}")
    end
  end

  defp ask_host(module, function, action, user, path) do
    case apply(module, function, [action, user, path]) do
      answer when is_boolean(answer) -> answer
      _other -> refuse("answered something other than true or false")
    end
  rescue
    error -> refuse("raised #{inspect(error.__struct__)}")
  catch
    kind, _reason -> refuse("failed (#{kind})")
  end

  # The arguments stay out of the log: they carry the user and the path, which
  # may name a client.
  defp refuse(why) do
    Logger.warning("[PhoenixKitKnowledgeBase] the :authorize hook #{why}; access refused")
    false
  end

  @doc """
  Whether `relative_path` (a note's folder or a folder) sits inside the place's
  folder — the fence every panel event checks, so a crafted event cannot reach
  the rest of the vault.
  """
  #
  # A path with an empty, `.` or `..` segment is refused outright: the check is a
  # string prefix, and `Clients/Acme/../Other` starts with `Clients/Acme`.
  @spec within?(t(), String.t() | nil) :: boolean()
  def within?(%__MODULE__{folder: folder}, relative_path) when is_binary(relative_path) do
    clean?(relative_path) and
      (folder == "" or relative_path == folder or
         String.starts_with?(relative_path, folder <> "/"))
  end

  def within?(_place, _relative_path), do: false

  defp clean?(""), do: true

  defp clean?(relative_path) do
    relative_path
    |> String.split("/")
    |> Enum.all?(&(&1 not in ["", ".", ".."]))
  end
end
