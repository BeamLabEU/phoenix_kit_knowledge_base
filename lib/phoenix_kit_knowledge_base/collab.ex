defmodule PhoenixKitKnowledgeBase.Collab do
  @moduledoc """
  One `Leaf.Collab.Room` per note, started when somebody opens it.

  Leaf holds a shared document in a process and has no opinion about how those
  processes are named or supervised — that is the host's job, and this is it.

  ## Why a room is temporary

  A room that crashes is not restarted with what it was holding, because it is
  not holding anything any more: the document lived in its state. The next
  person to open the note starts a fresh room, which loads from
  `PhoenixKitKnowledgeBase.Collab.Store` — that is, from the file, which is the
  source of truth anyway. Restarting would only produce an empty room wearing
  the name of a note.

  Rooms stop on their own once the last session leaves; the room writes what it
  was holding on the way down.

  ## Why this is in `children/0`

  `PhoenixKit.Module` collects child specs from every discovered module and
  starts them under core's supervisor, so this needs no host setup. They start
  whether or not the knowledge base is enabled — a registry and an idle
  dynamic supervisor, which cost nothing until a note is opened.
  """

  alias PhoenixKit.PubSubHelper
  alias PhoenixKitKnowledgeBase.Collab.Store
  alias PhoenixKitKnowledgeBase.Schemas.Note

  @registry PhoenixKitKnowledgeBase.Collab.Registry
  @supervisor PhoenixKitKnowledgeBase.Collab.RoomSupervisor

  @doc "Child specs for core's supervisor. See `PhoenixKitKnowledgeBase.children/0`."
  @spec children() :: [Supervisor.child_spec() | {module(), term()}]
  def children do
    [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, name: @supervisor, strategy: :one_for_one}
    ]
  end

  @doc """
  The room holding this note, started if nobody has opened it yet.

  Safe to call from several sessions at once: the loser of the race gets
  `{:already_started, pid}` back from the registry and uses that room, which is
  the whole point of naming them.
  """
  @spec room_for(Note.t()) :: {:ok, pid()} | {:error, term()}
  def room_for(%Note{} = note) do
    case DynamicSupervisor.start_child(@supervisor, room_spec(note)) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Whether a room is currently open for this note, without starting one."
  @spec room_open?(String.t()) :: boolean()
  def room_open?(note_uuid), do: Registry.lookup(@registry, note_uuid) != []

  defp room_spec(note) do
    %{
      id: {Leaf.Collab.Room, note.uuid},
      start:
        {Leaf.Collab.Room, :start_link,
         [
           [
             name: via(note.uuid),
             pubsub: PubSubHelper.pubsub(),
             document_id: note.uuid,
             # Only used for a note with nothing on disk; the store wins
             # whenever it has anything, which is almost always.
             initial_content: note.content || "",
             store: Store
           ]
         ]},
      restart: :temporary
    }
  end

  defp via(note_uuid), do: {:via, Registry, {@registry, note_uuid}}
end
