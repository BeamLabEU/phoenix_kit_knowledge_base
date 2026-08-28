# Live editing against a real database: what a room writes, and what it refuses.
#
# Layer 2 for `PhoenixKitKnowledgeBase.Collab`. `mix test` cannot reach any of
# it — a room is a process, a flush is a file write plus a reindex, and both
# need a database — and no HTTP check can see it either, because the whole
# point is what happens between keystrokes.
#
# The last four checks document a Leaf bug rather than our behaviour: a flush
# refused as a conflict is recorded, never announced, and the session's work is
# discarded when the room stops. See
# `dev_docs/2026-08-28-leaf-collab-conflict-silent.md`. They are written to
# pass against that behaviour, so this script goes red when Leaf fixes it —
# which is the point.
#
# Creates a throwaway vault, checks, and removes it again. Run from the HOST
# app, not this repo:
#
#     cd /www/app
#     mix run --no-start ../phoenix_kit_knowledge_base/scripts/verify_collab.exs
repo = DmitriDon.Repo
{:ok, _} = Application.ensure_all_started(:ecto_sql)
{:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
{:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: :phoenix_kit_internal_pubsub)
# The room broadcasts on this one; PubSubHelper resolves to it.
{:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: DmitriDon.PubSub)
{:ok, _} = repo.start_link(pool_size: 2)

# What core would start via children/0.
Enum.each(PhoenixKitKnowledgeBase.Collab.children(), fn spec ->
  {:ok, _} = Supervisor.start_link([spec], strategy: :one_for_one)
end)

import Ecto.Query
alias PhoenixKitKnowledgeBase.{Collab, Notes, Storage, Vaults}
alias PhoenixKitKnowledgeBase.Schemas.Vault
alias Leaf.Collab.Room

user = repo.one(from u in PhoenixKit.Users.Auth.User, limit: 1)
scope = %PhoenixKit.Users.Auth.Scope{user: %{uuid: user.uuid, email: user.email}}
slug = "kbcollab"
dir = Path.join(Storage.root(), "users/#{Storage.email_slug(user.email)}/#{slug}")
cleanup = fn -> repo.delete_all(from v in Vault, where: v.slug == ^slug); File.rm_rf(dir) end
cleanup.()

check = fn results, label, actual, expected ->
  ok? = actual == expected
  detail = if ok?, do: "", else: "\n        expected: #{inspect(expected)}\n        actual:   #{inspect(actual)}"
  IO.puts("#{if ok?, do: "ok  ", else: "FAIL"}  #{label}#{detail}")
  [ok? | results]
end

{:ok, vault} = Vaults.create(%{"name" => "KB Collab", "slug" => slug}, scope, :user)
{:ok, note} = Notes.create_note(vault, %{"title" => "Draft", "content" => "# Draft\n\noriginal body\n"}, user.uuid)
{:ok, _other} = Notes.create_note(vault, %{"title" => "Target", "content" => "x"}, user.uuid)

file = Path.join(dir, "Draft.md")

# --- the room loads from disk ---
PhoenixKitKnowledgeBase.Events.subscribe(vault.uuid)
{:ok, room} = Collab.room_for(note)
results = check.([], "a room starts for a note", is_pid(room), true)
results = check.(results, "the room loads the document from disk", Room.snapshot(room).document, File.read!(file))
results = check.(results, "room_open? sees it", Collab.room_open?(note.uuid), true)

# --- a flush writes the file AND reindexes ---
sid = "session-one"
Room.join(room, sid, self(), %{name: "Verifier"})

edited = """
---
status: draft
---

# Draft

Now links to [[Target]] and carries #atag.
"""

Room.adopt(room, sid, edited)
flush_result = Room.flush_now(room)
results = check.(results, "flush_now reports success", flush_result, :ok)
results = check.(results, "the file holds what the room held", File.read!(file), edited)

reindexed = Notes.get_note(vault.uuid, note.uuid)
results = check.(results, "front matter was re-derived", reindexed.frontmatter, %{"status" => "draft"})
results = check.(results, "tags were re-derived", reindexed.tags, ["atag"])

link_target =
  case PhoenixKitKnowledgeBase.Links.outgoing(reindexed) do
    [l] -> l.target_note_uuid && Notes.get_note(vault.uuid, l.target_note_uuid).title
    other -> {:unexpected_links, length(other)}
  end

results = check.(results, "the link graph was re-derived", link_target, "Target")

# --- a second flush of the same session is not a conflict with itself ---
Room.adopt(room, sid, edited <> "\nmore\n")
results = check.(results, "a second flush is not a conflict with our own last write", Room.flush_now(room), :ok)

# --- an edit behind the room's back is a conflict, not an overwrite ---
outside = "# Edited outside the app\n"
File.write!(file, outside)
Room.adopt(room, sid, "# The room's version, typed by two people\n")
conflict = Room.flush_now(room)

results = check.(results, "the outside edit is NOT overwritten", File.read!(file), outside)
results = check.(results, "but flush_now still reports :ok", conflict, :ok)

# Our own warning, since Leaf sends none.
got_warning =
  receive do
    {:kb_note_conflict, %{note_uuid: uuid}} -> uuid == note.uuid
  after
    500 -> false
  end

results = check.(results, "our store broadcasts a conflict warning", got_warning, true)

# Keep typing after the conflict. Nothing is told to anybody.
Room.adopt(room, sid, "# The room's version, with more typing\n")
Process.sleep(3000)
results = check.(results, "still not written after the flush timer fires", File.read!(file), outside)

# The room goes down gracefully — terminate/2 flushes one last time.
GenServer.stop(room)
Process.sleep(200)
results = check.(results, "a graceful stop does not rescue it either", File.read!(file), outside)

{:ok, room2} = Collab.room_for(Notes.get_note(vault.uuid, note.uuid))
results = check.(results, "a fresh room loads the outside copy — the session's work is gone",
                 Room.snapshot(room2).document, outside)

cleanup.()
passed = Enum.count(results, & &1)
IO.puts("\n#{passed}/#{length(results)} checks passed")
if passed == length(results) do
  IO.puts("ALL COLLAB CHECKS PASSED")
else
  IO.puts("SOME COLLAB CHECKS FAILED")
  System.halt(1)
end
