# Progress report — 2026-08-27

Worked the bug list from
[the 2026-08-26 module review](../reviews/2026-08-26-module-review.md). All six
of its "bugs worth fixing this week" are fixed, plus one the review had not
found — which the verification for the others turned up.

## Fixed

**1. Reload did not reload the editor.** `reload_open_note/1` only assigned
`@content`. Leaf's surfaces are `phx-update="ignore"`, so nothing on screen
changed: **Discard mine, reload** and a rescan that altered the open note both
left the old text in the buffer while the server believed it had replaced it.
Now pushes `send_update(Leaf, action: :set_content, …)`, addressed to that
note's `editor_id/1`. Opening a *different* note deliberately does not go
through this — the id is per-note, so that mounts a fresh component.

**2. `[[` autocomplete died at the first space.** Neither trigger set `:token`,
so both inherited Leaf's `[\p{L}\p{N}_-]`. `[[` is now `[^\[\]\n]` — exactly
`Markdown`'s wiki-link class, so every completion is a link the parser reads
back — and `#` is `[\p{L}\p{N}_/-]`, matching the tag regex, so
`#project/alpha` completes.

**3. A viewer could rename a note or start a rescan.** The only two mutating
handlers without `require_write/1`. The title input is `readonly` for a viewer,
but readonly is a DOM property, not a permission. Rescan is gated because it
walks and hashes the whole vault inside the LiveView process, not because it
writes. `MembersLive` re-resolves the actor's role on every membership change
rather than trusting the check done at mount — the page can be open for hours,
long enough for the ownership that opened it to have been taken away.

**4. A resolved link never reconsidered its target.** The one with real teeth.
`resolve_for_note/1` only filled rows whose target was nil, so a link kept
pointing at whichever same-named note got there first, rendering as resolved
with nothing to say it had gone to the wrong note.

Replaced with `Links.reresolve_keys/2`: re-resolve every link naming a given
key, resolved or not. Scoped by key rather than rebuilding the vault, so the
work is proportional to how many notes mention that title. Wired into create,
rename, move, delete, restore — and folder delete, which the review had not
listed and which had the same hole.

The decision half is split out as a pure `changed_targets/2`, so the tie-break
is tested without a database in the same style as `resolve/3`.

**5. Vault directory created after the row.** Reversed to match the comment
that was already sitting above it.

**6. Copy that contradicted the model.** Note and folder deletion said "from
disk… cannot be undone"; both go to `.trash/`. The new-note pane claimed titles
are unique within a vault — they are unique within a *folder*, and two folders
each holding an `Ideas` is the case the tie-break exists for.

## The bug the review did not find

Verifying fix 4 against a live database, one check failed that should have
passed: renaming a note away from a title left the link still pointing at it.

The cause was not the link code. `Notes.index_entry/4` finds the row to update
**by path** — which is the wrong key when the path is what changed. A rename
looked up the *new* path, found nothing, and inserted a second row:

```
before:  index ["Draft.md", "Linker.md"]              disk ["Draft.md", "Linker.md"]
after:   index ["Draft.md", "Final.md", "Linker.md"]  disk ["Final.md", "Linker.md"]
rename_note returned "Draft.md" — the phantom, and the backlink followed it
```

So renaming a note listed it twice in the sidebar, left the old entry pointing
at a file that had moved, returned the stale row to the caller, and kept every
backlink attached to it. `move_note/4` had it too. Rescan-detected renames were
never affected — `relocate/4` updates in place and matches by content hash,
which is why "renames preserve the uuid and every backlink" was true of `mv` in
a shell and false of the rename button.

Fixed by letting the caller name the row: `index_entry(…, existing: note)`.
`Storage.move_note/3` refuses to overwrite an existing file, so the named row
cannot collide with a real note at the target.

This is the third bug in this module found only by exercising a real database,
and it had been shipping since day one.

## Verification

| Layer | Result |
|---|---|
| `mix test` | 174 tests, 0 failures (was 156 — 18 added) |
| `scripts/verify_links.exs` | 15/15 against dev Postgres |
| `scripts/smoke_http.exs` | 6/6 pages render, against a restarted server |

New tests: `test/editor_commands_test.exs` asserts the `set_content` command is
issued at all and pins both suggestion tokens against a re-derived Leaf regex;
`test/links_resolution_test.exs` gains eight cases over the re-resolution
decision, including the review's exact three-step scenario.

`scripts/verify_links.exs` is the review's recommendation 3 — the ad-hoc
live-DB checks, committed. It creates a throwaway vault, checks what a link
points at after each operation, removes it, and exits non-zero on failure. It
is what caught the rename bug.

**The HTTP layer needed a restart to mean anything.** The server had been up
since 2026-08-25, and `mix run --no-start` from `/www/app` recompiles this
module into the same `_build/dev` the live server loads from — so the first
green 6/6 was rendered by templates compiled two days earlier, with new
`.beam` files sitting unread on disk beneath them. `supervisorctl restart
elixir`, then confirming over RPC that the live node really had the new code
(`suggestion_configs/0` returning the new tokens, `Links.reresolve_keys/2`
exported), then re-running: 6/6 again, this time meaning it.

Two things worth keeping from that. `function_exported?/3` answers `false` for a
module the VM has not loaded yet, so it needs `Code.ensure_loaded/1` first or it
reads as a missing function. And how the host app is managed — supervised as the
`elixir` service, restarted with `supervisorctl restart elixir`, never by
killing the pid — was not written down in this repo at all, which is how a plan
for this step got as far as proposing to kill the pid directly. It is in
`AGENTS.md` now.

**And still nothing here can verify the editor.** Fixes 1 and 2 are both
client-side in their effect. The `set_content` command is asserted; whether
Leaf acts on it, and whether the `[[` popup now survives a space, needs a
person in a browser.

## Left open

Untouched from the review, deliberately:

- `VaultLive` is ~1,570 lines and `web/components/` is still empty
- Rescan still runs in the LiveView process
- Global slug uniqueness, the missing file-size cap, the dead image button,
  the `hidden xl:block` context panel, the cwd-relative `root` default, the
  missing catch-all `handle_info`, the N+1 on the vault list
- Folder restore is still per-note, and the README still claims the subtree is
  restorable as a unit — one of those two has to change
- The FK-to-core question. The review's recommendation is to keep the FK and
  close it as a documented deviation; that is a call to make, not a fix.
