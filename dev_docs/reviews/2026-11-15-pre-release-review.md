# Pre-release review: everything since 0.1.0

**Reviewer:** Claude (2026-11-15)
**Range:** `cce536a` (0.1.0, published 2026-11-11) .. `9f57109`, i.e. PR #3
(notes panel polish), its review fixes `8e9cda3`, the core floor bump `1f46b8f`
and the dependency updates `c18012d` and `9f57109`.
**Verdict:** Ready to release once these fixes land. The dependency jump
(Leaf 0.10 → 0.12, core 3.4 → 3.6) changes how the drop-in panel runs, and the
panel's move and rename paths could overwrite a colleague's save. Both are fixed
and covered by tests.

PR #3 already has its own review
(`dev_docs/pull_requests/2026/3-notes-panel-polish/CLAUDE_REVIEW.md`). This
review re-read the panel independently and found the problems below, which that
review missed. It also checked that the `8e9cda3` fixes are correct; they are.

## Findings

### BUG - HIGH: a move or rename handed a colleague's save to the editor's stale guard

**What was wrong.** `follow_moved_note/2` took the note's fresh row whole. It
runs after a drag into a folder, after any folder move or rename from the tree,
and after the poll sees a rename. `apply_rename/4` did the same with the row
`Notes.rename_note/4` returns. That row is indexed from the file as it is now,
so if someone else had saved in the meantime, `@note.content_hash` became their
hash. The next keystroke then passed the stale guard and overwrote their text
with no prompt. AGENTS.md states the rule plainly: never replace `@note` with a
peer's row. `VaultLive.follow_open_note/1` follows it; the panel did not.

**Fix.** `adopt_row/2` takes a fresh row whole only when its hash matches the
buffer's. Otherwise it takes only where the note now lives (`relative_path`,
`folder_path`, `title`, `title_key`) and raises the "Someone else changed this
note" banner. The next save is then refused as stale, and the person chooses.
`check_open_note/1` uses the same helper, so a colleague who both moves and
edits a note no longer leaves `@note` pointing at a path that is gone.

### BUG - MEDIUM: clicking the note already open had the same effect

**What was wrong.** The open note is drawn in the tree beside the editor and
can be clicked; a `[[link]]` to itself does the same. Either path re-assigned
`@note` from the current row (the peer's hash) and cleared the banner. Leaf's id
is per note, so the browser kept its buffer, and the next keystroke overwrote
the colleague's save.

**Fix.** `switch_to/2` does nothing when the note is already open.

### BUG - MEDIUM: trash and rename acted on the note as it was when opened (also in 0.1.0)

**What was wrong.** `with_open_note/3` used `@note` without reading it again.
Suppose someone moves the open note out of the panel's folder from the admin
page, and the panel is on `poll: 0` or between polls. Trash then deleted the
row of a note now outside the fence: the note disappeared from the vault's
index and its backlinks were cleared until a rescan. If another file had taken
the old path, that file was trashed instead.

**Fix.** `with_open_note/3` reads the note again through the fence and passes
the fresh row on. A note that has left the fence is let go of, with "That note
was moved or deleted." `reload_note` no longer needs its own second read.

### BUG - MEDIUM: in a dev VM the panel detected Leaf too late and swapped editors mid-session

**What was wrong.** `detect_leaf_notify/0` called `function_exported?/3`, which
does not load a module. In interactive mode, which the host's `MIX_ENV=dev`
server uses, Leaf is not loaded until something renders it. So the panel
answered "no notify" and showed the textarea until some other page had shown a
Leaf editor, then switched to Leaf on its next render. With Leaf 0.10 in the
lock this never showed; with 0.12 it does. Release builds preload every module
and were not affected.

**Fix.** `Code.ensure_loaded?(Leaf)` runs first. `test/leaf_contract_test.exs`
unloads Leaf and checks detection still answers `true`. The new test fails on
the old code.

### BUG - MEDIUM: the gate was red, `deps.unlock --check-unused` (`9f57109`)

**What was wrong.** Core 3.6.0 dropped `ex_aws_ec2`, but the lock still carried
it, so `mix precommit` failed at that step.

**Fix.** `mix deps.unlock --unused`.

### BUG - LOW: the Leaf floor admitted versions the code cannot run on

**What was wrong.** `~> 0.5` admits 0.5.x, but the code uses `Leaf.Collab.Store`,
`Leaf.Collab.Room` (both from 0.6.0) and `wiki_links: %{follow: :click}` (0.6.1;
in 0.6.0 clicking a link followed nothing). Core 3.5.0 still admits Leaf back
to 0.4.1, so a host could have resolved such a Leaf.

**Fix.** The requirement is now `>= 0.6.1 and < 1.0.0`, pinned by a test. Leaf
0.11 (`notify`) is not a floor, because the panel falls back to a textarea
below it.

### BUG - LOW: an extra tick started a second timer chain for good

**What was wrong.** A tick cleared `timer_armed?` and re-armed without checking
where it came from. If a host hides the panel and shows it again under the same
id within `poll` ms (a tab behind `:if`), the old instance's pending tick
arrives at the new instance. That added a second permanent chain, and every
further toggle added another.

**Fix.** Each tick carries the ref it was armed with (`timer_ref`), and a
mismatched ref is dropped. `tick: true` stays a refresh from outside the chain;
the tests use it.

### BUG - LOW: creating something in a folder that has since moved brought the folder back

**What was wrong.** `8e9cda3` re-reads drop targets, but "+ Note", "+ Folder"
and a click on an unwritten `[[link]]` still wrote into `@current_folder` as the
last poll saw it. If that folder had been moved, the panel created it again,
empty, at its old path.

**Fix.** `current_folder_still_there/1` checks first. If the folder is gone, the
panel goes back to its top with "That folder was moved or deleted." This is a
new string; ru and et are translated, and gettext's fuzzy guess (which reused
the *note* sentence) was corrected.

### BUG - LOW: Back re-read the listing without asking about access (also in 0.1.0)

**What was wrong.** `close_note` called `load_listing/1` without
`with_access/3`, so after access was withdrawn, Back showed fresh titles.

**Fix.** The note is always closed; the listing is re-read only for someone who
may still see it.

### IMPROVEMENT: VaultLive drops core 3.6's new drag-hook events

Core 3.6's `MediaDragDrop` can also send `box_select`, `move_picked_to_folder`
and `pick_quick_confirm`. None of them can fire on this module's pages: they
need `data-box-area`, a pick mode or a selection, and this module renders none
of those. But AGENTS.md's rule is to match the hook's whole vocabulary, since
an unmatched event crashes the page. They are now dropped, and a test sends all
six. AGENTS.md says to check this list again on every core bump.

### Docs

- README: the admin vault link is opt-in (`vault_link`) since PR #3; the README
  still said admins always get it.
- README: the editor paragraph cited core 3.4.0 and Leaf 0.10. It is
  rewritten for the 3.5 floor.
- README and AGENTS.md: since core 3.6, `MediaDragDrop` is in core's admin
  bundle. A public page fetches it on first mount, and a host that skipped
  `mix phoenix_kit.update` gets a tree that does not drag.
- `DataCase` and the `leaf_notify?` comment described a lock that predates
  `notify` and a fallback that "shows no editor". Both are corrected.

## Left as is, on record

- **NITPICK:** a click on an unwritten `[[link]]` creates the note in the
  folder being looked at, not beside the note holding the link. The two differ
  only when the note was opened from the tree into another folder. This is a
  product choice, not a bug.
- **NITPICK:** after a folder move, the moved folders get new uuids
  (`sync_folders`), so they leave `@expanded_folders` and that part of the tree
  collapses. Cosmetic.
- **NITPICK (core):** FolderExplorer's inline-rename ids
  (`folder-tree-rename-form-<uuid>`) are not prefixed with the panel id. They
  collide only if two panels on one page rename the same folder at the same
  moment. This belongs to core.
- **IMPROVEMENT (also in 0.1.0):** every host re-render runs a full `load/1` (two
  authorize calls, `locate`, the subtree's folders and notes). A host that
  re-renders often pays the poll's cost each time. Caching that needs care
  around access changes, so it is not a release-day change.
- **Commit `1f46b8f`'s message** mentions dropping `Code.ensure_loaded?`
  fallbacks and updating pin-conformance, schema and migration tests. This repo
  has none of those; the commit changed only `mix.exs` and AGENTS.md. Nothing
  to fix, but the message is inaccurate.

## Verification

- `mix precommit` is green: compile `--force --warnings-as-errors`, gettext
  up to date, no unused deps, `hex.audit`, format, `credo --strict`, dialyzer.
- `mix test`: 360 tests, 0 failures, integration included (Postgres up). Every
  new regression test (8 in `notes_panel_test.exs`, plus the Leaf-loading test)
  fails against the code before this review.
- **Not run:** `scripts/smoke_http.exs`, `verify_links.exs`, `verify_collab.exs`
  and `verify_folder_move.exs`. They need the host app at `/www/app`, which is
  not in this environment. Run them, and use the panel by hand with Leaf 0.12
  (the Leaf editor branch is live by default now), before publishing.

## For the release entry (CHANGELOG is written at release)

Since 0.1.0: PR #3's panel changes (folder tree with drag and drop, rename from
the title, dated columns, opt-in `vault_link`); core floor 3.5.0; Leaf floor
0.6.1; with Leaf ≥ 0.11 the panel edits with Leaf. Fixed: a move, rename or
re-open of the open note no longer overwrites a colleague's save; trash and
rename act on the note as it is now; creating in a moved folder no longer
recreates it; Leaf detection in dev; poll timer chains. New features, so 0.2.0
rather than 0.1.1.
