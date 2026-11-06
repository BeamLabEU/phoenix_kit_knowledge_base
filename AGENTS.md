# AGENTS.md

Working notes for anyone — human or model — changing this module.

`README.md` explains what it does for a user. This is the part that isn't
obvious from reading the code, and the part that has already cost time.

## The three invariants

Break any of these and the design stops making sense.

1. **Files are the source of truth. Postgres is a cache.** Every write goes to
   disk first and is then indexed *from what actually landed*, never from what
   the caller intended. Dropping all five tables and running a rescan must
   reproduce the index exactly.
2. **The markdown is the source of truth for everything derived.** Title, front
   matter, tags and the whole link graph come from the file's path and bytes.
   Never store something the text cannot re-derive.
3. **This module never touches core.** Its five tables are all
   `phoenix_kit_kb_*`, it owns their DDL through its own migration coordinator,
   and it emits no DDL outside them. Core is depended on, never modified — not
   even a `CREATE OR REPLACE FUNCTION` (an earlier version did this via
   `Helpers.ensure_uuid_v7_function/1`; it was removed, and no sibling module
   does it either).

## Layout

```
lib/phoenix_kit_knowledge_base.ex        PhoenixKit.Module behaviour: key, tabs, permissions
lib/phoenix_kit_knowledge_base/
  storage.ex        filesystem: path safety, atomic writes, walk, trash   ← security-critical
  notes.ex          notes + folders; write-to-disk-then-index; stale guard
  links.ex          [[wiki-link]] index, backlinks, ambiguity resolution
  markdown.ex       front matter, tags, wiki-link parsing, rendering
  rescan.ex         reconcile index with disk; rename detection by hash
  vaults.ex         vault CRUD, membership, the whole access model
  places.ex         a notes panel's path → vault + folder; the `:authorize` hook
  events.ex         per-vault PubSub
  collab.ex         a Leaf.Collab.Room per note; started from `children/0`
  collab/store.ex   where a live document goes: Notes -> disk -> index
  migrations.ex     versioned coordinator (the host's migration calls into this)
  schemas/          five Ecto schemas, all `use PhoenixKit.SchemaPrefix`
  web/              three LiveViews, NotesPanel (the drop-in widget) + Components
scripts/smoke_http.exs                   renders every page as a logged-in user
scripts/verify_links.exs                 link resolution against a real database
scripts/verify_collab.exs                live editing: what a room writes and refuses
scripts/verify_folder_move.exs           moving a folder, and the four refusals
dev_docs/                                date-prefixed working notes (not shipped)
```

## Verifying a change

Four layers, and **none of them alone is sufficient**:

| Layer | Command | Catches | Blind to |
|---|---|---|---|
| Unit | `mix test` | parsing, path safety, resolution, changesets | anything needing a DB or a rendered page |
| Integration | `PGHOST=… PGUSER=… PGPASSWORD=… PGDATABASE=… mix test` (`test/integration/`, `DataCase`) | `Places`, migrations, the unique-index races — against Postgres and a temp vault root | templates; **excluded with exit 0 when no database answers — read the summary** |
| Live DB | `scripts/verify_links.exs`, `scripts/verify_collab.exs`, `scripts/verify_folder_move.exs`, plus ad-hoc `mix run --no-start` against the dev app | queries, migrations, indexing, rescan, what a link points at, what a room writes, folder moves | templates, client-side state |
| HTTP | `scripts/smoke_http.exs` | template crashes, dead renders | client-side JS behaviour |

**`curl` against an admin route proves nothing.** It is never authenticated, so
it always answers `302` to the login page and no template runs. A
`BadBooleanError` in the sidebar was reported green by exactly that check for
several rounds. Use `scripts/smoke_http.exs`, which forges a session cookie.

**The smoke fixture has a folder and a note inside it, deliberately.** A
`KeyError` on `folder.color` rendered green here for exactly as long as the
fixture vault had no folders: the sidebar tree was empty, so nothing in it ran.
A page that renders is not a page that rendered *something* — `smoke_http.exs`
now asserts the markers the sidebar needs (`kb-folder-explorer`,
`data-draggable-file`, `data-drop-folder`, `data-wikilinks`) rather than only
the status code.

**Nothing here can verify the editor.** Leaf is client-side; its DOM state and
message timing are outside anything this repo can assert. Two of the day-one
bugs were found by a person using the app, and that is expected to stay true.

### The host app, which layers 2 and 3 both need

This module is a path dependency of `/www/app` (`DmitriDon`), and both lower
layers run from *there*, not from here. `/www/app/AGENTS.md` is the authority on
that app; what matters here:

- **The server is supervised.** `supervisorctl` owns it as the `elixir`
  service, with `autorestart=true`, started by `/usr/local/bin/start-elixir.sh`.
  Restart it with **`supervisorctl restart elixir`** — never by killing the pid,
  which supervisord will simply restart out from under you. `supervisorctl
  status` for its uptime, `/var/log/elixir.log` for its output.
- **`MIX_ENV=dev`**, set container-wide by `/etc/supervisor/conf.d/elixir-app.conf`
  and inherited by every shell, so every `mix` command here builds into
  `_build/dev`.
- **Running `mix` in `/www/app` recompiles this module into the same
  `_build/dev` the live server loads from.** The running VM keeps the code it
  already has in memory, so a `mix run --no-start` leaves new `.beam` files on
  disk under an old server — harmless, but it means **layer 3 tests whatever
  was compiled at boot, not your change.** Restart before believing a green
  `smoke_http.exs`.
- **The node is named**, so the live system can be driven without restarting it
  — useful when a second `mix phx.server` would only fail to bind port 4000
  (`PHX_SERVER=true` is set):

  ```bash
  elixir --sname rpc$$ --cookie $(cat ~/.erlang.cookie) \
    --rpc-eval app@$(hostname -s) 'IO.inspect(:ok)'
  ```

## Gotchas, all of them paid for

**Elixir / Ecto**

- `import Ecto.Query` brings in `update/2` — it shadows a context function of the
  same name. `except: [update: 2, update: 3]`.
- A constraint violation inside `Repo.transaction/1` returns `{:error, :rollback}`
  and *discards the changeset* unless you call `repo.rollback(changeset)`
  explicitly — callers then never learn why the save failed. **No code here uses
  transactions any more** (see "Why there are no transactions" below), but this
  bites the moment anyone adds one.
- `websearch_to_tsquery`'s first argument is a `regconfig`. A bound parameter is
  typed as an OID and Postgrex refuses to encode a string into it — and Ecto
  refuses a module attribute interpolated into a fragment's first argument. It
  has to be a literal `'english'` in the fragment string.
- `ilike/3` takes no `escape:` option; use
  `fragment("? ILIKE ? ESCAPE '\\'", …)`.
- Uppercase names are **aliases**, not constants. `REPO = MyApp.Repo` is a
  failing match against `Elixir.REPO`.
- `Notes.update_content/4` and `index_entry/4` take `broadcast:` and
  `resolver:`. A caller writing on somebody else's behalf (the collaboration
  store, flushing from a room) must pass `broadcast: false` — `:kb_note_saved`
  carries the *writer's* pid as origin, so a room's write is nobody's own and
  every session with that note open raises "changed by someone else" against
  its own typing. A caller indexing many notes must pass a shared `resolver:`,
  or each call rebuilds one by scanning every note in the vault.
- `Notes.index_entry/4` finds the row to update **by path**, which is the wrong
  key when the path is what changed. A rename or move must pass
  `existing: note`, or it finds nothing at the new path, inserts a second row,
  and leaves the note listed twice with every backlink still on the stale one.
- `~r{…}` closes at the first `}`, so `\p{L}` breaks it. `~r/…/` interpolates,
  so a literal `#` must be `\#`.

**Core's components**

> **The declared constraint is `>= 2.14.0 and < 4.0.0`.** 2.14.0 is the first
> published core carrying both `FolderExplorer`'s `items` attr and `:item`
> slot (2.13.15 has those; 2.13.14 was never published) and the
> `<.context_menu>` components the vault tree's right-click menus use. An
> older locked core fails at compile time, which is the good failure mode —
> at runtime it would be an undefined-slot raise on render. The upper bound
> admits core 3.x: verified against 3.0.0, which still calls
> `migration_module/0` + `migrated_version_runtime/1` / `current_version/0`
> for module-owned tables — this module's coordinator already speaks that.
> Core 3.0 requires an existing install to be at V225 (2.65.0) first; that is
> a host-upgrade concern, not a code one. For cross-repo work against a local
> checkout: `PHOENIX_KIT_PATH=../phoenix_kit`.

- `PhoenixKitWeb.Components.FolderExplorer` is **not** in core's default
  imports — `use PhoenixKitWeb, :live_view` brings in `Components.Core.*` only.
  Import it explicitly.
- Every control is `phx-target={@myself}`, which is a LiveComponent contract.
  From a plain LiveView pass `myself={nil}`: HEEx omits a nil attribute, so the
  events arrive at the LiveView instead.
- Its event names are MediaBrowser's (`navigate_folder`, `toggle_folder_expand`,
  `rename_folder`, …) and cannot be renamed by a consumer. We implement its
  vocabulary rather than fork the component.
- Leaves are keyed by folder uuid with `"root"` for the top level, and each item
  needs an `:id` — that is what becomes `data-draggable-file`. `tree_items/2`
  builds the map; it loads **every** note in the vault, which is the first thing
  to change if a vault outgrows what a sidebar can show.
- `Folder` carries a **virtual** `:color`. Core reads it through `Map.get/2`
  since 2.13.14, so this is now belt-and-braces rather than load-bearing — it
  still matters for anyone running an older core.

**LiveView**

- `VaultLive` has a catch-all `handle_info/2` and must keep one. Leaf adds
  messages between versions and `Leaf.Collab` sends several; an unmatched
  clause is a `FunctionClauseError` that takes the view down with the editor in
  it.
- Core's `MediaDragDrop` hook speaks a vocabulary wider than this module uses —
  `move_selected_to_folder`, `delete_selected`, `long_press_select` come from a
  multi-select feature we do not have. They are matched and dropped on purpose:
  unhandled, they crash the LiveView.
- Anything that **moves the open note** must re-read its row (`refresh_open_note/1`).
  `@note.relative_path` is what `save_content/3` writes against, and the
  `:kb_note_saved` broadcast cannot fix it — it comes from the same pid, so
  `Events.own?/1` drops it.

**HEEx**

- `:if={@x}` accepts nil truthiness, but `@x and …` **raises** on nil. Use
  `not is_nil(@x) and …` or `&&`.
- `<template>` is not rendered by browsers. For a `:for` inside a grid, wrap in
  `<div class="contents">`.

**Leaf**

- Its editing surfaces are `phx-update="ignore"`. LiveView never patches them
  after mount, so changing the `content` assign does nothing — replacing content
  needs `send_update(Leaf, action: :set_content, …)`.
- Therefore **the component id must be per-note** (`editor_id/1`). A constant id
  reuses the hook across notes and every note shows whatever loaded first.
- Leaf debounces, so a `:leaf_changed` for the note you just left can arrive
  after switching. Match `editor_id` against the open note and drop stale
  payloads, or you write one note's text into another's file
  (`save_decision/3`).
- `dirty: false` means the buffer still matches what was loaded. Ignore it, or
  merely opening a note rewrites its file.
- **Visual and HTML modes are denied on purpose.** They round-trip through HTML,
  and YAML front matter is `---`-delimited — it would come back as a horizontal
  rule plus a paragraph, destroying every property.
- Leaf's JS is lazy-loaded from jsDelivr by core's vendored `phoenix_kit.js`, not
  bundled. It needs network and a permissive `script-src`.
- **A `Leaf.Collab.Room` stops itself once you let it.** Leaf 0.6.0's
  `{:DOWN, …}` clause dropped the session and returned `{:noreply, …}` — no
  stop, no idle timeout — so a room outlived everyone in it; that is why
  `Collab.close_room/1` exists and whatever opens a room must call it. Leaf
  ≥ 0.8 (what the lock resolves) adds `:idle_after`: the room stops itself
  when empty, so pass `idle_after:` in `Collab.room_spec/1` when rooms get
  wired to the UI and `close_room/1` becomes a backstop rather than the only
  way down.
- **A conflict is no longer silent in Leaf ≥ 0.8.** 0.6.0 set `conflict: true`,
  stopped writing, kept answering `:ok` from `flush_now/1`, and discarded the
  document in `terminate/2`. 0.8.0 answers `{:error, :conflict}` from
  `flush_now/1` and tells everyone on the topic `{:leaf_conflict, …}` once per
  conflict (plus `{:leaf_conflict_cleared, …}` on recovery). `Collab.Store`
  still broadcasts `Events.note_conflict/2` as well — keep it until the
  LiveView handles `:leaf_conflict` itself; written up in
  `dev_docs/2026-08-28-leaf-collab-conflict-silent.md`. Note
  `scripts/verify_collab.exs` pins the 0.6.0 behaviour on purpose, so two of
  its checks go red against 0.8.0 — that is the signal, not a failure.
- A suggestion trigger with no `:token` inherits Leaf's default,
  `[\p{L}\p{N}_-]`, which closes the popup at the first space — so `[[` never
  completes a title with a space in it, and `#` never completes `#project/alpha`.
  Set `:token` to match the parser: `Markdown`'s wiki-link regex is
  `[^\[\]\n]+`, and its tag regex is `[\p{L}\p{N}_/-]`. Pinned by a test,
  because inheriting the wrong default fails nothing.

**Filesystem**

- Timestamps at second resolution are not unique. Trash directories carry a
  random suffix because two deletes in the same second overwrote each other.
- Anything user-supplied that becomes a path goes through
  `Storage.validate_filename/1` (creates) or is accepted verbatim (indexing
  what already exists). Those two paths are deliberately asymmetric.

## Why there are no transactions

`Repo.transaction/1` appears nowhere in `lib/`, and that is deliberate rather
than an oversight.

A write here is: put bytes on disk, then index them. A database transaction
cannot roll back a file write, so wrapping the pair buys nothing and costs a
held-open transaction across filesystem I/O. The failure mode is instead made
harmless: if the disk write succeeds and indexing fails, the note exists and the
next rescan picks it up. If the disk write fails, nothing is indexed. **The disk
is never the thing that ends up wrong.**

The same reasoning applies to `Rescan.run/1`, which would otherwise hold a write
transaction open for the length of a full vault scan. Every step in it is
idempotent, so an interrupted rescan leaves a partly-updated index that the next
run finishes — better than a rolled-back one that has to start over.

The cost, stated plainly: a crash between writing a note's row and rebuilding its
links leaves the link index briefly stale. A rescan repairs it, and the index is
disposable by design (invariant 1).

## Conventions

- **Working notes** → `dev_docs/<YYYY-MM-DD>-<topic>.md`, never `docs/` (that is
  generated output). Progress reports → `dev_docs/reports/`. Kept out of the Hex
  package `files:` and out of ex_doc `extras:`.
- **Tables** are `phoenix_kit_kb_*`, UUIDv7 primary keys, and every schema does
  `use PhoenixKit.SchemaPrefix` — a test scans `lib/` to enforce it, because
  omitting it only breaks on named-schema installs.
- **Never hardcode a PhoenixKit path.** Everything goes through
  `PhoenixKitKnowledgeBase.Paths`, which wraps `PhoenixKit.Utils.Routes.path/1`.
- **No JavaScript.** The editor is Leaf, rendering is core's MDEx; the module
  ships no assets and asks the host for no build step. Keep it that way unless
  there is no alternative.
- Before inventing a layout or a convention, look at `phoenix_kit` and the
  sibling modules (`phoenix_kit_boards`, `phoenix_kit_inbox`) — they are the
  reference for how a module is expected to behave.

## Open question

`phoenix_kit_kb_vault_members.user_uuid` has a real FK to `phoenix_kit_users`
with `on_delete: :delete_all`. Boards and Inbox both use a bare `:binary_id`.
The argument for keeping it: theirs is attribution, ours is authorization, and an
orphaned membership row is a dangling permission grant. The argument against: it
couples our schema to core's, and no sibling does it. Unresolved.
