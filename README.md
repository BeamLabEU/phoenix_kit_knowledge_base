# PhoenixKitKnowledgeBase

An Obsidian-style linked knowledge base for [PhoenixKit](https://hex.pm/packages/phoenix_kit),
backed by **real markdown files on disk**.

```
priv/knowledge_base/users/fotkin-gmail-com/research/
├── Inbox.md
├── papers/
│   ├── Attention Is All You Need.md
│   └── Ideas.md
└── Ideas.md
```

A vault is a directory. A folder is a directory. A note is a `<Title>.md` file —
the filename *is* the title. So `rg`, `git`, `pandoc`, `vim`, `fzf` and Obsidian
itself all work on the tree directly. Postgres only indexes it.

## Install

```elixir
# host mix.exs
{:phoenix_kit_knowledge_base, "~> 0.1"}
```

```elixir
# host config/config.exs
config :phoenix_kit_knowledge_base,
  root: Path.expand("../priv/knowledge_base", __DIR__)
```

```bash
mix deps.get
mix phoenix_kit.update    # creates the five phoenix_kit_kb_* index tables
```

Enable **Knowledge Base** on the admin Modules page and grant the
`knowledge_base` permission to the roles that should have it.

Nothing else is asked of the host. The editor is [Leaf](https://hex.pm/packages/leaf)
— the same one PhoenixKit uses elsewhere — and rendering goes through core's MDEx
+ sanitizer. This module ships **no JavaScript**: no compiler entry, no script
tag, no `app.js` import.

> **How Leaf's JS arrives.** Core's vendored `phoenix_kit.js` registers a
> placeholder `Leaf` hook that lazy-loads `leaf.js` from jsDelivr on first
> mount, pinned to the version core depends on, then copies the real hook onto
> itself. That is core's mechanism, not this module's, and it has two
> consequences worth knowing: the browser needs to reach `cdn.jsdelivr.net`, and
> a strict `script-src` CSP has to allow it. If neither is acceptable, vendor
> `deps/leaf/priv/static/assets/leaf.js` yourself and load it before `app.js` —
> the loader short-circuits when `window.LeafHooks.Leaf` already exists.

## The storage model

**Files are the source of truth. Postgres is a cache.**

The index holds the note's content (for full-text search), its parsed front
matter, its tags, and the whole link graph. Every bit of that is derived from the
markdown — drop the tables, run a rescan, and it comes back identical.

```
<root>/system/<vault-slug>/…                organisation vaults
<root>/users/<email-slug>/<vault-slug>/…    personal vaults
```

To adopt notes you already have, move or symlink the directory into place, create
a vault with the matching slug, and press Rescan.

## Keeping the index honest

There is no filesystem watcher. Web edits index themselves; anything else is
picked up by a rescan:

```bash
mix phoenix_kit_knowledge_base.rescan            # every vault
mix phoenix_kit_knowledge_base.rescan research   # one vault
mix phoenix_kit_knowledge_base.rescan --quiet    # only report changes; for cron
```

or the **Rescan** button on any vault. A rescan:

- compares `(mtime, size)` first and only hashes what looks changed, so a large
  vault stays fast and a `touch` or a `git checkout` costs one read and no
  reindex;
- **detects renames by content hash** — a file that vanished plus a new file with
  identical bytes is a move, so the note keeps its uuid and every backlink and
  permalink into it survives. Without this, `mv Ideas.md archive/` in a shell
  would silently break every link to that note;
- removes index rows for deleted files, leaving links into them unresolved
  rather than dropping the mentions;
- rebuilds every link in the vault afterwards, because adding one note can change
  what an *existing* link resolves to.

Exits non-zero if any vault reported errors, so a cron job fails loudly.

### The web UI never clobbers an external edit

Before every save, the file's current hash is compared with the indexed one. If
they differ — you edited it in `vim` since opening the page — the save is
**refused**, and the UI offers to reload from disk or overwrite deliberately.
That is the difference between "eventually consistent" and "silently loses work".

### Titles are not unique

The filesystem allows `research/Ideas.md` and `archive/Ideas.md`, so the index
describes that rather than rejecting it. A bare `[[Ideas]]` resolves to:

1. a note in the **same folder** as the linking note, then
2. the **shortest path**, then
3. alphabetical order, so the answer is stable rather than whichever row came
   back first.

Write `[[research/Ideas]]` to be explicit. Path-qualified links match the path
and are never ambiguous.

## Two browsers, two people

Every vault page subscribes to a PubSub topic for that vault, so changes
propagate live:

- **another note changed** → your sidebar, backlinks and unresolved list refresh
- **the note you're reading changed** → replaced immediately, since there is
  nothing to lose in reading view
- **the note you're editing changed** → announced with a banner, never replaced;
  reloading is your call, because your buffer may hold unsaved keystrokes
- **the note you're on was deleted** → you're returned to the vault
- **a rescan ran anywhere** — including `mix phoenix_kit_knowledge_base.rescan`
  in a terminal — → every open browser refreshes

A rescan emits **one** message, not one per file: reindexing a thousand notes
should not push a thousand messages through every open browser to say the same
thing. Messages carry the pid that caused them and subscribers ignore their own,
so the browser that just saved is never told to reload its own work.

### What happens when two people edit the same note

Not merged — **detected**. Before every write the file's hash is compared with
the one indexed when you opened it. The second writer is stopped with
`{:error, :stale}` and shown a banner with two explicit choices: *discard mine
and reload*, or *keep mine and overwrite*.

Autosave never resolves this on its own. An earlier version passed `force:` once
a conflict was flagged, reasoning that "saving again is an explicit overwrite" —
which is wrong under autosave, where saving again is just continuing to type.
Overwriting somebody's work is now only ever reachable through the button.

This is last-writer-wins with a guard rail, not collaborative editing. Two
people typing into the *same note* at the same time will keep tripping the
conflict banner. Real co-editing needs a CRDT and editor-level integration; two
people working on *different notes* in a shared vault is fully supported and is
the common case.

## Vaults and access

A vault is the namespace links resolve in — `[[Foo]]` never crosses a vault
boundary.

| | System vault | Personal vault |
|---|---|---|
| Created by | anyone with `knowledge_base.manage_system_vaults` | any user of the module |
| Implicit owner | everyone with that sub-permission | its creator |
| Visible to | its implicit owners, plus members | its owner, plus members |

Both share one membership model, so a personal vault can be shared with three
colleagues without becoming org-wide:

| Role | May |
|---|---|
| `owner` | everything, including membership and removing the vault |
| `editor` | create, edit, move and delete notes and folders |
| `viewer` | read |

**An administrator does not get implicit access to other people's personal
vaults.** `manage_system_vaults` stops at system vaults on purpose.

**But membership is enforced in the application, not the filesystem.** The notes
are files; anyone with shell access to the server can read every vault. That is
inherent to storing notes as files. If it matters, put personal vaults on a
subtree with restrictive permissions, or don't use this model.

Removing a vault deletes its row and its index — **not its files**. Notes are the
durable artifact; a mis-click in a web UI should not `rm -rf` somebody's writing.
Re-create the vault with the same slug and rescan to get it all back.

## File names

The filename **is** the title, plus `.md` — Obsidian's scheme, so a note created
here is indistinguishable from one created there:

```
Réunion, 2026 — notes!.md    →    title "Réunion, 2026 — notes!"
research/Ideas.md            →    title "Ideas", folder "research"
```

Spaces, punctuation and unicode are preserved verbatim. Names are **rejected
with a reason**, never silently repaired — typing `Ideas: Part 2` tells you `:`
isn't allowed rather than quietly filing a note called `Ideas Part 2`.

Refused, matching Obsidian:

| Characters | Why |
|---|---|
| `* " \ / < > : \| ?` | illegal or hostile on some filesystem this vault will be synced to |
| `[ ] # ^` | break link syntax — `Ideas [draft]` can't be written as `[[Ideas [draft]]]` |
| leading `.` | would make the note a hidden file, invisible to the scan |
| trailing `.` | ambiguous on Windows |
| `CON`, `COM1`, `LPT1`, … | Windows device names; the file cannot exist there at all |

Names over 200 bytes are refused rather than truncated.

**Files that already exist are indexed whatever they're called.** The rules above
govern names *this app creates*. Something made in Obsidian or a shell gets
indexed as-is — refusing to show a note because of its name would be worse than
the name.

## Trash

Deleting a note moves it to `.trash/` inside the vault — the same place Obsidian
puts its own deletions — rather than unlinking it. Being a dotfile, `.trash` is
skipped by the scan, so trashed notes leave the index, search and the link graph
without any special-casing, and a rescan never resurrects them.

```
.trash/1787697480-a1b2c3/research/Ideas.md
       └── deleted at   └── original path, verbatim
```

The original path is preserved under a per-deletion directory, so **restore is a
move** with no name to un-mangle, and deleting, recreating and deleting the same
note again keeps both copies rather than one overwriting the other.

The Trash panel lists what's there with **Restore**, **Delete permanently** and
**Empty**. Restoring reindexes the note and re-resolves every link that was
waiting for its title. It refuses to overwrite a note written at that path since.

Deleting a folder trashes the whole subtree, so the folder can be restored
intact.

## Writing

Notes are plain markdown, and everything the app knows is derived from the text:

- **YAML front matter** — Obsidian's "properties". Shown above the note, kept
  whole on a round trip, never rendered into the prose. Invalid YAML leaves the
  block visible in the body instead of swallowing what's underneath.
- **Tags** — front matter `tags:` merged with inline `#tags`, downcased. Nested
  tags (`#project/alpha`) work. A markdown heading is never a tag.
- **`[[Wiki-links]]`** — `[[Target]]`, `[[Target|alias]]`, `[[Target#heading]]`,
  `[[folder/Target]]`.

Tags and links are read only from *outside* code, so a `[[Foo]]` in a fenced
block stays literal rather than becoming a phantom entry in the unresolved list.

### Unresolved links are a feature

A link to a note that doesn't exist is stored as a real row, not discarded. So
clicking a dangling link offers to create it, the sidebar lists everything the
vault has referred to but not written (ordered by how many notes want it), and
writing a note **retroactively resolves** every link already pointing at its
title — write "Foo" and the six notes that mentioned `[[Foo]]` last week wire
themselves up, untouched.

### Editing

Obsidian's model, and only that: clicking a note puts you in the editor, the
editor is already a rendered view, and there is no second "reading" surface. Leaf
in **hybrid mode** — its Obsidian-style live preview, where formatting renders
inline while the source markers stay editable. Edits autosave.

Until Leaf renders `[[wiki-links]]` they are literal text in the editor; the
right-hand panel lists a note's outgoing links so navigation does not depend on
it. See [the Leaf spec](dev_docs/2026-08-25-leaf-collaboration-spec.md).

**Visual and HTML modes are denied.** Both round-trip the document through HTML,
and YAML front matter is `---`-delimited — which survives that trip as a
horizontal rule and a paragraph, silently destroying every property on the note.
Hybrid and markdown modes edit the source directly and are safe.

Autosave ignores Leaf's non-dirty change events, so merely opening a note never
rewrites its file.

### `[[` and `#` autocomplete

Leaf's inline-suggestion triggers, so this is the real thing: a caret-anchored
popup, ↑↓ to move, Enter or Tab to accept, Escape to dismiss, working
mid-paragraph because the client knows where the caret is.

- `[[` completes note titles, showing each note's folder as a sublabel
- `#` completes tags, showing how many notes carry each

Both allow creating what doesn't exist yet, so you can link ahead of yourself.
A suggestion whose title several notes share is inserted **path-qualified**
(`[[research/Ideas]]`), so the link records which note it meant instead of
leaving it to the tie-break.

Configuring the `#` trigger also tells Leaf that `#` means "tag" here, so
hashtags render as tinted tokens in the editor. `#` at the first column still
opens a heading — the trigger is `:not_line_start`, so the two never contend for
a keystroke.

## Search

Full-text over the cached content via a generated `tsvector` with a GIN index.
The title is weighted above the body, so an exact-title hit outranks a passing
mention. Queries are parsed with `websearch_to_tsquery`, so quoted phrases and
`-exclusions` work and punctuation can't produce an error.

Full-text matches whole words; the link picker and quick lookups use a separate
`ILIKE` path so they respond to a half-typed word.

## Path safety

Every path is built from user-supplied text — titles, folder names, vault slugs —
so containment is enforced twice, in two different ways:

1. the input is rejected outright if it is absolute, contains a `..` segment at
   any depth, or contains a NUL byte;
2. the joined result is expanded and re-checked to still be under the base.

Symlinks *inside* a vault are skipped rather than followed, so a planted link
can't pull `/etc/passwd` into an index. Filenames are sanitised (separators
stripped, leading dots removed so a note can't become an invisible file, byte-
truncated without splitting a codepoint). Writes are atomic — temp file plus
rename — so no reader ever sees a half-written note.

There are 35 tests on this module alone.

## Schema

Five index tables, all `phoenix_kit_kb_`-prefixed, UUIDv7 keys, created by this
module's own versioned coordinator:

| Table | Holds |
|---|---|
| `phoenix_kit_kb_vaults` | vault metadata, its directory, last scan time |
| `phoenix_kit_kb_vault_members` | per-vault membership |
| `phoenix_kit_kb_folders` | an index of the directories on disk |
| `phoenix_kit_kb_notes` | path, cached content, tags, front matter, hash/mtime/size |
| `phoenix_kit_kb_note_links` | the link index, including unresolved links |

Every schema uses `PhoenixKit.SchemaPrefix`, so installs into a named Postgres
schema (`--prefix "auth"`) work; a test scans `lib/` so a new schema can't
silently skip it.

## Routes

| Path | Page |
|---|---|
| `/admin/knowledge-base` | vault list |
| `/admin/knowledge-base/:vault` | workspace |
| `/admin/knowledge-base/:vault/notes/:id` | a note |
| `/admin/knowledge-base/:vault/notes/new?title=…` | create the note an unresolved link points at |
| `/admin/knowledge-base/:vault/members` | membership |

The workspace routes are one LiveView, so moving between notes patches the note
pane rather than remounting the sidebar.

## Not in this version

Each a clean addition later; none needs a schema change:

- **Filesystem watcher.** Deliberate — rescan is explicit. `inotify` via
  `file_system` would make it live.
- **Attachments.** External image URLs render; Leaf's image button opens its
  by-URL dialog. There is no upload path — wiring `upload_handler` to core's
  `MediaBrowser` is the obvious way in.
- **Graph view.** The link index is already there; this is a JS rendering job.
- **Note history.** No revisions table — though the vault is a directory, so
  `git init` in it gives you exactly that.
- **Collaborative editing.** Concurrent edits to one note are detected, not
  merged. The route to Google-Docs-style editing is mapped out in
  [the Leaf spec](dev_docs/2026-08-25-leaf-collaboration-spec.md): `y_ex` holds the CRDT
  server-side, Postgres holds it while a note is open, and the `.md` file is
  flushed on a timer — files are deliberately not real-time. The blocker is
  Leaf needing a document model, not the CRDT layer.
- **Presence.** No "3 people viewing this vault" indicator.
- **Folder rename in the UI.** `mv` the directory and rescan.

## Development

```bash
mix deps.get
mix test          # 126 tests, no database required
mix quality       # format, credo --strict, dialyzer
```

Tests are database-free by design: they cover markdown parsing, path containment
and filename rules against a real temp directory, link-resolution tie-breaking,
editor identity, changeset invariants, behaviour compliance, route ordering and
migration version bookkeeping. The database-backed paths (indexing, rescan,
search) are exercised against a live Postgres instead.

### Rendering pages

`mix test` has no endpoint, so it cannot catch a mistake in a template — and an
unauthenticated `curl` never gets past the login redirect, so it never renders
one either. A `BadBooleanError` in the sidebar reached the browser through
exactly that gap. `scripts/smoke_http.exs` closes it by forging a session cookie
and fetching every page as a logged-in user:

```bash
cd /path/to/host_app
APP_PID=$(pgrep -f "mix phx.server" | head -1) \
  mix run --no-start ../phoenix_kit_knowledge_base/scripts/smoke_http.exs
```

It creates a scratch vault with a note, a dangling link and a trashed note,
fetches all five pages plus the not-found redirect, and fails on any 500 or
exception page. Host-specific values (repo module, session key, signing salt)
are at the top of the file.

For cross-repo work against a local PhoenixKit checkout:

```bash
export PHOENIX_KIT_PATH=../phoenix_kit
```

## License

MIT
