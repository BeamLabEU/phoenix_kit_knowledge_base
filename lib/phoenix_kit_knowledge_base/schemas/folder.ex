defmodule PhoenixKitKnowledgeBase.Schemas.Folder do
  @moduledoc """
  An index row for a directory inside a vault.

  There is no `parent_uuid`. The filesystem already expresses the hierarchy, and
  a second representation in the database is a second thing that can disagree
  with the disk — so the tree is rebuilt from `relative_path` when the sidebar
  needs it (`PhoenixKitKnowledgeBase.Notes.folder_tree/1`).

  Folders play no part in `[[wiki-link]]` resolution, which matches on title
  across the vault and only consults paths to break a tie.
  """
  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  import Ecto.Changeset

  alias PhoenixKitKnowledgeBase.Schemas.Vault
  alias PhoenixKitKnowledgeBase.Storage

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  schema "phoenix_kit_kb_folders" do
    field(:relative_path, :string)
    field(:name, :string)

    belongs_to(:vault, Vault, foreign_key: :vault_uuid, references: :uuid, type: UUIDv7)

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Changeset for an indexed directory.

  `:name` is derived from the path rather than accepted separately — they can
  only ever disagree by mistake.
  """
  def changeset(folder, attrs) do
    folder
    |> cast(attrs, [:vault_uuid, :relative_path])
    |> validate_required([:vault_uuid, :relative_path])
    |> validate_length(:relative_path, min: 1, max: 1000)
    |> validate_safe_path()
    |> put_name()
    |> unique_constraint([:vault_uuid, :relative_path], message: "is already indexed")
    |> foreign_key_constraint(:vault_uuid)
  end

  # The path is validated again here even though Storage refuses to act on an
  # unsafe one: a row that Storage would reject is a row nothing can ever read,
  # so it should not reach the table in the first place.
  defp validate_safe_path(changeset) do
    case get_field(changeset, :relative_path) do
      nil ->
        changeset

      path ->
        case Storage.safe_relative(path) do
          {:ok, ""} -> add_error(changeset, :relative_path, "cannot be the vault root")
          {:ok, _} -> changeset
          :error -> add_error(changeset, :relative_path, "is not a valid path")
        end
    end
  end

  defp put_name(changeset) do
    case get_field(changeset, :relative_path) do
      nil -> changeset
      path -> put_change(changeset, :name, Path.basename(path))
    end
  end
end
