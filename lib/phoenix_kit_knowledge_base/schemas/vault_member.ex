defmodule PhoenixKitKnowledgeBase.Schemas.VaultMember do
  @moduledoc """
  One person's access to one vault.

  Roles, most to least capable:

    * `"owner"`  — everything, including managing members and deleting the vault
    * `"editor"` — create, edit and delete notes and folders
    * `"viewer"` — read only

  A personal vault's `owner_uuid` is granted `"owner"` implicitly, without a row
  here (see `PhoenixKitKnowledgeBase.Vaults.role_for/2`), so a vault can never
  end up with nobody able to administer it.
  """
  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  import Ecto.Changeset

  alias PhoenixKitKnowledgeBase.Schemas.Vault

  @type t :: %__MODULE__{}

  @roles ~w(owner editor viewer)

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  schema "phoenix_kit_kb_vault_members" do
    field(:user_uuid, UUIDv7)
    field(:role, :string, default: "viewer")

    belongs_to(:vault, Vault, foreign_key: :vault_uuid, references: :uuid, type: UUIDv7)

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The roles a member may hold, most capable first."
  @spec roles() :: [String.t()]
  def roles, do: @roles

  def changeset(member, attrs) do
    member
    |> cast(attrs, [:vault_uuid, :user_uuid, :role])
    |> validate_required([:vault_uuid, :user_uuid, :role])
    |> validate_inclusion(:role, @roles)
    |> unique_constraint([:vault_uuid, :user_uuid],
      message: "is already a member of this vault"
    )
    |> foreign_key_constraint(:user_uuid, message: "is not a known user")
    |> foreign_key_constraint(:vault_uuid)
  end
end
