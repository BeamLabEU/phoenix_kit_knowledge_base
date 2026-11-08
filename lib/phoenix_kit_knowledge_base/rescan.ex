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

  ## One bad file is one error

  A file the index cannot hold — binary bytes renamed `.md`, a path too long to
  index — is reported in `:errors` and the scan goes on. Everything per file is
  guarded, down to an exception: before this, one such file made the whole
  rescan raise, every time, until somebody found it by hand.

  ## Links are rebuilt wholesale

  Once files have settled, every link in the vault is rebuilt rather than
  patched. Adding one note can change what an *existing* link resolves to,
  because a nearer same-name file may have appeared — an incremental update
  cannot see that, so it would leave links quietly pointing at the wrong note.
  """

  import Ecto.Query

  use Gettext, backend: PhoenixKitKnowledgeBase.Gettext

  alias PhoenixKitKnowledgeBase.{Errors, Events, Links, Notes, Storage}
  alias PhoenixKitKnowledgeBase.Schemas.{Note, Vault}

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

  @doc "A one-line summary of a report, in the current locale."
  @spec summarize(report()) :: String.t()
  def summarize(report) do
    if no_changes?(report) do
      ngettext(
        "Everything already up to date (%{count} note).",
        "Everything already up to date (%{count} notes).",
        report.unchanged
      )
    else
      [
        {report.added, &ngettext("%{count} note added", "%{count} notes added", &1)},
        {report.updated, &ngettext("%{count} note updated", "%{count} notes updated", &1)},
        {report.renamed, &ngettext("%{count} note moved", "%{count} notes moved", &1)},
        {report.removed, &ngettext("%{count} note removed", "%{count} notes removed", &1)},
        {report.folders_added, &ngettext("%{count} folder added", "%{count} folders added", &1)},
        {report.folders_removed,
         &ngettext("%{count} folder removed", "%{count} folders removed", &1)}
      ]
      |> Enum.filter(fn {count, _phrase} -> count > 0 end)
      |> Enum.map_join(", ", fn {count, phrase} -> phrase.(count) end)
    end
  end

  # ── Existing files ────────────────────────────────────────────────────────

  defp reconcile_existing(report, vault, entries, indexed) do
    Enum.reduce(entries, report, fn entry, acc ->
      reconcile_one(acc, vault, entry, Map.fetch!(indexed, entry.relative_path))
    end)
  end

  defp reconcile_one(report, vault, entry, note) do
    if unchanged?(note, entry) do
      Map.update!(report, :unchanged, &(&1 + 1))
    else
      guarded(report, entry, fn -> reindex_if_content_differs(report, vault, entry, note) end)
    end
  end

  # Whatever goes wrong with one file is that file's error, not the scan's.
  # `fun` returns the next report; an exception becomes an error entry instead.
  defp guarded(report, entry, fun) do
    fun.()
  rescue
    exception -> add_error(report, entry.relative_path, {:exception, exception})
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
          {:ok, stat} ->
            try do
              claim_or_add(acc, pool, vault, entry, stat)
            rescue
              exception ->
                {add_error(acc, entry.relative_path, {:exception, exception}), pool}
            end

          {:error, reason} ->
            {add_error(acc, entry.relative_path, reason), pool}
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
          {:ok, _note} ->
            # No per-file link repair here. `run/1` finishes with
            # `Links.reindex_vault/1`, which rebuilds every row from scratch, so
            # anything done per file is overwritten moments later — and the pair
            # that used to be called is the one every other caller was migrated
            # off, because an already-resolved link never reconsidered.
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
      # Same as above: `reindex_vault/1` at the end of the scan is what fixes
      # the link graph, and it fixes all of it.
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

  # Folder rows are reconciled by `Notes.sync_folders/1`, which the folder-move
  # path uses too — the two things that can make the index disagree with the
  # directories on disk, so they must agree about how to fix it.
  defp sync_folders(report, vault) do
    case Notes.sync_folders(vault) do
      {:ok, {added, removed}} ->
        report
        |> Map.update!(:folders_added, &(&1 + added))
        |> Map.update!(:folders_removed, &(&1 + removed))

      {:error, reason} ->
        # The rescan report is the only surface this has. A vault whose
        # directory cannot be listed must not read as a clean scan.
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

  # The described reason, not `inspect/1` of it: a changeset carries the file's
  # whole content, and a note's text has no business in a log line.
  defp add_error(report, path, reason) do
    description = describe(reason)
    Logger.warning("[knowledge_base] rescan could not index #{path}: #{description}")
    Map.update!(report, :errors, &(&1 ++ [%{path: path, reason: description}]))
  end

  defp describe(%Ecto.Changeset{} = changeset), do: Errors.changeset_message(changeset)

  defp describe(:enoent), do: gettext("file disappeared during the scan")
  defp describe(:eacces), do: gettext("permission denied")
  defp describe(:unsafe_path), do: gettext("path escapes the vault directory")

  defp describe({:exception, exception}),
    do: gettext("could not be indexed: %{reason}", reason: Exception.message(exception))

  defp describe(reason), do: inspect(reason)
end
