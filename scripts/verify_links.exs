# Exercises the link index against a real database: what a link points at after
# every operation that can change the answer.
#
# This is layer 2 of the three in AGENTS.md. `mix test` cannot reach any of it —
# the suite is deliberately database-free — and `smoke_http.exs` only proves a
# page renders, not that it renders the right note. Resolution is the logic most
# likely to be quietly wrong: a link pointing at the *wrong* note looks exactly
# like one that resolved correctly.
#
# Creates a throwaway vault, checks, and removes it again. Run from the HOST
# app, not this repo:
#
#     cd /www/app
#     mix run --no-start ../phoenix_kit_knowledge_base/scripts/verify_links.exs
#
# Lowercase deliberately: an uppercase name in Elixir is an alias, not a
# constant, and `REPO = DmitriDon.Repo` is a failing match against `Elixir.REPO`.
repo = DmitriDon.Repo
slug = "kbverify"

{:ok, _} = Application.ensure_all_started(:ecto_sql)
# PhoenixKit broadcasts on every note save; without its PubSub the writes still
# succeed but log a warning per note.
{:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
{:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: :phoenix_kit_internal_pubsub)
{:ok, _} = repo.start_link(pool_size: 2)

import Ecto.Query
alias PhoenixKitKnowledgeBase.{Links, Notes, Storage, Vaults}
alias PhoenixKitKnowledgeBase.Schemas.{Folder, Note, Vault}

user = repo.one(from u in PhoenixKit.Users.Auth.User, limit: 1)
scope = %PhoenixKit.Users.Auth.Scope{user: %{uuid: user.uuid, email: user.email}}
dir = Path.join(Storage.root(), "users/#{Storage.email_slug(user.email)}/#{slug}")

cleanup = fn ->
  repo.delete_all(from(v in Vault, where: v.slug == ^slug))
  File.rm_rf(dir)
end

cleanup.()

check = fn results, label, actual, expected ->
  ok? = actual == expected

  detail =
    if ok?, do: "", else: "\n        expected: #{inspect(expected)}\n        actual:   #{inspect(actual)}"

  IO.puts("#{if ok?, do: "ok  ", else: "FAIL"}  #{label}#{detail}")
  [ok? | results]
end

{:ok, vault} = Vaults.create(%{"name" => "KB Verify", "slug" => slug}, scope, :user)

# The directory has to exist before the row does: a vault row pointing at
# nothing fails on the first read, an empty directory is inert.
results = check.([], "vault directory exists after create", File.dir?(dir), true)

note_paths = fn ->
  repo.all(from(n in Note, where: n.vault_uuid == ^vault.uuid, select: n.relative_path))
  |> Enum.sort()
end

disk_paths = fn ->
  Path.join(dir, "**/*.md")
  |> Path.wildcard()
  |> Enum.map(&Path.relative_to(&1, dir))
  |> Enum.reject(&String.starts_with?(&1, ".trash/"))
  |> Enum.sort()
end

# Where a note's single outgoing link points, as a path.
target_of = fn note ->
  case Links.outgoing(Notes.get_note(vault.uuid, note.uuid)) do
    [link] ->
      case link.target_note_uuid do
        nil -> :unresolved
        uuid -> Notes.get_note(vault.uuid, uuid).relative_path
      end

    other ->
      {:unexpected_link_count, length(other)}
  end
end

create = fn title, folder, content ->
  {:ok, note} =
    Notes.create_note(
      vault,
      %{"title" => title, "folder_path" => folder, "content" => content},
      user.uuid
    )

  note
end

# ── Resolution follows the vault as it changes ─────────────────────────────
#
# The bug this exists for: an incremental resolve that only fills *unresolved*
# rows leaves an already-resolved link pointing at whichever note got there
# first, even after a nearer one appears.

a = create.("A", "archive", "See [[Ideas]]")
results = check.(results, "a link to a note nobody has written is unresolved", target_of.(a), :unresolved)

create.("Ideas", "research", "far")
results = check.(results, "creating the note resolves the waiting link", target_of.(a), "research/Ideas.md")

archive = create.("Ideas", "archive", "near")
results = check.(results, "a nearer note takes an already-resolved link", target_of.(a), "archive/Ideas.md")

{:ok, _} = Notes.delete_note(vault, archive)
results = check.(results, "deleting it hands the link back to the survivor", target_of.(a), "research/Ideas.md")

[entry] = Enum.filter(Notes.list_trash(vault), &(&1.original_path == "archive/Ideas.md"))
{:ok, archive} = Notes.restore_note(vault, entry)
results = check.(results, "restoring it takes the link back", target_of.(a), "archive/Ideas.md")

# ── A rename moves a row; it does not add one ──────────────────────────────
#
# `index_entry/4` looks the row up by path, so a rename used to find nothing at
# the new path and insert a second row: the note listed twice, the old entry
# pointing at a file that had moved, and every backlink still on the stale one.

{:ok, renamed} = Notes.rename_note(vault, archive, "Concepts", actor_uuid: user.uuid)
results = check.(results, "renaming returns the note at its new path", renamed.relative_path, "archive/Concepts.md")
results = check.(results, "renaming preserves the note's uuid", renamed.uuid, archive.uuid)
results = check.(results, "renaming leaves no phantom row behind", note_paths.(), disk_paths.())
results = check.(results, "renaming the target away falls back", target_of.(a), "research/Ideas.md")

research = Notes.get_note_by_path(vault.uuid, "research/Ideas.md")
{:ok, moved} = Notes.move_note(vault, research, "archive", actor_uuid: user.uuid)
results = check.(results, "moving preserves the note's uuid", moved.uuid, research.uuid)
results = check.(results, "moving leaves no phantom row behind", note_paths.(), disk_paths.())
results = check.(results, "moving a note nearer wins the tie-break", target_of.(a), "archive/Ideas.md")

# ── Deleting a folder ──────────────────────────────────────────────────────
#
# The linker sits at the root so it survives the folder that goes. `nilify_all`
# on the FK unresolves its link, which is only right if nothing else answers to
# the name.

root_linker = create.("Root", "", "See [[Widget]]")
create.("Widget", "deep/nested", "far")
create.("Widget", "temp", "near")
results = check.(results, "shortest path wins between two candidates", target_of.(root_linker), "temp/Widget.md")

temp = repo.one(from(f in Folder, where: f.vault_uuid == ^vault.uuid and f.relative_path == "temp"))
{:ok, _} = Notes.delete_folder(vault, temp)
results = check.(results, "deleting a folder hands its links to the survivor", target_of.(root_linker), "deep/nested/Widget.md")

cleanup.()

passed = Enum.count(results, & &1)
IO.puts("\n#{passed}/#{length(results)} checks passed")

if passed == length(results) do
  IO.puts("ALL LINK CHECKS PASSED")
else
  IO.puts("SOME LINK CHECKS FAILED")
  # Non-zero so cron and CI fail loudly, matching the rescan Mix task.
  System.halt(1)
end
