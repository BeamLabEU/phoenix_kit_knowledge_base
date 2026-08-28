# Moving and renaming a folder, against a real vault.
#
# One operation on a filesystem, so one function: `Notes.relocate_folder/3`.
# The parts worth checking are the ones that go wrong quietly — note uuids (and
# therefore every backlink) surviving the move, empty subdirectories coming
# with it, path-qualified `[[folder/Note]]` links re-resolving, and the four
# refusals holding.
#
# Run from the HOST app, not this repo:
#
#     cd /www/app
#     mix run --no-start ../phoenix_kit_knowledge_base/scripts/verify_folder_move.exs

repo = DmitriDon.Repo
{:ok, _} = Application.ensure_all_started(:ecto_sql)
{:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
{:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: :phoenix_kit_internal_pubsub)
{:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: DmitriDon.PubSub)
{:ok, _} = repo.start_link(pool_size: 2)

import Ecto.Query
alias PhoenixKitKnowledgeBase.{Links, Notes, Storage, Vaults}
alias PhoenixKitKnowledgeBase.Schemas.{Folder, Note, Vault}

user = repo.one(from u in PhoenixKit.Users.Auth.User, limit: 1)
scope = %PhoenixKit.Users.Auth.Scope{user: %{uuid: user.uuid, email: user.email}}
slug = "kbfolder"
dir = Path.join(Storage.root(), "users/#{Storage.email_slug(user.email)}/#{slug}")
cleanup = fn -> repo.delete_all(from v in Vault, where: v.slug == ^slug); File.rm_rf(dir) end
cleanup.()

check = fn results, label, actual, expected ->
  ok? = actual == expected
  detail = if ok?, do: "", else: "\n        expected: #{inspect(expected)}\n        actual:   #{inspect(actual)}"
  IO.puts("#{if ok?, do: "ok  ", else: "FAIL"}  #{label}#{detail}")
  [ok? | results]
end

{:ok, vault} = Vaults.create(%{"name" => "KB Folder", "slug" => slug}, scope, :user)
{:ok, ideas} = Notes.create_note(vault, %{"title" => "Ideas", "folder_path" => "research", "content" => "# Ideas"}, user.uuid)
{:ok, deep} = Notes.create_note(vault, %{"title" => "Deep", "folder_path" => "research/sub", "content" => "# Deep"}, user.uuid)
{:ok, linker} = Notes.create_note(vault, %{"title" => "Linker", "content" => "See [[research/Ideas]] and [[Deep]]"}, user.uuid)
File.mkdir_p!(Path.join(dir, "research/empty"))
Notes.sync_folders(vault)

paths = fn -> repo.all(from n in Note, where: n.vault_uuid == ^vault.uuid, select: n.relative_path) |> Enum.sort() end
folders = fn -> repo.all(from f in Folder, where: f.vault_uuid == ^vault.uuid, select: f.relative_path) |> Enum.sort() end
disk = fn -> Path.wildcard(Path.join(dir, "**/*.md")) |> Enum.map(&Path.relative_to(&1, dir)) |> Enum.sort() end

results = check.([], "the empty directory is indexed", "research/empty" in folders.(), true)

folder = Notes.get_folder_by_path(vault.uuid, "research")
{:ok, moved} = Notes.relocate_folder(vault, folder, "archive")

results = check.(results, "the folder row moved", moved.relative_path, "archive")
results = check.(results, "files moved on disk", disk.(), ["Linker.md", "archive/Ideas.md", "archive/sub/Deep.md"])
results = check.(results, "the index agrees with disk", paths.(), disk.())
results = check.(results, "the empty subdirectory moved with it", "archive/empty" in folders.(), true)
results = check.(results, "the old folder rows are gone", Enum.any?(folders.(), &String.starts_with?(&1, "research")), false)

# uuids, and therefore backlinks, survive
results = check.(results, "the moved note kept its uuid", Notes.get_note(vault.uuid, ideas.uuid).relative_path, "archive/Ideas.md")
results = check.(results, "the nested note kept its uuid", Notes.get_note(vault.uuid, deep.uuid).relative_path, "archive/sub/Deep.md")
results = check.(results, "no phantom rows", length(paths.()), 3)

# links: the path-qualified one named a path that no longer exists
links = Links.outgoing(Notes.get_note(vault.uuid, linker.uuid)) |> Map.new(&{&1.target_key, &1.target_note_uuid})
results = check.(results, "the path-qualified link is now unresolved", Map.get(links, "research/ideas"), nil)
results = check.(results, "the bare link still resolves through the move", Map.get(links, "deep"), deep.uuid)

# refusals
f2 = Notes.get_folder_by_path(vault.uuid, "archive")
results = check.(results, "moving a folder into its own subtree is refused", Notes.relocate_folder(vault, f2, "archive/inner"), {:error, :refuse_descendant})
results = check.(results, "a no-op move is refused", Notes.relocate_folder(vault, f2, "archive"), {:error, :unchanged})
results = check.(results, "escaping the vault is refused", Notes.relocate_folder(vault, f2, "../escape"), {:error, :unsafe_path})

# Moving *onto* something that already exists. This needs a folder that is not
# an ancestor of the target, or `refuse_descendant` fires first and the check
# passes for the wrong reason — which is what it used to do, leaving the guard
# that stops a move from clobbering an existing directory untested.
{:ok, _} = Notes.create_folder(vault, "", "other")
other = Notes.get_folder_by_path(vault.uuid, "other")
results = check.(results, "moving onto an existing path is refused", Notes.relocate_folder(vault, other, "archive"), {:error, :target_exists})

# The vault root, in the target position. `Storage.move_folder/3` refuses it in
# either position; a folder row for the root does not exist, so this is the
# reachable half.
results = check.(results, "moving onto the vault root is refused", Notes.relocate_folder(vault, other, ""), {:error, :refuse_vault_root})
results = check.(results, "nothing was damaged by the refusals", paths.(), disk.())

cleanup.()
passed = Enum.count(results, & &1)
IO.puts("\n#{passed}/#{length(results)} checks passed")
if passed == length(results) do
  IO.puts("ALL FOLDER MOVE CHECKS PASSED")
else
  IO.puts("SOME FOLDER MOVE CHECKS FAILED")
  System.halt(1)
end
