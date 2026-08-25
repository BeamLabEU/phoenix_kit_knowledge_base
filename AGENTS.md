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
  events.ex         per-vault PubSub
  migrations.ex     versioned coordinator (the host's migration calls into this)
  schemas/          five Ecto schemas, all `use PhoenixKit.SchemaPrefix`
  web/              three LiveViews
scripts/smoke_http.exs                   renders every page as a logged-in user
dev_docs/                                date-prefixed working notes (not shipped)
```

## Verifying a change

Three layers, and **none of them alone is sufficient**:

| Layer | Command | Catches | Blind to |
|---|---|---|---|
| Unit | `mix test` | parsing, path safety, resolution, changesets | anything needing a DB or a rendered page |
| Live DB | ad-hoc `mix run --no-start` against the dev app | queries, migrations, indexing, rescan | templates, client-side state |
| HTTP | `scripts/smoke_http.exs` | template crashes, dead renders | client-side JS behaviour |

**`curl` against an admin route proves nothing.** It is never authenticated, so
it always answers `302` to the login page and no template runs. A
`BadBooleanError` in the sidebar was reported green by exactly that check for
several rounds. Use `scripts/smoke_http.exs`, which forges a session cookie.

**Nothing here can verify the editor.** Leaf is client-side; its DOM state and
message timing are outside anything this repo can assert. Two of the day-one
bugs were found by a person using the app, and that is expected to stay true.

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
- `~r{…}` closes at the first `}`, so `\p{L}` breaks it. `~r/…/` interpolates,
  so a literal `#` must be `\#`.

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
