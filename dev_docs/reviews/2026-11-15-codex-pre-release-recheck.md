# Pre-release recheck after Claude and Grok

**Reviewer:** Codex, 2026-11-15.
**Range:** `cce536a` (published 0.1.0) through `1a86ff8`, including PR #3,
Claude's `c43c138` fixes and Grok's `1a86ff8` fixes.
**Result:** Four additional findings fixed below. Local validation passes,
including real Postgres integration tests. Authenticated host and browser
checks remain outstanding before publication. No version bump, tag or publish.

The previous reviews are
[`2026-11-15-pre-release-review.md`](2026-11-15-pre-release-review.md) and
[`2026-11-15-grok-pre-release-recheck.md`](2026-11-15-grok-pre-release-recheck.md).
Their fixes remain useful: in particular, rereading the current note location
before saving protects the occupant of its former path, and folder moves keep
the uuids the tree uses. This pass found other callers that still violated the
buffer-hash rule, plus access checks that stopped at initial navigation.

## BUG — HIGH: the admin editor still adopted a peer's hash

Three paths replaced `@note` with a current row while Leaf retained its older
browser buffer:

- A patch to the already-open note ran `open_note/2` again. Clicking the sidebar
  entry or following a self-link can cause that patch.
- A file or folder drag called `refresh_open_note/1`, which took the entire
  current row. Even moving an unrelated item refreshed the open note this way.
- Selecting the current folder called a no-op `Notes.move_note/4`. That bypasses
  the filesystem stale check and returns the current row, which the handler
  assigned whole.

After a peer saved, each path replaced the buffer's `content_hash` with the
peer's. The next keystroke silently overwrote their file. All four regression
tests (same-note patch, file drag, folder drag and no-op select) reproduced the
overwrite before the fix.

**Fix:** reuse `follow_open_note/1` for these paths. It takes the current
location while preserving the buffer's hash through `Notes.located_for_save/2`.
Same-note navigation retains content and conflict state. Explicit Reload uses
`load_note/2` and `:set_content` to replace both buffer and hash; a separate
regression test confirms that editing can resume after that choice.

## BUG — HIGH: a reused notes panel retained the previous context's editor

LiveComponents survive host updates under the same id. A host changing `path`
loaded the new listing but left the previous folder's open note and content in
place. Changing `current_user` had the same problem for private notes whenever
the next user already had a vault: the new user's vault existed, so
`release_note_without_vault/1` did not close the old user's editor. The result
could expose the previous user's private content in the new context.

The cached admin link also belonged to the old context; its cache key contained
only the vault uuid.

**Fix:** compare the parsed place and user uuid on host updates. A changed
context releases the editor, folder selection, drafts, expanded folders, people
cache and admin-link cache before loading. A cosmetic update preserves the
editor and its original hash. Host updates also check the open note through the
current fence, as polling already did.

Two regression tests reproduced the old editor surviving a path change and a
private-user change. A third ensures that a cosmetic update keeps the editor
and still refuses to overwrite a peer's save.

## BUG — MEDIUM: the selected visibility could leave the host's allowed set

`visibility_options` was reassigned on every host update, but `init_once/1`
retained the previous selection unconditionally. A host replacing the options
with `[:shared]` could leave the component displaying and editing private notes
with no switch visible.

**Fix:** retain the selection only while it remains allowed. Otherwise use the
allowed default or first option, then reset the context as above. The regression
test removes the selected private option and verifies that the private editor
disappears and the shared listing appears.

## BUG — HIGH: an open admin vault page outlived its membership

`VaultLive` checked access during navigation, then trusted `@can_write` for
browser events and Leaf autosaves. A member downgraded from editor to viewer
could keep saving and deleting from the open page. A removed member could
continue searching the vault and receiving fresh data through PubSub-triggered
reloads. `MembersLive` already reread access for its actions; the vault page did
not.

**Fix:** attach LiveView lifecycle checks to both `:handle_event` and
`:handle_info`. Each checks current vault membership using `Vaults.fetch_for/2`
with the current scope and refreshes the role and permission assigns before
the handler runs. A removed member is redirected to the vault list before a
read or mutation runs. Checking messages is essential: Leaf autosaves and
PubSub refreshes arrive there, rather than as browser events.

Three regression tests failed before the fix: autosave after demotion, search
after removal, and PubSub refresh after removal. They now pass; the demotion
test also verifies that deletion is refused. Revocation is enforced on the
next event or message; already-delivered content cannot be withdrawn.

## Verification

- Baseline: **369 tests, 0 failures**, integration included.
- Added **12 tests**. Ten failed against the corresponding pre-fix code; two
  preserve intended behavior (cosmetic host updates and explicit reload).
- Focused admin/panel suite: **106 tests, 0 failures**.
- Final full suite: `PGPOOL=8 mix test --max-cases 6` — **381 tests, 0 failures**,
  including integration against Postgres. No integration exclusion notice.
- `mix precommit` — passed: forced compile with warnings as errors, gettext
  extraction check, unused-lock check, Hex advisory audit, format, strict Credo
  and Dialyzer (zero errors).
- `mix docs --warnings-as-errors --output /tmp/kb-codex-docs` — passed.
- `mix hex.build --output /tmp/kb-codex-release-check.tar` — passed using the
  unchanged development version, 0.1.0. This validates packaging only.
- Gettext source references were regenerated and merged; no new wording or
  translations were needed.
- No core changes, new tables, migrations, transactions or JavaScript.

**Not run:** `scripts/smoke_http.exs`, `scripts/verify_links.exs`,
`scripts/verify_collab.exs`, `scripts/verify_folder_move.exs`, or browser testing.
The documented host app `/www/app` is absent. The integration test router does
not exercise core's admin chrome, and it cannot verify Leaf's client DOM or
message timing. Run those host checks with the new code loaded and use the
editor by hand before publishing. The existing collaboration script still has
the documented Leaf 0.6 conflict expectations; interpret those checks against
the locked Leaf 0.12 as described in AGENTS.md.

## Release notes to carry forward

Keep the earlier reviews' proposed 0.2.0 feature scope. Add these fixes to its
release entry: same-note navigation and drag operations preserve stale-write
protection; embedded panels release old editors when their user, path or
allowed visibility changes; open vault pages enforce membership changes before
further events and messages. Version and CHANGELOG changes belong to the
release commit.
