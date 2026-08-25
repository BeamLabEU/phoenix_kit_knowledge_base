defmodule PhoenixKitKnowledgeBase.Schemas.NoteLink do
  @moduledoc """
  One `[[wiki-link]]` from a note to a title in the same vault.

  The index is rebuilt from a note's body every time it is saved
  (`PhoenixKitKnowledgeBase.Links.reindex_note/1`), so it is a cache of the
  markdown rather than a second source of truth.

  A row with `target_note_uuid` nil is an **unresolved** link: the note being
  pointed at does not exist yet. Those are kept deliberately — "what have I
  linked to but not written?" is the question that grows a vault, and it is
  what makes clicking a dangling link offer to create the note. When a note is
  later created with a matching title, every unresolved row in that vault
  pointing at it is resolved in one update; when a note is deleted, the links
  into it go back to unresolved rather than vanishing.
  """
  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  import Ecto.Changeset

  alias PhoenixKitKnowledgeBase.Schemas.{Note, Vault}

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  schema "phoenix_kit_kb_note_links" do
    # Normalised target title (matches Note.title_key). Retained even once the
    # link resolves, so a deleted target can be re-pointed later.
    field(:target_key, :string)
    # The target exactly as written inside `[[...]]`, for display.
    field(:target_title, :string)

    belongs_to(:vault, Vault, foreign_key: :vault_uuid, references: :uuid, type: UUIDv7)

    belongs_to(:source_note, Note,
      foreign_key: :source_note_uuid,
      references: :uuid,
      type: UUIDv7
    )

    belongs_to(:target_note, Note,
      foreign_key: :target_note_uuid,
      references: :uuid,
      type: UUIDv7
    )

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [
      :vault_uuid,
      :source_note_uuid,
      :target_note_uuid,
      :target_key,
      :target_title
    ])
    |> validate_required([:vault_uuid, :source_note_uuid, :target_key, :target_title])
    |> unique_constraint([:source_note_uuid, :target_key])
    |> foreign_key_constraint(:vault_uuid)
    |> foreign_key_constraint(:source_note_uuid)
    |> foreign_key_constraint(:target_note_uuid)
  end
end
