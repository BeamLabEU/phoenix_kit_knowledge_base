defmodule PhoenixKitKnowledgeBase.Events do
  @moduledoc """
  PubSub notifications so a vault open in two browsers — or two people — stays
  current.

  One topic per vault, carrying every change in it. A per-note topic was the
  obvious alternative and is worse: a viewer would need two subscriptions,
  changes to *other* notes (which move the sidebar, the backlinks panel and the
  unresolved list) would need the vault topic anyway, and a subscriber to both
  would receive every note event twice.

  ## Origin

  Every message carries the pid that caused it, and subscribers ignore their
  own. Without that, the browser that just saved would immediately be told its
  own note changed and offer to reload it from itself.

  ## What this is not

  This keeps *separate* notes in sync and tells you when the note you are
  reading changed underneath you. It is **not** collaborative editing: two
  people typing into the same note at the same time still resolve
  last-writer-wins, caught by the stale-write guard rather than merged. Merging
  concurrent keystrokes needs a CRDT and a different editor integration.
  """

  alias PhoenixKit.PubSubHelper

  @typedoc "A change worth telling other sessions about."
  @type message ::
          {:kb_note_saved, map()}
          | {:kb_note_deleted, map()}
          | {:kb_vault_changed, map()}

  @doc "The topic carrying every change in one vault."
  @spec vault_topic(String.t()) :: String.t()
  def vault_topic(vault_uuid), do: "phoenix_kit_kb:vault:#{vault_uuid}"

  @doc "Subscribe the calling process to a vault's changes."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(vault_uuid), do: PubSubHelper.subscribe(vault_topic(vault_uuid))

  @doc """
  Announce that a note's content changed.

  `hash` lets a receiver tell "somebody saved the bytes I already have" (a
  rescan re-stamping an mtime, say) from a real edit it should react to.
  """
  @spec note_saved(map()) :: :ok
  def note_saved(%{uuid: uuid, vault_uuid: vault_uuid, content_hash: hash}) do
    broadcast(vault_uuid, {:kb_note_saved, %{note_uuid: uuid, hash: hash}})
  end

  @doc "Announce that a note is gone."
  @spec note_deleted(map()) :: :ok
  def note_deleted(%{uuid: uuid, vault_uuid: vault_uuid}) do
    broadcast(vault_uuid, {:kb_note_deleted, %{note_uuid: uuid}})
  end

  @doc """
  Announce a change to the vault's shape rather than to one note's text —
  a folder added or removed, or a rescan that touched many things at once.

  A rescan sends this once instead of a note event per file: reindexing a
  thousand-note vault should not put a thousand messages through every open
  browser to say the same thing.
  """
  @spec vault_changed(String.t(), atom()) :: :ok
  def vault_changed(vault_uuid, reason \\ :structure) do
    broadcast(vault_uuid, {:kb_vault_changed, %{reason: reason}})
  end

  @doc """
  Whether a message came from this process.

  Subscribers use it to skip their own writes.
  """
  @spec own?(map()) :: boolean()
  def own?(%{origin: origin}), do: origin == self()
  def own?(_payload), do: false

  defp broadcast(vault_uuid, {event, payload}) do
    PubSubHelper.broadcast(
      vault_topic(vault_uuid),
      {event, Map.put(payload, :origin, self())}
    )

    :ok
  rescue
    # A host with no PubSub configured must not take a save down with it. The
    # write already succeeded; the only thing lost is the notification.
    error ->
      require Logger
      Logger.warning("[knowledge_base] could not broadcast #{event}: #{inspect(error)}")
      :ok
  end
end
