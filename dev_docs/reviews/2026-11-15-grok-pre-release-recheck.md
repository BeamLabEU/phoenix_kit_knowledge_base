# Pre-release recheck: everything since 0.1.0

**Reviewer:** Grok (2026-11-15)
**Range:** `cce536a` (0.1.0, published 2026-11-11) through `c43c138`, which is
Claude's review fixes, then this recheck of that commit and of the unreleased
work on top of it.
**Verdict:** The fixes in `c43c138` hold. This pass found a second way a
colleague's save could be overwritten, and a folder move that threw away the
uuid the tree is keyed by. Both are fixed and covered by tests. Version and
CHANGELOG are untouched; those belong to the release step. Ready for
`hex-publish` when a release is wanted. Suggested version: 0.2.0.

Claude's review is `dev_docs/reviews/2026-11-15-pre-release-review.md`. PR #3
has `dev_docs/pull_requests/2026/3-notes-panel-polish/CLAUDE_REVIEW.md`. This
file does not append to either. Each of Claude's claimed fixes was read
against the code and against the tests that pin it. They match what that
review says.

## What `c43c138` got right

- The panel's `adopt_row/2` takes a fresh row whole only while its hash is the
  buffer's. A different hash raises "Someone else changed this note" and the
  next save is refused as stale.
- Clicking the note that is already open does nothing, so that click cannot
  swap in a peer's hash.
- Trash and rename on the panel re-read the open note through the fence. A
  note that has left the folder is let go of.
- `Code.ensure_loaded?(Leaf)` runs before the notify check. A dev server no
  longer paints a textarea and then swaps in Leaf mid-session.
- Leaf is `>= 0.6.1 and < 1.0.0`, pinned by `test/leaf_contract_test.exs`.
  Leaf 0.11 (`notify`) is not a floor; below it the panel uses a textarea.
- Poll ticks carry `timer_ref`. A hidden-then-reshown panel does not grow a
  second refresh loop.
- Creating in a folder that has moved since it was shown does not recreate
  that folder. "Back" re-reads the listing only while view access still holds.
- VaultLive matches core 3.6's `MediaDragDrop` names (`box_select`,
  `move_picked_to_folder`, `pick_quick_confirm`, plus the older selection
  events) and drops the ones this module does not implement. Re-grepped
  `deps/phoenix_kit/priv/static/assets/phoenix_kit_admin.js`: the whitelist
  matches the hook. Check it again on the next core bump.
- `mix.lock` no longer lists `ex_aws_ec2`.
- README: the vault link is opt-in (`vault_link`); the editor note no longer
  cites core 3.4; core 3.6 loads drag-and-drop from the admin bundle.

## Findings

### BUG - HIGH: Keep mine, and a keystroke before the next poll, wrote the old path

**What was wrong.** `c43c138` stopped the panel from *adopting* a peer's hash.
It did not stop a save from using `@note.relative_path` as it was when the
note was opened. The panel only polls, so a move that happens between polls
is invisible until the next tick. `force: true` ("Keep mine") skips the stale
guard, and `index_entry/4` finds the row by path. Writing the old path
recreated that file, or overwrote a different note that had taken it.

On the vault page the same hole was the other way around. `follow_open_note/1`
refused the whole row when the hash differed, so a peer who edited *and*
moved the note left `@note` on the old path. The next Keep mine wrote that
path back into existence. Trash on the vault page used the same stale path:
after a move it deleted whatever file now lived there, and dropped this
note's row out from under the file that had moved.

**Fix.** `Notes.located_for_save/2` takes the location (`relative_path`,
`folder_path`, `title`, `title_key`) from the row just read, and keeps the
buffer's `content_hash` unless it still matches. A same-hash row is taken
whole. The panel's save re-reads through the fence before it writes. The
vault page does the same on save, rename, move, delete, and on
`:kb_note_saved` / `:kb_vault_changed`. A vanished row is not force-written:
the old path may belong to someone else. AGENTS.md states the rule.

Pinned by `notes_panel_test.exs` (Keep mine after a move and an edit; a
keystroke before the next poll) and `vault_live_test.exs` (Keep mine after a
move and an edit; delete after a move leaves the occupant alone).

### BUG - MEDIUM: a folder move minted a new uuid, so the tree's click missed it

**What was wrong.** `relocate_folder/3` reconciled folder rows by deleting
every path that was no longer on disk and inserting the new path. The sidebar,
drag targets and `@expanded_folders` are keyed by uuid, so the folder the
person was looking at became a different row. Clicking the old picture found
nothing. With `poll: 0` the next "new note" was created in the panel's root,
not in the folder that had moved. Claude's review recorded the collapsed tree
as a nit. The missed click is the same cause, and it changes where a file
lands.

Doing the rewrite *after* reindexing the notes fails for a second reason.
`index_entry/4` indexes the folder a note landed in, so the new path already
has a row by the time the old row is updated. The unique index refuses the
rewrite, and `sync_folders/1` then drops the old uuid.

**Fix.** `relocate_folder/3` rewrites the folder row and every folder under it
onto the new prefix, longest path first, *before* the notes are reindexed.
`sync_folders/1` still runs, which is what picks up an empty directory that
was never indexed. A folder moved on disk by something other than this
function still gets a new uuid: the rescan has none to keep. A name that is a
LIKE wildcard (`50%_off`) does not take a neighbour with it.

The panel's `navigate_folder` reads that uuid again. Inside the fence, the
listing follows the folder and a new note is created there. Outside the
fence, the click says the folder was moved or deleted and does not open the
old path. A poll leaves a current folder whose path no longer exists and
returns to the panel's own folder. The panel stores that folder as a path, so
it does not follow a disappeared listing by uuid.

### BUG - LOW: a subfolder could be recreated after its vault was gone

**What was wrong.** `current_folder_still_there/1` answered `:ok` whenever
`vault` was nil, including when the panel was inside a subfolder. The panel's
own folder is created on demand. A subfolder is not: creating it would rebuild
a tree somebody deleted.

**Fix.** With no vault, only the panel's own folder is still "there". A
subfolder returns to the top with the same notice.

### BUG - LOW: the peer-delete flash was a bare English string

**What was wrong.** `:kb_note_deleted` put "This note was deleted by someone
else." on the flash without `gettext/1`. On a Russian or Estonian page that
one sentence stayed English. The catalogue test exists for this.

**Fix.** It goes through gettext. Russian: "Кто-то другой удалил эту заметку."
Estonian: "Keegi teine kustutas seda märget."

## Left as is, on record

- A click on an unwritten `[[link]]` creates the note in the folder being
  looked at, not beside the note that holds the link. Product choice. Claude
  left it; so does this pass.
- FolderExplorer's inline-rename ids are not prefixed with the panel id. Two
  panels renaming the same folder at the same moment would collide. That is
  core's markup.
- Every host re-render runs a full `load/1`. Caching it has to be careful
  about access changes. Not a release-day change.
- Commit `1f46b8f`'s message describes work this repo does not contain. The
  diff is only `mix.exs` and AGENTS.md. The message stays.
- Two panels on one page: core's drag hook treats `"root"` as a document-wide
  drop target, so a drop on the other panel's tree root lands on this panel's
  folder. The target is still fenced. Changing it means changing core's hook.
- A file deleted on disk while its row remains: the save is `:missing_file`,
  the banner is raised, and Keep mine may write that same note back. The row
  is still this note. A *row* that is gone is not written.
- The panel's people-name cache lives for the life of the component.
- Collaboration rooms are specified and tested, and no LiveView calls
  `room_for/1` yet. Unchanged.
- `scripts/verify_collab.exs` still pins Leaf 0.6.0's silent conflict. Against
  the locked Leaf 0.12, two of its checks go red on purpose. Claude's note
  stands.

## Verification

- `mix precommit` is green: compile `--force --warnings-as-errors`, gettext
  up to date, no unused deps, `hex.audit`, format, `credo --strict`, dialyzer
  (0 errors).
- `mix test`: 369 tests, 0 failures. Integration ran (Postgres on
  `postgres-test`, about 36s of sync tests, no excluded count).
- **Not run:** `scripts/smoke_http.exs`, `verify_links.exs`,
  `verify_collab.exs`, `verify_folder_move.exs`. They need the host app at
  `/www/app`, which is not in this environment. The Leaf editor itself is
  client-side; nothing here can assert its DOM. Use the panel by hand, on
  Leaf 0.12, before publishing.

## For the release entry

Since 0.1.0, on top of Claude's list: a save after someone else moved the
open note writes where the note is now, including Keep mine; trashing it from
the vault page does not remove the file that took the old path; moving a
folder keeps its uuid, so the tree still opens it; a subfolder is not
recreated once its vault is gone. New features in the same range (the notes
panel's tree, Leaf on by default, core floor 3.5.0), so 0.2.0 rather than
0.1.1.
