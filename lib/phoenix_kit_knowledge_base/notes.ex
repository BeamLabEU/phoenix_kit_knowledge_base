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

  require Logger

  alias PhoenixKitKnowledgeBase.{Errors, Events, Links, Markdown, Storage}
  alias PhoenixKitKnowledgeBase.Schemas.{Folder, Note, Vault}

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # ── Folders ───────────────────────────────────────────────────────────────

  @doc """
  Every indexed folder in a vault, ordered by path so a tree can be built in one pass.

  Options:

    * `:parent` — only the folders directly inside this one (`""`: the vault
      root's own). For a listing of one folder, which would otherwise read the
      whole vault's tree to show a level of it.
  """
  @spec list_folders(String.t(), keyword()) :: [Folder.t()]
  def list_folders(vault_uuid, opts \\ []) do
    from(f in Folder, where: f.vault_uuid == ^vault_uuid, order_by: [asc: f.relative_path])
    |> filter_children_of(Keyword.get(opts, :parent, :any))
    |> repo().all()
  end

  defp filter_children_of(query, :any), do: query

  defp filter_children_of(query, ""),
    do: from(f in query, where: not like(f.relative_path, "%/%"))

  defp filter_children_of(query, parent) do
    prefix = escape_like(parent) <> "/"

    from(f in query,
      where:
        like(f.relative_path, ^(prefix <> "%")) and not like(f.relative_path, ^(prefix <> "%/%"))
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

  @doc """
  Move or rename a folder, and reindex everything underneath it.

  One function, because on a filesystem it is one operation: renaming
  `research` and moving it into `2026/` are both a directory rename.

  The reindex is the part worth reading. Every note under the folder gets a new
  `relative_path`, and each is re-indexed **naming the row to update** — the
  same `existing:` that `move_and_reindex/4` needs, and for the same reason: a
  lookup by the new path finds nothing, inserts a second row, and strands every
  backlink on the old one. Moving a folder of thirty notes would do that thirty
  times.

  Then the link graph. Path-qualified links (`[[research/Ideas]]`) name a path
  that no longer exists, and the same link written against the new path starts
  resolving — so every key the subtree answered to, before and after, is
  re-resolved together.

  Folder rows are reconciled against the disk rather than rewritten from the
  old prefix, so empty subdirectories move with the rest instead of vanishing
  from the sidebar until the next rescan.
  """
  @spec relocate_folder(Vault.t(), Folder.t(), String.t()) ::
          {:ok, Folder.t()} | {:error, term()}
  def relocate_folder(%Vault{} = vault, %Folder{} = folder, target_path) do
    from = folder.relative_path

    with {:ok, target} <- safe_path(target_path),
         :ok <- refuse_noop_move(from, target),
         affected <- notes_under(vault.uuid, from),
         old_keys <- Enum.flat_map(affected, &Links.keys_for/1),
         :ok <- Storage.move_folder(vault.directory, from, target) do
      # One resolver for the whole subtree. Without it `index_entry/4` builds a
      # fresh one per note — a full scan of every note in the vault, thirty
      # times over for a folder of thirty notes.
      resolver = Links.resolver(vault.uuid)
      {new_keys, failed} = reindex_moved_notes(vault, affected, from, target, resolver)
      sync_folders(vault)
      Links.reresolve_keys(vault.uuid, old_keys ++ new_keys)
      Events.vault_changed(vault.uuid, :folder)

      # The bytes moved; the index did not entirely follow. Reported rather than
      # hidden behind a success — a rescan repairs it, and the caller is the
      # only thing that can say so.
      case failed do
        [] -> {:ok, get_folder_by_path(vault.uuid, target)}
        paths -> {:error, {:reindex_incomplete, paths}}
      end
    end
  end

  defp refuse_noop_move(from, from), do: {:error, :unchanged}
  defp refuse_noop_move(_from, _target), do: :ok

  # The folder itself and everything below it. Compared with a trailing slash so
  # `researching` is not swept up with `research`.
  defp notes_under(vault_uuid, folder_path) do
    prefix = folder_path <> "/"

    repo().all(
      from(n in Note,
        where:
          n.vault_uuid == ^vault_uuid and
            (n.folder_path == ^folder_path or
               like(n.folder_path, ^(escape_like(prefix) <> "%")))
      )
    )
  end

  # Returns `{keys, failed_paths}`. A note that cannot be re-indexed is *not*
  # dropped quietly: the directory has already moved, so its row still points at
  # a path that no longer exists, and `sync_folders/1` is about to delete the
  # folder row it lived under — the note disappears from the tree and every save
  # against it is refused. Invariant 1 says the index is disposable, not that it
  # may be wrong.
  defp reindex_moved_notes(vault, notes, from, target, resolver) do
    Enum.reduce(notes, {[], []}, fn note, {keys, failed} ->
      new_path = swap_prefix(note.relative_path, from, target)

      with {:ok, stat} <- Storage.stat_note(vault.directory, new_path),
           {:ok, moved} <-
             index_entry(vault, new_path, stat,
               existing: note,
               broadcast: false,
               resolver: resolver
             ) do
        {Links.keys_for(moved) ++ keys, failed}
      else
        error ->
          Logger.error(
            "[knowledge_base] could not reindex #{new_path} after moving #{from}: #{Errors.for_log(error)}"
          )

          {keys, [new_path | failed]}
      end
    end)
  end

  defp swap_prefix(path, from, target) do
    case String.replace_prefix(path, from <> "/", "") do
      ^path -> path
      rest -> Path.join(target, rest)
    end
  end

  @doc """
  Make the folder index agree with the directories on disk.

  Used after a folder move and by the rescan, which is the only other thing
  that can make the two disagree.

  `{:error, reason}` when the directory cannot be listed — a vault that lost
  read permission or was unmounted. That has to reach the rescan report:
  answering `{0, 0}` there would report "everything already up to date" for a
  vault nothing can read.
  """
  @spec sync_folders(Vault.t()) ::
          {:ok, {non_neg_integer(), non_neg_integer()}} | {:error, term()}
  def sync_folders(%Vault{} = vault) do
    case Storage.list_folders(vault.directory) do
      {:ok, on_disk} ->
        indexed = repo().all(from(f in Folder, where: f.vault_uuid == ^vault.uuid))
        indexed_paths = MapSet.new(indexed, & &1.relative_path)
        disk_paths = MapSet.new(on_disk)

        added =
          disk_paths
          |> MapSet.difference(indexed_paths)
          |> Enum.count(&match?({:ok, _}, index_folder_chain(vault, &1)))

        gone = Enum.filter(indexed, &(not MapSet.member?(disk_paths, &1.relative_path)))

        removed =
          if gone == [] do
            0
          else
            {count, _} =
              repo().delete_all(from(f in Folder, where: f.uuid in ^Enum.map(gone, & &1.uuid)))

            count
          end

        {:ok, {added, removed}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Fetch a folder by its path inside the vault, or `nil`."
  @spec get_folder_by_path(String.t(), String.t()) :: Folder.t() | nil
  def get_folder_by_path(vault_uuid, relative_path) do
    repo().get_by(Folder, vault_uuid: vault_uuid, relative_path: relative_path)
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
    * `:under` — a folder and everything below it (`""` or `nil`: no limit)
    * `:tag` — only notes carrying this tag
    * `:order` — `:title` (default) or `:updated`
    * `:limit`
    * `:content` — `false` leaves each note's body unloaded (it reads `""`).
      For listings and link resolution, which need titles, paths, tags and
      dates and would otherwise read every note's whole text — a notes panel
      does that on every poll.
    * `:property` — `{key, value}`: only notes whose front matter has
      `key: value` at the top level. The value is compared as text (YAML
      `7` matches `"7"`), so a host keeping an id in its notes' properties
      finds them without querying this module's tables.
    * `:has_property` — a key, or a list of keys: only notes whose front
      matter has at least one of them.
  """
  @spec list_notes(String.t(), keyword()) :: [Note.t()]
  def list_notes(vault_uuid, opts \\ []) do
    from(n in Note, where: n.vault_uuid == ^vault_uuid)
    |> filter_by_folder(Keyword.get(opts, :folder_path, :any))
    |> filter_by_subtree(Keyword.get(opts, :under))
    |> filter_by_tag(Keyword.get(opts, :tag))
    |> filter_by_property(Keyword.get(opts, :property))
    |> filter_by_has_property(Keyword.get(opts, :has_property))
    |> order_notes(Keyword.get(opts, :order, :title))
    |> maybe_limit(Keyword.get(opts, :limit))
    |> maybe_without_content(Keyword.get(opts, :content, true))
    |> repo().all()
  end

  defp maybe_without_content(query, false),
    do: from(n in query, select: struct(n, ^(Note.__schema__(:fields) -- [:content])))

  defp maybe_without_content(query, _), do: query

  defp filter_by_folder(query, :any), do: query
  defp filter_by_folder(query, path), do: from(n in query, where: n.folder_path == ^path)

  defp filter_by_subtree(query, nil), do: query
  defp filter_by_subtree(query, ""), do: query

  defp filter_by_subtree(query, path) do
    from(n in query,
      where: n.folder_path == ^path or like(n.folder_path, ^(escape_like(path) <> "/%"))
    )
  end

  defp filter_by_tag(query, nil), do: query
  defp filter_by_tag(query, tag), do: from(n in query, where: ^tag in n.tags)

  defp filter_by_property(query, nil), do: query

  defp filter_by_property(query, {key, value}) when is_binary(key) do
    value = to_string(value)
    from(n in query, where: fragment("?->>? = ?", n.frontmatter, ^key, ^value))
  end

  defp filter_by_has_property(query, nil), do: query

  defp filter_by_has_property(query, key) when is_binary(key),
    do: filter_by_has_property(query, [key])

  defp filter_by_has_property(query, keys) when is_list(keys) do
    from(n in query,
      where: fragment("jsonb_exists_any(?, ?)", n.frontmatter, type(^keys, {:array, :string}))
    )
  end

  @doc """
  The first note (by path) whose front matter has `key: value`, or `nil`.
  See `list_notes/2`'s `:property`.
  """
  @spec get_note_by_property(String.t(), String.t(), term()) :: Note.t() | nil
  def get_note_by_property(vault_uuid, key, value) do
    from(n in Note,
      where: n.vault_uuid == ^vault_uuid,
      order_by: [asc: n.relative_path],
      limit: 1
    )
    |> filter_by_property({key, value})
    |> repo().one()
  end

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

  @doc """
  Note counts for several vaults in one query, as `%{vault_uuid => count}`.

  For list pages that show a count per row — one grouped query instead of one
  `count_notes/1` per card.
  """
  @spec count_notes_by_vault([String.t()]) :: %{String.t() => non_neg_integer()}
  def count_notes_by_vault([]), do: %{}

  def count_notes_by_vault(vault_uuids) do
    from(n in Note,
      where: n.vault_uuid in ^vault_uuids,
      group_by: n.vault_uuid,
      select: {n.vault_uuid, count(n.uuid)}
    )
    |> repo().all()
    |> Map.new()
  end

  @doc "Fetch a note scoped to its vault, or `nil` (also for a malformed uuid)."
  @spec get_note(String.t(), String.t() | nil) :: Note.t() | nil
  def get_note(_vault_uuid, nil), do: nil

  def get_note(vault_uuid, note_uuid) do
    repo().get_by(Note, uuid: note_uuid, vault_uuid: vault_uuid)
  rescue
    Ecto.Query.CastError -> nil
  end

  @doc """
  A note and the vault holding it, from the note uuid alone.

  For a caller that has only the uuid and no vault in hand — the collaboration
  store, whose document id is the note uuid, running inside a room process that
  never saw a LiveView's assigns. One query rather than two, because it runs on
  every flush.
  """
  @spec fetch_with_vault(String.t()) :: {:ok, Note.t(), Vault.t()} | :error
  def fetch_with_vault(note_uuid) when is_binary(note_uuid) do
    from(n in Note,
      join: v in Vault,
      on: v.uuid == n.vault_uuid,
      where: n.uuid == ^note_uuid,
      select: {n, v}
    )
    |> repo().one()
    |> case do
      {%Note{} = note, %Vault{} = vault} -> {:ok, note, vault}
      nil -> :error
    end
  rescue
    # A malformed uuid is "no such note", not a crash — the id reaches here from
    # a room that may outlive the note it was started for.
    Ecto.Query.CastError -> :error
  end

  def fetch_with_vault(_note_uuid), do: :error

  @doc """
  Every note's uuid, title and folder, for building the sidebar tree.

  Three columns rather than whole rows: the tree needs a label and something to
  drag, and `content` is the entire markdown of every note in the vault. This
  runs on every note click, folder click, tag click, drag and peer save.
  """
  @spec list_titles(String.t()) :: [
          %{uuid: String.t(), title: String.t(), folder_path: String.t()}
        ]
  def list_titles(vault_uuid) do
    repo().all(
      from(n in Note,
        where: n.vault_uuid == ^vault_uuid,
        order_by: [asc: n.title, asc: n.relative_path],
        select: %{uuid: n.uuid, title: n.title, folder_path: n.folder_path}
      )
    )
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

  Options:

    * `unique: true` — when the name is taken, number it instead of refusing:
      `Ideas` → `Ideas 2` → `Ideas 3` … (the note's title is the file name,
      so read it back from the returned note).
  """
  @spec create_note(Vault.t(), map(), String.t() | nil, keyword()) ::
          {:ok, Note.t()} | {:error, term()}
  def create_note(%Vault{} = vault, attrs, actor_uuid \\ nil, opts \\ []) do
    title = Map.get(attrs, "title") || Map.get(attrs, :title)
    folder = Map.get(attrs, "folder_path") || Map.get(attrs, :folder_path) || ""
    content = Map.get(attrs, "content") || Map.get(attrs, :content) || ""

    if Keyword.get(opts, :unique, false) do
      title
      |> numbered_titles()
      |> Enum.find_value(
        {:error, :too_many_duplicates},
        &unless_taken(&1, vault, folder, content, actor_uuid)
      )
    else
      write_new_note(vault, title, folder, content, actor_uuid)
    end
  end

  # nil (try the next number) when the name is taken, else the result.
  defp unless_taken(title, vault, folder, content, actor_uuid) do
    case write_new_note(vault, title, folder, content, actor_uuid) do
      {:error, :already_exists} -> nil
      result -> result
    end
  end

  defp write_new_note(vault, title, folder, content, actor_uuid) do
    with :ok <- check_text(content),
         {:ok, relative_path} <- build_note_path(title, folder),
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
    with :ok <- check_text(content),
         :ok <- check_not_stale(vault, note, opts),
         {:ok, stat} <- Storage.write_note(vault.directory, note.relative_path, content) do
      index_entry(vault, note.relative_path, stat,
        updated_by: opts[:actor_uuid],
        # Forwarded, not swallowed: a caller writing on somebody else's behalf
        # — the collaboration store, flushing from a room process — needs to
        # suppress the per-note announcement and say something truer itself.
        broadcast: Keyword.get(opts, :broadcast, true)
      )
    end
  end

  @doc """
  Rename a note — which renames its file, because the filename *is* the title.

  Links to the old name stop resolving and links waiting for the new one start,
  both handled here.

  `unique: true` numbers the new name when it is taken in the folder
  (`Ideas 2`), instead of refusing with `:target_exists`.
  """
  @spec rename_note(Vault.t(), Note.t(), String.t(), keyword()) ::
          {:ok, Note.t()} | {:error, term()}
  def rename_note(%Vault{} = vault, %Note{} = note, new_title, opts \\ []) do
    with {:ok, target} <- target_path(vault, note, note.folder_path || "", new_title, opts),
         :ok <- move_and_reindex(vault, note, target, opts) do
      {:ok, get_note(vault.uuid, note.uuid)}
    end
  end

  @doc """
  Move a note into another folder (`\"\"` = the vault root), moving its file.

  Options:

    * `title:` — rename it in the same step: one file move, so there is no
      moment where the note sits renamed in the old folder (or moved under
      its old name, colliding there).
    * `unique: true` — number the name when it is taken in the target folder
      (`Ideas 2`) instead of refusing with `:target_exists`.
  """
  @spec move_note(Vault.t(), Note.t(), String.t(), keyword()) ::
          {:ok, Note.t()} | {:error, term()}
  def move_note(%Vault{} = vault, %Note{} = note, folder_path, opts \\ []) do
    title = Keyword.get(opts, :title) || Storage.title_from_path(note.relative_path)

    with {:ok, folder} <- safe_path(folder_path),
         {:ok, target} <- target_path(vault, note, folder, title, opts),
         :ok <- move_and_reindex(vault, note, target, opts) do
      {:ok, get_note(vault.uuid, note.uuid)}
    end
  end

  # Where a rename/move lands: `folder/title.md`, or with `unique: true` the
  # first numbered variant that is free (the note's own current path counts
  # as free — renaming `Ideas` to `Ideas` is a no-op, not `Ideas 2`).
  defp target_path(vault, note, folder, title, opts) do
    if Keyword.get(opts, :unique, false) do
      free_path(vault, folder, title, note.relative_path)
    else
      build_note_path(title, folder)
    end
  end

  @max_numbered 100

  # `Ideas`, `Ideas 2`, `Ideas 3`, … — Pezu's and Obsidian's duplicate rule.
  defp numbered_titles(title) do
    Stream.map(1..@max_numbered, fn
      1 -> title
      n -> "#{title} #{n}"
    end)
  end

  defp free_path(vault, folder, title, except_path) do
    title
    |> numbered_titles()
    |> Enum.find_value(
      {:error, :too_many_duplicates},
      &free_candidate(&1, vault, folder, except_path)
    )
  end

  # {:ok, path} when free, nil when taken (try the next), an error when the
  # name itself is invalid (no number will fix that).
  defp free_candidate(title, vault, folder, except_path) do
    with {:ok, path} <- build_note_path(title, folder) do
      if path == except_path or not Storage.note_exists?(vault.directory, path),
        do: {:ok, path}
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

  @doc """
  Everything in the vault's trash, newest first.

  `frontmatter: true` adds each entry's parsed front matter (`%{}` for a
  file without any, or one that is not markdown), so a host that binds notes
  by a property — an `id:` — can find its trashed copy without reading the
  trash itself.
  """
  @spec list_trash(Vault.t(), keyword()) :: [map()]
  def list_trash(%Vault{} = vault, opts \\ []) do
    entries =
      case Storage.list_trash(vault.directory) do
        {:ok, entries} -> entries
        {:error, _reason} -> []
      end

    if Keyword.get(opts, :frontmatter, false),
      do: Enum.map(entries, &put_trash_frontmatter(vault, &1)),
      else: entries
  end

  defp put_trash_frontmatter(vault, entry) do
    frontmatter =
      with true <- String.ends_with?(entry.original_path, ".md"),
           {:ok, content} <- Storage.read_note(vault.directory, entry.trash_path) do
        content |> Markdown.split_frontmatter() |> elem(0)
      else
        _ -> %{}
      end

    Map.put(entry, :frontmatter, frontmatter)
  end

  @doc """
  Restore a trashed note to where it came from, and reindex it.

  Every link that was waiting for its title resolves again, which is the whole
  point of un-deleting rather than re-typing.

  Refuses with `:target_exists` when a note has taken the old place since;
  with `unique: true` it comes back numbered beside it instead (`Ideas 2`).
  """
  @spec restore_note(Vault.t(), map(), keyword()) :: {:ok, Note.t()} | {:error, term()}
  def restore_note(vault, entry, opts \\ [])

  def restore_note(
        %Vault{} = vault,
        %{trash_path: trash_path, original_path: original_path},
        opts
      ) do
    with {:ok, original_path} <- restore_target(vault, original_path, opts),
         :ok <- Storage.restore(vault.directory, trash_path, original_path),
         {:ok, stat} <- Storage.stat_note(vault.directory, original_path),
         {:ok, note} <- index_entry(vault, original_path, stat) do
      Links.reresolve_for_note(note)
      {:ok, note}
    end
  end

  defp restore_target(vault, original_path, opts) do
    if Keyword.get(opts, :unique, false) and String.ends_with?(original_path, ".md") do
      folder = original_path |> Path.dirname() |> then(&if(&1 == ".", do: "", else: &1))
      free_path(vault, folder, Storage.title_from_path(original_path), nil)
    else
      {:ok, original_path}
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

  Pass `resolver:` when indexing several notes in one pass; otherwise each call
  builds its own, which is a scan of every note in the vault per note indexed.

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
      # A caller reindexing many notes at once passes one resolver rather than
      # letting each rebuild a full-vault one.
      Links.reindex_note(note, opts[:resolver])
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

  # Refused before anything touches the disk. Bytes the index cannot hold would
  # land in the file and then fail to index, leaving the row describing the
  # previous version — and the stale guard refusing every save after it. A
  # browser can send a NUL (`\u0000` is valid JSON); nothing a person types does.
  defp check_text(content) when is_binary(content) do
    if Storage.text?(content), do: :ok, else: {:error, :not_text}
  end

  defp check_text(_content), do: {:error, :not_text}

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

  # Private-use code points as the match markers: they cannot occur in what
  # a person typed into a note by accident, and ts_headline copies them as is.
  @snippet_start "\u{E000}"
  @snippet_stop "\u{E001}"

  @doc """
  `search/3`, with a snippet of each note showing where it matched.

  Returns `[%{note: note, snippet: segments}]`, best match first, where
  `segments` is a list of `{:text, binary}` and `{:match, binary}` pieces of
  the note's body around the matched words (Postgres `ts_headline`, with the
  front matter left out). Segments rather than HTML, so the host renders and
  escapes them its own way: nothing from a note's text reaches a page
  unescaped through this.

  Options: `:limit` (default 50), `:words` (the snippet's length, default 18).
  """
  @spec search_with_snippets(String.t(), String.t(), keyword()) :: [
          %{note: Note.t(), snippet: [{:text | :match, String.t()}]}
        ]
  def search_with_snippets(vault_uuid, term, opts \\ []) do
    case String.trim(term || "") do
      "" ->
        []

      trimmed ->
        limit = Keyword.get(opts, :limit, 50)
        words = opts |> Keyword.get(:words, 18) |> max(3) |> min(60)

        options =
          "StartSel=#{@snippet_start}, StopSel=#{@snippet_stop}, MaxWords=#{words}, MinWords=#{min(5, words)}, MaxFragments=1"

        repo().all(
          from(n in Note,
            where: n.vault_uuid == ^vault_uuid,
            where: fragment("search_vector @@ websearch_to_tsquery('english', ?)", ^trimmed),
            order_by: [
              desc:
                fragment("ts_rank(search_vector, websearch_to_tsquery('english', ?))", ^trimmed),
              asc: n.title
            ],
            limit: ^limit,
            select:
              {n,
               fragment(
                 "ts_headline('english', regexp_replace(?, '\\A---\\n.*\\?\\n---\\n', ''), websearch_to_tsquery('english', ?), ?)",
                 n.content,
                 ^trimmed,
                 ^options
               )}
          )
        )
        |> Enum.map(fn {note, headline} -> %{note: note, snippet: snippet_segments(headline)} end)
    end
  end

  defp snippet_segments(nil), do: []

  defp snippet_segments(headline) do
    headline
    |> String.split(@snippet_start)
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {piece, 0} ->
        [{:text, piece}]

      {piece, _} ->
        case String.split(piece, @snippet_stop, parts: 2) do
          [match, rest] -> [{:match, match}, {:text, rest}]
          [text] -> [{:text, text}]
        end
    end)
    |> Enum.map(fn {kind, text} -> {kind, String.replace(text, ~r/\s+/, " ")} end)
    |> Enum.reject(fn {_kind, text} -> text == "" end)
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
