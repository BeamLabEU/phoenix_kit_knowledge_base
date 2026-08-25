defmodule PhoenixKitKnowledgeBase.Rescan do
  @moduledoc """
  Reconciles a vault's index with what is actually on disk.

  There is no file watcher by design, so this is how edits made outside the web
  UI — `vim`, a script, Obsidian, `git pull` — become visible. Run it from the
  Rescan button, or call it from a Mix task or a cron job.

  ## How change is detected

  Cheap first, authoritative second. A file whose `(mtime, size)` still match
  the index is skipped without being read, which is what keeps a rescan of a
  large vault fast. Anything else gets hashed, and only a differing hash counts
  as a real change — so `touch`, a `git checkout` that rewrites mtimes, or a
  save that produced identical bytes cost one read and no reindex.

  ## Renames survive

  A file that disappeared plus a new file with identical content is a **move**,
  not a delete and a create. Recognising that keeps the note's uuid, and with it
  every permalink and every backlink pointing at it. Without this step, `mv
  Ideas.md archive/Ideas.md` in a shell would quietly break every link into that
  note — the single most likely thing anyone does outside the app.

  Identical *content* is the only signal available after the fact. Two genuinely
  distinct notes with byte-identical content are indistinguishable here; pairing
  them off arbitrarily is still better than dropping both uuids, and the
  resulting index is correct either way.

  ## Links are rebuilt wholesale

  Once files have settled, every link in the vault is rebuilt rather than
  patched. Adding one note can change what an *existing* link resolves to,
  because a nearer same-name file may have appeared — an incremental update
  cannot see that, so it would leave links quietly pointing at the wrong note.
  """

  import Ecto.Query

  alias PhoenixKitKnowledgeBase.{Events, Links, Notes, Storage}
  alias PhoenixKitKnowledgeBase.Schemas.{Folder, Note, Vault}

  require Logger

  @typedoc "What a rescan did, for reporting back to whoever pressed the button."
  @type report :: %{
          added: non_neg_integer(),
          updated: non_neg_integer(),
          removed: non_neg_integer(),
          renamed: non_neg_integer(),
          unchanged: non_neg_integer(),
          folders_added: non_neg_integer(),
          folders_removed: non_neg_integer(),
          errors: [%{path: String.t(), reason: String.t()}]
        }

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @doc """
  Reconcile one vault and return what changed.

  Not run in a transaction, deliberately. A rescan of a big vault would hold a
  write transaction open for its whole duration, and every step here is
  independently idempotent — an interrupted rescan leaves a partially updated
  index that the next run finishes, rather than a rolled-back one that has to
  start over.
  """
  @spec run(Vault.t()) :: {:ok, report()} | {:error, term()}
  def run(%Vault{} = vault) do
    with :ok <- Storage.ensure_vault(vault.directory),
         {:ok, entries} <- Storage.list_notes(vault.directory) do
      indexed = indexed_by_path(vault.uuid)
      on_disk = MapSet.new(entries, & &1.relative_path)

      # Rows whose file is gone: either renamed (claimed below) or deleted.
      missing = for {path, note} <- indexed, not MapSet.member?(on_disk, path), do: note

      {existing_entries, new_entries} =
        Enum.split_with(entries, &Map.has_key?(indexed, &1.relative_path))

      base = %{
        added: 0,
        updated: 0,
        removed: 0,
        renamed: 0,
        unchanged: 0,
        folders_added: 0,
        folders_removed: 0,
        errors: []
      }

      report =
        base
        |> reconcile_existing(vault, existing_entries, indexed)
        |> reconcile_new(vault, new_entries, missing)

      report = remove_orphans(report, vault, missing)
      report = sync_folders(report, vault)

      Links.reindex_vault(vault.uuid)
      touch_vault(vault)

      # One announcement, not one per file: reindexing a thousand-note vault
      # should not put a thousand messages through every open browser to say the
      # same thing. Sent even when nothing changed, because a browser showing a
      # stale sidebar has no way to know that.
      Events.vault_changed(vault.uuid, :rescan)

      {:ok, report}
    end
  end

  @doc "Reconcile every vault, for a Mix task or a scheduled job."
  @spec run_all([Vault.t()]) :: [{Vault.t(), {:ok, report()} | {:error, term()}}]
  def run_all(vaults), do: Enum.map(vaults, &{&1, run(&1)})

  @doc "An empty report, so callers can render 'nothing to do' without a special case."
  @spec empty_report() :: report()
  def empty_report do
    %{
      added: 0,
      updated: 0,
      removed: 0,
      renamed: 0,
      unchanged: 0,
      folders_added: 0,
      folders_removed: 0,
      errors: []
    }
  end

  @doc "True when a rescan found nothing to do — the common case, worth saying plainly."
  @spec no_changes?(report()) :: boolean()
  def no_changes?(report) do
    report.added == 0 and report.updated == 0 and report.removed == 0 and
      report.renamed == 0 and report.folders_added == 0 and report.folders_removed == 0
  end

  @doc "A one-line summary of a report."
  @spec summarize(report()) :: String.t()
  def summarize(report) do
    if no_changes?(report) do
      "Everything already up to date (#{report.unchanged} notes)."
    else
      [
        {report.added, "added"},
        {report.updated, "updated"},
        {report.renamed, "moved"},
        {report.removed, "removed"},
        {report.folders_added, "folders added"},
        {report.folders_removed, "folders removed"}
      ]
      |> Enum.filter(fn {count, _label} -> count > 0 end)
      |> Enum.map_join(", ", fn {count, label} -> "#{count} #{label}" end)
    end
  end

  # ── Existing files ────────────────────────────────────────────────────────

  defp reconcile_existing(report, vault, entries, indexed) do
    Enum.reduce(entries, report, fn entry, acc ->
      note = Map.fetch!(indexed, entry.relative_path)

      if unchanged?(note, entry) do
        Map.update!(acc, :unchanged, &(&1 + 1))
      else
        reindex_if_content_differs(acc, vault, entry, note)
      end
    end)
  end

  # The cheap comparison: same size and same mtime means don't even open it.
  defp unchanged?(%Note{} = note, entry) do
    note.file_size == entry.size and
      note.file_mtime != nil and
      DateTime.compare(DateTime.truncate(note.file_mtime, :second), entry.mtime) == :eq
  end

  defp reindex_if_content_differs(report, vault, entry, note) do
    case Storage.stat_note(vault.directory, entry.relative_path) do
      {:ok, stat} when stat.hash == note.content_hash ->
        # Same bytes, different mtime — a touch, or a checkout. Record the new
        # mtime so the next rescan takes the cheap path again, but don't count
        # it as a change, because nothing the reader cares about changed.
        note
        |> Ecto.Changeset.change(file_mtime: stat.mtime, file_size: stat.size)
        |> repo().update()

        Map.update!(report, :unchanged, &(&1 + 1))

      {:ok, stat} ->
        case Notes.index_entry(vault, entry.relative_path, stat, broadcast: false) do
          {:ok, _note} -> Map.update!(report, :updated, &(&1 + 1))
          {:error, reason} -> add_error(report, entry.relative_path, reason)
        end

      {:error, reason} ->
        add_error(report, entry.relative_path, reason)
    end
  end

  # ── New files, and renames ────────────────────────────────────────────────

  defp reconcile_new(report, vault, entries, missing) do
    # Index the vanished notes by content so a new file can claim one.
    by_hash =
      missing
      |> Enum.filter(& &1.content_hash)
      |> Enum.group_by(& &1.content_hash)

    {report, _remaining} =
      Enum.reduce(entries, {report, by_hash}, fn entry, {acc, pool} ->
        case Storage.stat_note(vault.directory, entry.relative_path) do
          {:ok, stat} -> claim_or_add(acc, pool, vault, entry, stat)
          {:error, reason} -> {add_error(acc, entry.relative_path, reason), pool}
        end
      end)

    report
  end

  defp claim_or_add(report, pool, vault, entry, stat) do
    case Map.get(pool, stat.hash) do
      [note | rest] ->
        # A file with these exact bytes disappeared from somewhere else: same
        # note, new home. Keeping its uuid keeps every backlink and permalink.
        pool =
          if rest == [], do: Map.delete(pool, stat.hash), else: Map.put(pool, stat.hash, rest)

        case relocate(vault, note, entry.relative_path, stat) do
          {:ok, _note} -> {Map.update!(report, :renamed, &(&1 + 1)), pool}
          {:error, reason} -> {add_error(report, entry.relative_path, reason), pool}
        end

      _ ->
        case Notes.index_entry(vault, entry.relative_path, stat, broadcast: false) do
          {:ok, note} ->
            Links.resolve_for_note(note)
            {Map.update!(report, :added, &(&1 + 1)), pool}

          {:error, reason} ->
            {add_error(report, entry.relative_path, reason), pool}
        end
    end
  end

  defp relocate(vault, note, new_path, stat) do
    result =
      note
      |> Note.changeset(%{
        "vault_uuid" => vault.uuid,
        "relative_path" => new_path,
        "content" => stat.content,
        "content_hash" => stat.hash,
        "file_mtime" => stat.mtime,
        "file_size" => stat.size
      })
      |> repo().update()

    with {:ok, moved} <- result do
      if moved.folder_path != "", do: Notes.index_folder_chain(vault, moved.folder_path)
      # The name changed, so links to the old one stop resolving and links
      # waiting for the new one start.
      Links.unresolve_stale(moved)
      Links.resolve_for_note(moved)
      {:ok, moved}
    end
  end

  # ── Deletions ─────────────────────────────────────────────────────────────

  defp remove_orphans(report, vault, missing) do
    # Anything still missing after rename detection really is gone. Re-read
    # each row rather than trusting the earlier snapshot: a rename claimed some
    # of them and moved them to paths that now exist.
    orphans =
      missing
      |> Enum.map(& &1.uuid)
      |> then(fn uuids -> if uuids == [], do: [], else: still_missing(vault, uuids) end)

    if orphans == [] do
      report
    else
      {count, _} = repo().delete_all(from(n in Note, where: n.uuid in ^orphans))
      Map.update!(report, :removed, &(&1 + count))
    end
  end

  defp still_missing(vault, uuids) do
    from(n in Note, where: n.uuid in ^uuids, select: {n.uuid, n.relative_path})
    |> repo().all()
    |> Enum.reject(fn {_uuid, path} -> Storage.note_exists?(vault.directory, path) end)
    |> Enum.map(fn {uuid, _path} -> uuid end)
  end

  # ── Folders ───────────────────────────────────────────────────────────────

  defp sync_folders(report, vault) do
    case Storage.list_folders(vault.directory) do
      {:ok, on_disk} ->
        indexed = repo().all(from(f in Folder, where: f.vault_uuid == ^vault.uuid))
        indexed_paths = MapSet.new(indexed, & &1.relative_path)
        disk_paths = MapSet.new(on_disk)

        added =
          disk_paths
          |> MapSet.difference(indexed_paths)
          |> Enum.count(&match?({:ok, _}, Notes.index_folder_chain(vault, &1)))

        gone = indexed |> Enum.filter(&(not MapSet.member?(disk_paths, &1.relative_path)))

        removed =
          if gone == [] do
            0
          else
            {count, _} =
              repo().delete_all(from(f in Folder, where: f.uuid in ^Enum.map(gone, & &1.uuid)))

            count
          end

        report
        |> Map.update!(:folders_added, &(&1 + added))
        |> Map.update!(:folders_removed, &(&1 + removed))

      {:error, reason} ->
        add_error(report, "(folders)", reason)
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp indexed_by_path(vault_uuid) do
    from(n in Note, where: n.vault_uuid == ^vault_uuid)
    |> repo().all()
    |> Map.new(&{&1.relative_path, &1})
  end

  defp touch_vault(vault) do
    vault
    |> Ecto.Changeset.change(last_scanned_at: DateTime.utc_now())
    |> repo().update()
  end

  defp add_error(report, path, reason) do
    Logger.warning("[knowledge_base] rescan could not index #{path}: #{inspect(reason)}")
    Map.update!(report, :errors, &(&1 ++ [%{path: path, reason: describe(reason)}]))
  end

  defp describe(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end

  defp describe(:enoent), do: "file disappeared during the scan"
  defp describe(:eacces), do: "permission denied"
  defp describe(:unsafe_path), do: "path escapes the vault directory"
  defp describe(reason), do: inspect(reason)
end
