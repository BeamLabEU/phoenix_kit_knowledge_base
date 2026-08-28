defmodule PhoenixKitKnowledgeBase.Collab.Store do
  @moduledoc """
  Where a live document goes: through `Notes`, onto disk, and into the index.

  `Leaf.Collab.Store.File` ships with Leaf and describes exactly this
  arrangement — the file is the document, its hash is checked before writing,
  and a note edited from outside is answered with a conflict rather than
  overwritten. It is not used here for one reason: it writes the file and stops
  there.

  A note is not only its bytes. Its title, front matter, tags, outgoing links
  and search vector are all derived from those bytes, and writing the file
  without re-deriving them leaves Postgres describing a note that no longer
  exists — invariant 1 says the index is disposable, not that it may be wrong.
  `Notes.update_content/4` already writes to disk and indexes what landed, and
  already carries the stale guard, so this store is a thin adapter onto it.

  ## The two callbacks

  `save/2` is a no-op. It is called on every change and is meant for a store
  cheap enough to write to constantly; a file plus a reindex is the expensive
  copy, which is what `flush/2` is for. If losing seconds of a session ever
  matters more than it does now, `save/2` is where a row in a table would go.

  `flush/2` runs when the writing pauses, at a bounded interval while it
  continues, and once when the room stops.

  ## Conflict

  `{:error, :conflict}` means the file moved underneath the session — someone
  edited the note outside the editor, or a rescan re-stamped it. The room stops
  flushing and keeps the document, which is the right answer: the work in the
  file is somebody's, and this session's copy is not more entitled to exist.
  Resolving it needs a person.

  The note row is re-read on every flush rather than held, because the previous
  flush changed it: `Notes.update_content/4` compares the file's hash against
  the row's, so a stale row would report a conflict against this session's own
  last write.
  """
  @behaviour Leaf.Collab.Store

  require Logger

  alias PhoenixKitKnowledgeBase.{Events, Notes, Storage}

  @impl true
  def load(note_uuid) do
    with {:ok, note, vault} <- Notes.fetch_with_vault(note_uuid),
         {:ok, stat} <- Storage.stat_note(vault.directory, note.relative_path) do
      # Read from disk, not from the indexed copy. The file is the source of
      # truth, and a note changed outside the app since it was last indexed
      # should open as what it actually says.
      #
      # And when it *has* changed, the row is re-indexed here rather than left
      # behind. `flush/2`'s guard compares the file against the row, so a room
      # holding the newer bytes while the row still describes the older ones
      # would conflict on its very first flush — in exactly the case this
      # disk-first read exists to serve, which would make the feature useless
      # for a vault people also edit in vim.
      reindex_if_drifted(vault, note, stat)

      {:ok, %{document: stat.content, revision: 0}}
    else
      _ ->
        # No note, or no file. `:error` means "start from nothing", and the room
        # falls back to the `initial_content` it was given.
        :error
    end
  end

  defp reindex_if_drifted(vault, note, stat) do
    if stat.hash != note.content_hash do
      # Broadcast: other sessions are looking at a stale sidebar entry for a
      # note that changed on disk, and this is the moment we found out.
      Notes.index_entry(vault, note.relative_path, stat)
    end

    :ok
  end

  @impl true
  def save(_note_uuid, _snapshot), do: :ok

  @impl true
  def flush(note_uuid, %{document: document}) do
    case Notes.fetch_with_vault(note_uuid) do
      {:ok, note, vault} -> write(vault, note, document)
      :error -> {:error, :note_gone}
    end
  end

  defp write(vault, note, document) do
    # `broadcast: false`, then one vault-level message instead. `index_entry/4`
    # would announce `:kb_note_saved` with this room's pid as the origin, which
    # is nobody's own write — so every session with that note open would fail
    # the `own?` check, see a hash it does not hold (it is mid-edit), and raise
    # the "changed by someone else, reload?" banner against its own typing,
    # every couple of seconds. Accepting that reload pushes `set_content` into
    # the live buffer and discards unflushed keystrokes.
    #
    # A vault-level change still refreshes sidebars and counts, which is what
    # sessions not in this room actually need.
    case Notes.update_content(vault, note, document, broadcast: false) do
      {:ok, _note} ->
        Events.vault_changed(vault.uuid, :note)
        :ok

      {:error, :stale} ->
        # Our name for it; Leaf's is `:conflict`, and the room only knows that
        # one. Same event: the bytes on disk are not the bytes we last saw.
        #
        # Announced on our own topic because Leaf will not announce it. The room
        # records the conflict, stops writing, and tells nobody — no broadcast,
        # no reply, and `flush_now/1` answers `:ok` either way — so without this
        # people go on typing into a document that is never written again and is
        # dropped when the room stops. This message is the only warning there
        # is; see the conflict section above.
        Events.note_conflict(note.vault_uuid, note.uuid)
        {:error, :conflict}

      {:error, :missing_file} ->
        # The file was deleted while a session had it open. Not a conflict —
        # there is nothing to conflict with — but not something to recreate
        # behind the deleter's back either.
        {:error, :missing_file}

      {:error, reason} ->
        Logger.warning(
          "[knowledge_base] collab flush failed for #{note.uuid}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end
end
