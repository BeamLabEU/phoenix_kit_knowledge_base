defmodule PhoenixKitKnowledgeBase.Notes do
  @moduledoc """
  Notes and folders, where **the filesystem is the source of truth** and this
  table is an index of it.

  Every write goes to disk first and is then indexed from what actually landed —
  never from what the caller intended. If the write succeeds and the indexing
  fails, the note still exists and the next rescan picks it up; if the write
  fails, nothing is indexed. The disk is never the thing that ends up wrong.

  ## The stale-write guard

  Without a file watcher, the real hazard is the web UI overwriting an edit made
  in `vim` (or Obsidian, or a script) since the page was loaded. Before every
  write, the file's current hash is compared with the indexed one; if they
  differ, the save is refused with `{:error, :stale}` and the caller is told to
  rescan. That is the difference between "eventually consistent" and "silently
  loses work".

  ## Access is not checked here

  The caller has already resolved a role through
  `PhoenixKitKnowledgeBase.Vaults.fetch_for/2`, and every function is scoped to
  a vault — which keeps the permission decision in one place rather than
  re-derived in twenty query functions.
  """

  import Ecto.Query

  alias PhoenixKitKnowledgeBase.{Events, Links, Markdown, Storage}
  alias PhoenixKitKnowledgeBase.Schemas.{Folder, Note, Vault}

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # ── Folders ───────────────────────────────────────────────────────────────

  @doc "Every indexed folder in a vault, ordered by path so a tree can be built in one pass."
  @spec list_folders(String.t()) :: [Folder.t()]
  def list_folders(vault_uuid) do
    repo().all(
      from(f in Folder, where: f.vault_uuid == ^vault_uuid, order_by: [asc: f.relative_path])
    )
  end

  @doc """
  The folder tree as nested `%{folder: folder, children: [...]}` nodes.

  Rebuilt from `relative_path` rather than stored: the filesystem already owns
  the hierarchy, and a second copy of it in the database is a second thing that
  can disagree with the disk.
  """
  @spec folder_tree(String.t()) :: [map()]
  def folder_tree(vault_uuid) do
    folders = list_folders(vault_uuid)

    by_parent =
      Enum.group_by(folders, fn folder ->
        case Path.dirname(folder.relative_path) do
          "." -> ""
          parent -> parent
        end
      end)

    build_tree("", by_parent)
  end

  defp build_tree(parent_path, by_parent) do
    by_parent
    |> Map.get(parent_path, [])
    |> Enum.map(fn folder ->
      %{folder: folder, children: build_tree(folder.relative_path, by_parent)}
    end)
  end

  @doc "Fetch a folder scoped to its vault, by uuid, or `nil`."
  @spec get_folder(String.t(), String.t() | nil) :: Folder.t() | nil
  def get_folder(_vault_uuid, nil), do: nil

  def get_folder(vault_uuid, folder_uuid) do
    repo().get_by(Folder, uuid: folder_uuid, vault_uuid: vault_uuid)
  rescue
    Ecto.Query.CastError -> nil
  end

  @doc """
  Create a directory on disk and index it, plus any parents it needed.

  `parent_path` is `""` for the vault root.
  """
  @spec create_folder(Vault.t(), String.t(), String.t()) ::
          {:ok, Folder.t()} | {:error, term()}
  def create_folder(%Vault{} = vault, parent_path, name) do
    with {:ok, segment} <- sanitize(name),
         {:ok, parent} <- safe_path(parent_path),
         relative_path <- Path.join(parent, segment),
         :ok <- Storage.create_folder(vault.directory, relative_path) do
      # Index the parents too: `a/b/c` created in one call means `a` and `a/b`
      # now exist on disk and must appear in the sidebar.
      result = index_folder_chain(vault, relative_path)
      Events.vault_changed(vault.uuid, :folder)
      result
    end
  end

  @doc """
  Move a directory and everything under it to the trash, and drop its index rows.

  The notes inside go with it — a folder is its contents — but they go to
  `.trash/` with the subtree intact, so the whole folder can be restored.
  """
  @spec delete_folder(Vault.t(), Folder.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def delete_folder(%Vault{} = vault, %Folder{} = folder) do
    prefix = folder.relative_path <> "/"

    with {:ok, _trash_path} <- Storage.trash_folder(vault.directory, folder.relative_path) do
      doomed_notes =
        from(n in Note,
          where:
            n.vault_uuid == ^vault.uuid and
              (n.folder_path == ^folder.relative_path or
                 like(n.folder_path, ^(escape_like(prefix) <> "%")))
        )

      # Loaded before the delete, because the keys they answered to are what the
      # rest of the vault's links have to be re-resolved against afterwards.
      gone = repo().all(doomed_notes)
      {removed, _} = repo().delete_all(doomed_notes)

      repo().delete_all(
        from(f in Folder,
          where:
            f.vault_uuid == ^vault.uuid and
              (f.relative_path == ^folder.relative_path or
                 like(f.relative_path, ^(escape_like(prefix) <> "%")))
        )
      )

      # Same reasoning as `delete_note/2`: `nilify_all` has unresolved every link
      # into these notes, which is only right if nothing else answers to their
      # titles. A copy elsewhere in the vault should inherit those links.
      Links.reresolve_keys(vault.uuid, Enum.flat_map(gone, &Links.keys_for/1))

      Events.vault_changed(vault.uuid, :folder)
      {:ok, removed}
    end
  end

  @doc false
  # Index a directory and every ancestor of it, ignoring ones already present.
  @spec index_folder_chain(Vault.t(), String.t()) :: {:ok, Folder.t()} | {:error, term()}
  def index_folder_chain(%Vault{} = vault, relative_path) do
    relative_path
    |> ancestor_paths()
    |> Enum.reduce({:error, :no_path}, fn path, _acc -> upsert_folder(vault, path) end)
  end

  defp upsert_folder(vault, path) do
    case repo().get_by(Folder, vault_uuid: vault.uuid, relative_path: path) do
      %Folder{} = existing -> {:ok, existing}
      nil -> insert_folder(vault, path)
    end
  end

  defp insert_folder(vault, path) do
    %Folder{}
    |> Folder.changeset(%{"vault_uuid" => vault.uuid, "relative_path" => path})
    |> repo().insert(on_conflict: :nothing, conflict_target: [:vault_uuid, :relative_path])
    |> case do
      # `on_conflict: :nothing` returns a struct with no uuid when the row was
      # already there (a concurrent rescan, say); re-read it.
      {:ok, %Folder{uuid: nil}} ->
        {:ok, repo().get_by(Folder, vault_uuid: vault.uuid, relative_path: path)}

      other ->
        other
    end
  end

  defp ancestor_paths(""), do: []

  defp ancestor_paths(path) do
    path
    |> Path.split()
    |> Enum.scan([], fn segment, acc -> acc ++ [segment] end)
    |> Enum.map(&Path.join/1)
  end

  # ── Notes: reads ──────────────────────────────────────────────────────────

  @doc """
  Notes in a vault.

  Options:

    * `:folder_path` — `""` for the vault root, `:any` (default) for everything
    * `:tag` — only notes carrying this tag
    * `:order` — `:title` (default) or `:updated`
    * `:limit`
  """
  @spec list_notes(String.t(), keyword()) :: [Note.t()]
  def list_notes(vault_uuid, opts \\ []) do
    from(n in Note, where: n.vault_uuid == ^vault_uuid)
    |> filter_by_folder(Keyword.get(opts, :folder_path, :any))
    |> filter_by_tag(Keyword.get(opts, :tag))
    |> order_notes(Keyword.get(opts, :order, :title))
    |> maybe_limit(Keyword.get(opts, :limit))
    |> repo().all()
  end

  defp filter_by_folder(query, :any), do: query
  defp filter_by_folder(query, path), do: from(n in query, where: n.folder_path == ^path)

  defp filter_by_tag(query, nil), do: query
  defp filter_by_tag(query, tag), do: from(n in query, where: ^tag in n.tags)

  defp order_notes(query, :updated), do: from(n in query, order_by: [desc: n.updated_at])

  defp order_notes(query, _title),
    do: from(n in query, order_by: [asc: n.title, asc: n.relative_path])

  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, limit), do: from(n in query, limit: ^limit)

  @doc "How many notes a vault holds."
  @spec count_notes(String.t()) :: non_neg_integer()
  def count_notes(vault_uuid) do
    repo().one(from(n in Note, where: n.vault_uuid == ^vault_uuid, select: count(n.uuid))) || 0
  end

  @doc "Fetch a note scoped to its vault, or `nil` (also for a malformed uuid)."
  @spec get_note(String.t(), String.t() | nil) :: Note.t() | nil
  def get_note(_vault_uuid, nil), do: nil

  def get_note(vault_uuid, note_uuid) do
    repo().get_by(Note, uuid: note_uuid, vault_uuid: vault_uuid)
  rescue
    Ecto.Query.CastError -> nil
  end

  @doc "Fetch a note by its path within the vault, or `nil`."
  @spec get_note_by_path(String.t(), String.t()) :: Note.t() | nil
  def get_note_by_path(vault_uuid, relative_path) do
    repo().get_by(Note, vault_uuid: vault_uuid, relative_path: relative_path)
  end

  @doc """
  Fetch a note by title, matched case- and whitespace-insensitively.

  Returns the same note `[[Title]]` would resolve to from the vault root when
  several share a title.
  """
  @spec get_note_by_title(String.t(), String.t() | nil) :: Note.t() | nil
  def get_note_by_title(vault_uuid, title) do
    case Markdown.normalize_title(title) do
      key when key in [nil, ""] ->
        nil

      key ->
        case Links.resolve(Links.resolver(vault_uuid), key, "") do
          nil -> nil
          %{uuid: uuid} -> get_note(vault_uuid, uuid)
        end
    end
  end

  @doc "The note's current content read from disk, bypassing the cached column."
  @spec read_from_disk(Vault.t(), Note.t()) :: {:ok, String.t()} | {:error, term()}
  def read_from_disk(%Vault{} = vault, %Note{} = note) do
    Storage.read_note(vault.directory, note.relative_path)
  end

  # ── Notes: writes ─────────────────────────────────────────────────────────

  @doc """
  Create a note: write the file, then index what landed.

  Refuses if a file is already at that path, rather than overwriting a note that
  the index may not even know about yet.
  """
  @spec create_note(Vault.t(), map(), String.t() | nil) :: {:ok, Note.t()} | {:error, term()}
  def create_note(%Vault{} = vault, attrs, actor_uuid \\ nil) do
    title = Map.get(attrs, "title") || Map.get(attrs, :title)
    folder = Map.get(attrs, "folder_path") || Map.get(attrs, :folder_path) || ""
    content = Map.get(attrs, "content") || Map.get(attrs, :content) || ""

    with {:ok, relative_path} <- build_note_path(title, folder),
         false <- Storage.note_exists?(vault.directory, relative_path),
         {:ok, stat} <- Storage.write_note(vault.directory, relative_path, content),
         {:ok, note} <- index_entry(vault, relative_path, stat, created_by: actor_uuid) do
      # Not just the links that were waiting for this title — every link naming
      # it, including ones already resolved to a note this one now beats on the
      # same-folder tie-break. See `Links.reresolve_keys/2`.
      Links.reresolve_for_note(note)
      {:ok, note}
    else
      true -> {:error, :already_exists}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Save new content for a note.

  Guarded against clobbering an external edit — see the moduledoc. Pass
  `force: true` to overwrite deliberately, which is what a "save anyway" button
  would do.
  """
  @spec update_content(Vault.t(), Note.t(), String.t(), keyword()) ::
          {:ok, Note.t()} | {:error, term()}
  def update_content(%Vault{} = vault, %Note{} = note, content, opts \\ []) do
    with :ok <- check_not_stale(vault, note, opts),
         {:ok, stat} <- Storage.write_note(vault.directory, note.relative_path, content) do
      index_entry(vault, note.relative_path, stat, updated_by: opts[:actor_uuid])
    end
  end

  @doc """
  Rename a note — which renames its file, because the filename *is* the title.

  Links to the old name stop resolving and links waiting for the new one start,
  both handled here.
  """
  @spec rename_note(Vault.t(), Note.t(), String.t(), keyword()) ::
          {:ok, Note.t()} | {:error, term()}
  def rename_note(%Vault{} = vault, %Note{} = note, new_title, opts \\ []) do
    with {:ok, target} <- build_note_path(new_title, note.folder_path || ""),
         :ok <- move_and_reindex(vault, note, target, opts) do
      {:ok, get_note(vault.uuid, note.uuid)}
    end
  end

  @doc "Move a note into another folder (`\"\"` = the vault root), moving its file."
  @spec move_note(Vault.t(), Note.t(), String.t(), keyword()) ::
          {:ok, Note.t()} | {:error, term()}
  def move_note(%Vault{} = vault, %Note{} = note, folder_path, opts \\ []) do
    with {:ok, folder} <- safe_path(folder_path),
         target <- Path.join(folder, Path.basename(note.relative_path)),
         :ok <- move_and_reindex(vault, note, target, opts) do
      {:ok, get_note(vault.uuid, note.uuid)}
    end
  end

  defp move_and_reindex(vault, note, target, opts) do
    if target == note.relative_path do
      :ok
    else
      with :ok <- check_not_stale(vault, note, opts),
           :ok <- Storage.move_note(vault.directory, note.relative_path, target),
           {:ok, stat} <- Storage.stat_note(vault.directory, target),
           {:ok, moved} <-
             index_entry(vault, target, stat, updated_by: opts[:actor_uuid], existing: note) do
        # The name changed, so both directions of resolution need revisiting:
        # what pointed here under the old name, and what was waiting for the new
        # one. Both key sets go in together — a link to the old name may now
        # belong to a different note entirely, not merely be unresolved.
        Links.reresolve_keys(vault.uuid, Links.keys_for(note) ++ Links.keys_for(moved))
        :ok
      end
    end
  end

  @doc """
  Move a note to the vault's trash and drop its index row.

  The file is not unlinked — it goes to `.trash/`, so an accidental delete is
  recoverable (`list_trash/1`, `restore_note/2`). The index row goes because a
  trashed note is not part of the vault any more: it should not appear in
  search, in the sidebar or in the link graph.

  Links into it become unresolved rather than disappearing, so the notes that
  mentioned it keep saying so — and restoring re-resolves them.
  """
  @spec delete_note(Vault.t(), Note.t()) :: {:ok, Note.t()} | {:error, term()}
  def delete_note(%Vault{} = vault, %Note{} = note) do
    with {:ok, _trash_path} <- Storage.trash_note(vault.directory, note.relative_path),
         {:ok, deleted} <- repo().delete(note) do
      # The FK's `nilify_all` has just turned every link here into an unresolved
      # one. That is right only when nothing else answers to the name — if the
      # vault still holds another `Ideas.md`, those links belong to it now.
      Links.reresolve_for_note(deleted)
      Events.note_deleted(deleted)
      {:ok, deleted}
    end
  end

  @doc "Everything in the vault's trash, newest first."
  @spec list_trash(Vault.t()) :: [map()]
  def list_trash(%Vault{} = vault) do
    case Storage.list_trash(vault.directory) do
      {:ok, entries} -> entries
      {:error, _reason} -> []
    end
  end

  @doc """
  Restore a trashed note to where it came from, and reindex it.

  Every link that was waiting for its title resolves again, which is the whole
  point of un-deleting rather than re-typing.
  """
  @spec restore_note(Vault.t(), map()) :: {:ok, Note.t()} | {:error, term()}
  def restore_note(%Vault{} = vault, %{trash_path: trash_path, original_path: original_path}) do
    with :ok <- Storage.restore(vault.directory, trash_path, original_path),
         {:ok, stat} <- Storage.stat_note(vault.directory, original_path),
         {:ok, note} <- index_entry(vault, original_path, stat) do
      Links.reresolve_for_note(note)
      {:ok, note}
    end
  end

  @doc "Delete one trashed item for good."
  @spec purge_trash(Vault.t(), map()) :: :ok | {:error, term()}
  def purge_trash(%Vault{} = vault, %{trash_path: trash_path}) do
    Storage.purge(vault.directory, trash_path)
  end

  @doc "Empty the vault's trash."
  @spec empty_trash(Vault.t()) :: :ok | {:error, term()}
  def empty_trash(%Vault{} = vault) do
    with :ok <- Storage.empty_trash(vault.directory) do
      Events.vault_changed(vault.uuid, :trash)
      :ok
    end
  end

  # ── Indexing ──────────────────────────────────────────────────────────────

  @doc """
  Index one file: upsert its row from the bytes on disk and rebuild its links.

  The single entry point for "make the database agree with this file", used by
  every write path and by the rescan.

  Pass `broadcast: false` during a bulk reindex; a rescan announces itself once
  at the end rather than once per file.

  Pass `existing: note` when the file has just *moved* and the row to update is
  therefore not the one at `relative_path`. Without it a rename looks up the
  new path, finds nothing, and inserts a second row — leaving the note listed
  twice, the old entry pointing at a file that is no longer there, and every
  backlink still attached to the stale one. `Storage.move_note/3` refuses to
  overwrite an existing file, so the row named here cannot collide with a real
  note at the target.
  """
  @spec index_entry(Vault.t(), String.t(), map(), keyword()) ::
          {:ok, Note.t()} | {:error, term()}
  def index_entry(%Vault{} = vault, relative_path, stat, opts \\ []) do
    existing = opts[:existing] || get_note_by_path(vault.uuid, relative_path)

    attrs = %{
      "vault_uuid" => vault.uuid,
      "relative_path" => relative_path,
      "content" => stat.content,
      "content_hash" => stat.hash,
      "file_mtime" => stat.mtime,
      "file_size" => stat.size
    }

    attrs =
      attrs
      |> maybe_put("created_by", opts[:created_by], is_nil(existing))
      |> maybe_put("updated_by", opts[:updated_by] || opts[:created_by], true)

    result =
      case existing do
        nil -> %Note{} |> Note.changeset(attrs) |> repo().insert()
        note -> note |> Note.changeset(attrs) |> repo().update()
      end

    with {:ok, note} <- result do
      # Fold the folder into the index so an empty-until-now directory shows up
      # in the sidebar the moment it holds a note.
      if note.folder_path != "", do: index_folder_chain(vault, note.folder_path)
      Links.reindex_note(note)
      if Keyword.get(opts, :broadcast, true), do: Events.note_saved(note)
      {:ok, note}
    end
  end

  defp maybe_put(attrs, _key, nil, _condition), do: attrs
  defp maybe_put(attrs, _key, _value, false), do: attrs
  defp maybe_put(attrs, key, value, true), do: Map.put(attrs, key, value)

  @doc """
  Whether the file backing a note has changed since it was indexed.

  `:missing` when the file is gone, which is a conflict too — saving would
  silently resurrect a note somebody deleted on disk.
  """
  @spec disk_state(Vault.t(), Note.t()) :: :current | :changed | :missing
  def disk_state(%Vault{} = vault, %Note{} = note) do
    case Storage.stat_note(vault.directory, note.relative_path) do
      {:ok, %{hash: hash}} -> if hash == note.content_hash, do: :current, else: :changed
      {:error, :enoent} -> :missing
      {:error, _reason} -> :missing
    end
  end

  # The guard itself. `force: true` is the "save anyway" escape hatch; without
  # it, a file that changed underneath us stops the write rather than silently
  # winning the race.
  defp check_not_stale(vault, note, opts) do
    if Keyword.get(opts, :force, false) do
      :ok
    else
      case disk_state(vault, note) do
        :current -> :ok
        :changed -> {:error, :stale}
        :missing -> {:error, :missing_file}
      end
    end
  end

  # ── Search ────────────────────────────────────────────────────────────────

  @doc """
  Full-text search over a vault, best match first.

  Runs against the cached `content` column via a generated `tsvector`, with the
  title weighted above the body so an exact-title hit outranks a passing
  mention. `websearch_to_tsquery` parses the query the way a search box user
  expects (quoted phrases, `-exclusions`) and, unlike `to_tsquery`, cannot be
  made to raise by punctuation someone typed.

  The `'english'` config is written literally in both fragments and matches the
  one the migration's generated column uses — a mismatch would search a vector
  built with different stemming rules. It cannot be a bound parameter: that
  argument is a `regconfig`, so Postgres types the placeholder as an OID and
  Postgrex refuses to encode a string into it.

  The `search_vector` reference is unqualified SQL because the column is
  deliberately not mapped in `Note`; there is exactly one table here, so it is
  unambiguous.
  """
  @spec search(String.t(), String.t(), keyword()) :: [Note.t()]
  def search(vault_uuid, term, opts \\ []) do
    case String.trim(term || "") do
      "" ->
        []

      trimmed ->
        limit = Keyword.get(opts, :limit, 50)

        repo().all(
          from(n in Note,
            where: n.vault_uuid == ^vault_uuid,
            where: fragment("search_vector @@ websearch_to_tsquery('english', ?)", ^trimmed),
            order_by: [
              desc:
                fragment("ts_rank(search_vector, websearch_to_tsquery('english', ?))", ^trimmed),
              asc: n.title
            ],
            limit: ^limit
          )
        )
    end
  end

  @doc """
  Title-prefix search, for the `[[` link picker and the quick switcher.

  Separate from `search/3` on purpose: full-text matches whole lexemes, so
  typing "kno" finds nothing until the word is complete, while picking a link
  has to respond to a half-typed word.
  """
  @spec search_titles(String.t(), String.t(), keyword()) :: [Note.t()]
  def search_titles(vault_uuid, term, opts \\ []) do
    limit = Keyword.get(opts, :limit, 8)
    exclude = Keyword.get(opts, :exclude_uuid)

    case String.trim(term || "") do
      "" ->
        vault_uuid
        |> list_notes(order: :updated, limit: limit + 1)
        |> Enum.reject(&(&1.uuid == exclude))
        |> Enum.take(limit)

      trimmed ->
        pattern = "%#{escape_like(trimmed)}%"
        prefix = "#{escape_like(trimmed)}%"

        from(n in Note,
          where: n.vault_uuid == ^vault_uuid,
          # `ESCAPE '\\'` so the backslashes `escape_like/1` inserts are read as
          # escapes rather than as literal characters to match.
          where: fragment("? ILIKE ? ESCAPE '\\'", n.title, ^pattern),
          order_by: [
            desc: fragment("(? ILIKE ?)", n.title, ^prefix),
            asc: fragment("length(?)", n.title),
            asc: n.title
          ],
          limit: ^limit
        )
        |> exclude_uuid(exclude)
        |> repo().all()
    end
  end

  defp exclude_uuid(query, nil), do: query
  defp exclude_uuid(query, uuid), do: from(n in query, where: n.uuid != ^uuid)

  # `%` and `_` are wildcards in LIKE; a user searching for "50%" means the
  # literal characters.
  defp escape_like(term) do
    term
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  @doc """
  How many notes carry each of these normalised titles.

  Used to decide whether a suggested `[[link]]` needs to be path-qualified: a
  title only one note answers to can be inserted bare, and one that several
  share should be inserted as a path so the link is not left to the tie-break.
  """
  @spec title_key_counts(String.t(), [String.t()]) :: %{String.t() => pos_integer()}
  def title_key_counts(_vault_uuid, []), do: %{}

  def title_key_counts(vault_uuid, keys) do
    keys = Enum.uniq(keys)

    from(n in Note,
      where: n.vault_uuid == ^vault_uuid and n.title_key in ^keys,
      group_by: n.title_key,
      select: {n.title_key, count(n.uuid)}
    )
    |> repo().all()
    |> Map.new()
  end

  @doc """
  Every tag in a vault with how many notes carry it, most used first.

  Aggregated in Elixir rather than with `unnest`: a vault's tag arrays are small
  and this keeps the query a plain scoped select. If a vault ever outgrows
  loading one array per note, this is the function to move into SQL — the
  callers do not change.
  """
  @spec list_tags(String.t()) :: [{String.t(), pos_integer()}]
  def list_tags(vault_uuid) do
    from(n in Note, where: n.vault_uuid == ^vault_uuid, select: n.tags)
    |> repo().all()
    |> List.flatten()
    |> Enum.frequencies()
    |> Enum.sort_by(fn {tag, count} -> {-count, tag} end)
  end

  # ── internals ─────────────────────────────────────────────────────────────

  defp build_note_path(title, folder), do: Storage.note_relative_path(title, folder)

  defp sanitize(name), do: Storage.validate_filename(name)

  defp safe_path(path) do
    case Storage.safe_relative(path || "") do
      {:ok, safe} -> {:ok, safe}
      :error -> {:error, :unsafe_path}
    end
  end
end
