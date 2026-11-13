# PR #3 — Update the notes panel: media-style list, folder tree with drag and drop, rename from the title

**Author:** alexdont (Sasha Don)
**Reviewer:** Claude (2026-11-13, merge `0bbdbc4`)
**Verdict:** Approve with fixes. There is no migration and no new JavaScript: the
tree is core's `FolderExplorer` and the drag is core's `MediaDragDrop`. Every new
event asks `Places.authorize/3` again (`with_access/3`), and a note that an event
names is re-read and fenced (`fenced_note/2`). One privacy gap and two staleness
bugs were found in the new code, plus a dead click. All are fixed and tested.

## What was checked and is fine

- **Authorization per event.** `move_file_to_folder`, `move_folder_to_folder`,
  `rename_folder`, `start_rename_folder` and the "+" all go through
  `with_access(socket, :edit, …)`. `navigate_folder` and `navigate_root` need
  `:view`. `toggle_folder_expand` and `toggle_sidebar` change only UI state.
  Read-only viewers get no hook and no `data-draggable-*`.
- **Fence.** A drop target or a moved folder must be one the panel knows to be
  below its own folder. A note is re-read with `Notes.get_note/2` and checked
  with `Places.within?/2`. A folder is never moved into itself or below itself.
  A rename target is `Storage.validate_filename/1`'d and stays a sibling.
- **Forged input.** `get_note/2` and `get_folder/2` rescue `Ecto.Query.CastError`,
  and the catch-all `handle_event/3` swallows unknown events, so a forged event
  cannot crash the host's LiveView.
- **Form ids.** The new rename form is `#{@id}-rename`, the create form is
  `#{@id}-create`, and the plain editor is `#{@id}-plain-form`. All are unique
  per panel.
- **Hook.** `MediaDragDrop` is named through `phx-hook` and core registers it.
  There is no inline `<script>`.
- **Gettext.** `gettext.extract --check-up-to-date` is clean, and ru and et carry
  the new strings.
- **No query in mount.** The panel is a LiveComponent, and `init_once/1` only
  sets defaults. Listing happens in `load/1` on `update`.
- **Rename from the title.** Enter submits and blur sends `value`. A blur that
  lands after Escape finds `renaming?` false and does nothing.

## Findings

### IMPROVEMENT - MEDIUM — Bylines fell back to a person's whole email address (fixed)

The new Created / Modified columns labelled people with `Vaults.user_label/1`,
which falls back to `email` when a user has no name or username. That helper
was written for the members page, where a vault manager has to tell people
apart. The panel is a drop-in widget shown to everyone who may read a place,
so any reader could see the email address of every writer who has no name. For
a managed organization it also showed the `.invalid` placeholder address.

**Fix:** the panel uses core's byline, `User.display_name/1` (in core since
2.0.0). It gives the full name, else the username, else the email's local part,
which is how core's comment and marker bylines read. The members page keeps
`user_label/1`.
**Test:** `a writer with no name is not shown by their whole email address`.

### BUG - MEDIUM — Folder events acted on the last poll's picture of a folder (fixed)

`rename_folder`, `move_folder_to_folder` and the drop target of both moves took
the folder from `@tree_folders`. That map is the last poll's listing, and with
`poll: 0` it is the mount's listing. If someone else moved that folder away in
the meantime:
- The rename or move used the stale `relative_path` as its source. If another
  folder had since taken that path, **that other folder** was renamed or moved
  instead.
- A note dropped on the stale folder was moved into its old path, which brought
  a folder nobody can see back into existence.

Nothing could leave the panel's fence, because the stale paths were all inside
it, but the panel changed the wrong thing. `VaultLive` already re-reads the
folder (`Notes.get_folder/2`) for the same events.

**Fix:** `fenced_folder/2` re-reads the folder by uuid on every event that
changes something. It accepts only a folder strictly below the panel's own:
the panel's own folder must not move, because that would move the fence. The
tree keeps using `@tree_folders` to draw and to navigate, which only show
things.
**Tests:** `a folder moved away since the tree was drawn is neither moved nor
renamed` and `the panel's own folder is not renamed or moved from it` (a guard
on the new check).

### IMPROVEMENT - MEDIUM — A partial re-index left the panel on a vanished path (fixed)

`Notes.relocate_folder/3` returns `{:error, {:reindex_incomplete, paths}}` after
the bytes **have** moved. The panel showed the notice but did not follow the
move. A listing of the moved folder stayed on a path that was gone, and an open
note inside it kept a `relative_path` that the next save would fail against.

**Fix:** the rename and move both go through `relocate/3`. It follows the move
(`after_folder_move/3`) on success and on `:reindex_incomplete`, then shows the
notice telling the person to rescan. There is no test: triggering a partial
re-index needs a failing index write in the middle of a move.

### IMPROVEMENT - MEDIUM — The tree's "+" did nothing while a note was open (fixed)

The tree stays beside an open note, but the folder name field is part of the
listing. Clicking "+" set `creating: :folder`, and nothing appeared until the
note was closed. Then the field showed up unasked.

**Fix:** `open_new_folder_modal` leaves the note first, as opening a folder does.
Autosave has already written what was typed.
**Test:** `the tree's "+" beside an open note brings up the folder name field`.

### NITPICK — A drop on another panel's tree root lands on this panel's root (not changed)

With two editable panels on one page, every `MediaDragDrop` instance listens on
every `[data-drop-folder]` in the document. `FolderExplorer` labels every tree
root `"root"`, and the hook sends that as `""`. So a note dragged from panel A
and dropped on panel B's root moves to the top of **panel A's** folder. It stays
inside A's fence, so nothing leaks, but the move is surprising. The fix would
belong in core's hook (scope `"root"` to the hook's own element), not here.

### NITPICK — Each poll now reads the whole subtree (not changed)

The listing used to read one level. It now reads every folder and every note
(without content) below the panel's folder on each poll, for the tree and the
folder counts. That is the trade the tree needs, and `VaultLive` already does
it for a whole vault. A panel on a very large folder pays it every `poll` ms.
`folder_stats/2` is O(folders × notes) in memory, which is fine at sidebar
scale.

## Validation

- `mix precommit` (forced compile with warnings as errors,
  `gettext.extract --check-up-to-date`, `deps.unlock --check-unused`,
  `hex.audit`, format, `credo --strict`, dialyzer): exit 0. The `.pot` and `.po`
  line references were re-synced. No msgid changed.
- `mix test` against the local Postgres, integration included, none excluded:
  347 tests, 0 failures, exit 0.
- Mutation check: with the PR's `notes_panel.ex` restored, the three new
  behaviour tests fail (63 tests, 3 failures in `notes_panel_test.exs`).
