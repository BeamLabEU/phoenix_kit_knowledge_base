# Module review — 2026-10-31

A second full pass over the module after two months of upstream movement:
`phoenix_kit` went from the locked 2.13.13 to 2.65.0 on Hex, and `leaf` from
0.6.0 to 0.8.0. Working tree was clean on `main` at `fb71478` when the review
started; the fixes below are the uncommitted diff on top of it.

## Overall

The module is in good shape. The three invariants — files are the source of
truth, the markdown is the derivation source, this module never touches core —
are still held in the code, not just in `AGENTS.md`. I re-read the
security-critical paths specifically: double path containment
(`safe_relative/1` + `resolve/2`), symlink skipping via `lstat`, atomic
temp-plus-rename writes, trash containment (`purge` refuses anything outside
`.trash/`), and per-event authorization (`require_write` in `VaultLive`,
`require_manage` re-resolved from the current scope in `MembersLive`, role
re-resolved on `delete_vault`). No holes found. Every mutating `handle_event`
gates on write except the read-only ones, and `overwrite_note` is effectively
gated by `save_content`'s `can_write` check.

The one thing that was genuinely broken was the build itself: **the committed
`mix.lock` did not compile.** See below.

## Gate

| Layer | Command | Result |
|---|---|---|
| Unit | `mix test` | 190 tests, 0 failures |
| Static | `mix compile --force --warnings-as-errors` | clean |
| Lint | `mix credo --strict` | no issues |
| Format | `mix format --check-formatted` | clean |

All against `phoenix_kit` 2.65.0 and `leaf` 0.8.0 (what the updated lock
resolves). Layers 2 and 3 (`scripts/verify_*.exs`, `smoke_http.exs`) need the
host app and a live Postgres, which this environment does not have — **not run
here**.

## Fixed in this pass

1. **Stale lock / unbuildable HEAD.** `mix.lock` pinned `phoenix_kit` 2.13.13,
   which lacks both `FolderExplorer`'s `items` attr / `:item` slot and the
   `<.context_menu>` components the last two commits use, so a fresh
   `mix deps.get` + `mix test` died with `undefined function context_menu/1`.
   Lock updated to 2.65.0; constraint in `mix.exs` raised `~> 2.0` → `~> 2.14`
   (verified against Hex: 2.14.0 is the first published core with the context
   menus; 2.13.14 was never published, 2.13.15 has the slot but not the
   menus). This closes the "bump it the moment it is published" item
   `AGENTS.md` left open. `AGENTS.md`'s warning block rewritten to match.
2. **Uppercase `.MD` files were indexed but unlinkable.** The walk accepts
   `Note.MD` (downcased comparison) but `title_from_path/1`, `Links.path_key/1`
   and the suggestion `drop_extension/1` stripped only a lowercase `.md`, so
   such a note got the title `"Note.MD"` and a bare `[[Note]]` never resolved
   to it. New `Storage.drop_extension/1` strips case-insensitively; all three
   call sites route through it; pinned by tests.
3. **Dead code:** `Links.unresolve_stale/1` was never called — rename/move
   already re-resolve both directions via `reresolve_keys/2`, and its doc
   claimed otherwise. Removed.
4. **N+1 on the vault list.** `IndexLive` ran `count_notes/1` per card; now one
   grouped query via `Notes.count_notes_by_vault/1`.
5. **Stale docs:** README test counts (51/156 → 190); a duplicated sentence and
   a broken comment line in `editor_id/1`'s doc; `AGENTS.md`'s two Leaf
   gotchas were outdated — **leaf 0.8.0 self-stops rooms via `:idle_after` and
   announces flush conflicts itself** (`{:leaf_conflict, _}`,
   `flush_now/1` returns `{:error, :conflict}`). Rewritten; CHANGELOG updated.

## Open items

Carried over from `2026-08-26-module-review.md` (still true, deliberately
untouched — each is a decision, not a bug):

- `VaultLive` is ~2,100 lines with sidebar/panes as function components in the
  same file; the LiveView should be events and loading.
- Rescan runs in the LiveView process; a large vault freezes that tab. Fix is
  `Task.async` + the existing one-shot `:rescan` broadcast.
- No file-size cap on indexing — `stat_note/2` reads whole files, and the
  front-matter YAML is parsed from them. A few-MB ceiling with the oversize
  file reported in the rescan error list is enough.
- The image/video toolbar buttons are dead controls (`{:leaf_insert_request}`
  is swallowed) — deny them or flash "no uploads in this version".
- The context panel is `hidden xl:block`, so backlinks/outgoing vanish below
  xl.
- `root` defaults to cwd-relative `priv/knowledge_base` — wrong for a release.
- Folder restore is per-note while the README claims subtree-intact restore;
  empty directories are not restored. One of the two has to change.
- Global slug uniqueness: two users cannot both have a personal vault
  `research`. Decide whether personal vault URLs need an owner segment.
- `search_vector` is generated from raw `content`, front matter included.
- The `phoenix_kit_kb_vault_members.user_uuid` FK-to-core question (kept, with
  reasoning, in `AGENTS.md`).

New from this pass:

- **The collab layer is groundwork, not wired.** `Collab.room_for/1` /
  `close_room/1` are only called from `scripts/verify_collab.exs`; no LiveView
  opens a room. When wiring it up: pass `idle_after:` in `room_spec` (leaf ≥
  0.8 rooms self-stop when empty, so `close_room/1` becomes a backstop), handle
  `{:leaf_conflict, _}` / `{:leaf_conflict_cleared, _}` in `VaultLive` (the
  catch-all currently just logs them), and `Collab.Store`'s
  `Events.note_conflict/2` broadcast becomes redundant with Leaf's own message.
  Note that `scripts/verify_collab.exs` pins the 0.6.0 silent-conflict behavior
  on purpose — two of its checks will go red against leaf 0.8.0. That is the
  signal, not a failure.

## What I could not verify here

- Layers 2 and 3 (live-DB scripts, HTTP smoke) — no host app, no Postgres in
  this environment. The updated lock pulls leaf 0.8.0 and newer transitives;
  the unit suite passes against them, but the DB-backed scripts have not been
  run against 0.8.0.
- The editor itself. Leaf's DOM state is outside anything this repo can
  assert; that stays true by design.
