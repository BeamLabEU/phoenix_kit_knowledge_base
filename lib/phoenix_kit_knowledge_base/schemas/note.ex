defmodule PhoenixKitKnowledgeBase.Schemas.Note do
  @moduledoc """
  An index row for one markdown file.

  **The file is the note.** Everything here is derived from its path and its
  bytes, and could be rebuilt by re-reading the vault directory — which is
  exactly what a rescan does. Nothing in this table is authoritative.

  ## Derived from the path

    * `:relative_path` — the note's identity, unique per vault because the
      filesystem makes it so
    * `:title` — the filename without `.md`, as in Obsidian
    * `:title_key` — normalised title, what `[[wiki-links]]` match on. **Not
      unique**: two folders may each hold an `Ideas.md`, and the index has to
      describe the disk rather than reject it
    * `:folder_path` — the directory part, `""` at the vault root

  ## Derived from the bytes

    * `:content` — a cache, so search and rendering never touch the disk
    * `:frontmatter` — parsed YAML properties, kept whole
    * `:tags` — front matter `tags:` merged with inline `#tags`
    * `:content_hash`, `:file_mtime`, `:file_size` — change detection, the
      stale-write guard, and rename detection across an external `mv`

  ## search_vector

  The table also carries a generated `tsvector` column, deliberately not mapped
  here: Postgres computes it from `title` and `content` on every write, so Ecto
  must never try to write it.
  """
  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  import Ecto.Changeset

  alias PhoenixKitKnowledgeBase.Markdown
  alias PhoenixKitKnowledgeBase.Schemas.Vault
  alias PhoenixKitKnowledgeBase.Storage

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  schema "phoenix_kit_kb_notes" do
    field(:relative_path, :string)
    field(:folder_path, :string, default: "")
    field(:title, :string)
    field(:title_key, :string)
    field(:content, :string, default: "")
    field(:frontmatter, :map, default: %{})
    field(:tags, {:array, :string}, default: [])
    field(:content_hash, :string)
    field(:file_mtime, :utc_datetime_usec)
    field(:file_size, :integer)
    field(:created_by, UUIDv7)
    field(:updated_by, UUIDv7)

    belongs_to(:vault, Vault, foreign_key: :vault_uuid, references: :uuid, type: UUIDv7)

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Changeset for indexing a file.

  Callers pass the path and the bytes read from disk; every other field is
  computed here, so there is no way to persist a row that disagrees with the
  file it describes.
  """
  def changeset(note, attrs) do
    note
    |> cast(attrs, [
      :vault_uuid,
      :relative_path,
      :content,
      :content_hash,
      :file_mtime,
      :file_size,
      :created_by,
      :updated_by
    ])
    |> validate_required([:vault_uuid, :relative_path])
    # Bytes, not characters: the unique `(vault_uuid, relative_path)` index has
    # a ceiling of about 2.7 KB per entry, and 1,000 CJK characters are 3,000
    # bytes. Over it, the insert raises instead of returning this error.
    |> validate_length(:relative_path, min: 1, max: 2000, count: :bytes)
    |> validate_path()
    |> validate_text()
    |> put_path_derived()
    |> put_content_derived()
    |> validate_required([:title, :title_key])
    |> unique_constraint([:vault_uuid, :relative_path],
      message: "a note already exists at this path"
    )
    |> foreign_key_constraint(:vault_uuid)
  end

  defp validate_path(changeset) do
    case get_field(changeset, :relative_path) do
      nil ->
        changeset

      path ->
        cond do
          Storage.safe_relative(path) == :error ->
            add_error(changeset, :relative_path, "is not a valid path")

          not String.ends_with?(String.downcase(path), Storage.extension()) ->
            add_error(changeset, :relative_path, "must be a #{Storage.extension()} file")

          Storage.title_from_path(path) == "" ->
            add_error(changeset, :relative_path, "has no filename")

          true ->
            changeset
        end
    end
  end

  # Postgres refuses a `text` value holding invalid UTF-8 or a NUL byte, and
  # refuses it by raising. A file may hold either, so it is asked here, where
  # the answer is an error the rescan can report against the file — and before
  # `put_content_derived/1`, whose regexes raise on invalid UTF-8 too.
  defp validate_text(changeset) do
    case get_change(changeset, :content) do
      content when is_binary(content) ->
        if Storage.text?(content),
          do: changeset,
          else: add_error(changeset, :content, "is not UTF-8 text (binary data or a NUL byte)")

      _ ->
        changeset
    end
  end

  defp put_path_derived(changeset) do
    case get_field(changeset, :relative_path) do
      nil ->
        changeset

      path ->
        title = Storage.title_from_path(path)

        changeset
        |> put_change(:title, title)
        |> put_change(:title_key, Markdown.normalize_title(title))
        |> put_change(:folder_path, Storage.folder_from_path(path))
    end
  end

  # Only re-parse when the bytes actually changed. A move rewrites the path but
  # not the content, and re-deriving front matter from a `content` that was
  # never loaded would wipe it.
  defp put_content_derived(changeset) do
    case get_change(changeset, :content) do
      nil ->
        changeset

      content ->
        if Keyword.has_key?(changeset.errors, :content),
          # Unreadable bytes: nothing to derive, and the regexes would raise.
          do: changeset,
          else: put_derived_from(changeset, content)
    end
  end

  defp put_derived_from(changeset, content) do
    {frontmatter, body} = Markdown.split_frontmatter(content)

    changeset
    |> put_change(:frontmatter, frontmatter)
    |> put_change(:tags, Markdown.extract_tags(frontmatter, body))
  end

  @doc """
  The canonical form of a title, used for link resolution.

  Delegates to `PhoenixKitKnowledgeBase.Markdown.normalize_title/1` so indexing
  and `[[wiki-link]]` resolution can never normalise differently.
  """
  @spec normalize_title(String.t() | nil) :: String.t() | nil
  defdelegate normalize_title(title), to: Markdown
end
