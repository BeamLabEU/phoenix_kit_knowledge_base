# Knowledge base: goals and founding decisions

*Written at the end of day one, recording the brief and the decisions as they
were actually taken — not reconstructed intentions.*

## The brief

Build a PhoenixKit module that is "similar to Obsidian": markdown notes, linked
together, organised into **multiple vaults** so different projects stay separate.
Vaults come in two kinds — **system** (organisation-wide) and **user's own**.
Use the markdown editor PhoenixKit already ships rather than inventing one.

## Goal

Obsidian's working model, inside a Phoenix admin: write markdown, link notes with
`[[wiki-links]]`, see what links back, and have the vault tell you what you have
referred to but not yet written.

Two things follow from "similar to Obsidian" that shaped everything else:

1. **Notes are files.** Not rows that happen to contain markdown. If `rg`, `git`,
   `vim` and the Obsidian client cannot work on the vault directly, it is not
   really Obsidian-like — it is a wiki with familiar syntax.
2. **The markdown is the truth.** Front matter, tags and the link graph are all
   *derived* from what the author wrote. Nothing the database knows should be
   unrecoverable by re-reading the text.

## Non-goals for v1

Named explicitly so they are choices rather than omissions:

- Attachments and uploads
- Obsidian vault import/export as an archive
- Graph view
- Note revision history *inside the app* (the vault is a directory — `git init`)
- Collaborative editing of the same note by two people at once
- A filesystem watcher

## Decisions

Taken in three rounds of questions. Recorded with the reasoning, because the
reasoning is the part that dates.

### Round 1 — shape

| Question | Decision |
|---|---|
| Access model | **Per-vault membership** (`owner` / `editor` / `viewer`) across both vault kinds, so a personal vault can be shared with three colleagues without becoming org-wide |
| Organisation | **Folder tree + tags**, as Obsidian has both |
| Link features | `[[wiki-links]]` with autocomplete, **backlinks panel**, **unresolved links**. Graph view excluded — impressive, but a JS rendering job that teaches you nothing about the data |
| Where it lives | **Admin area only** |

### Round 2 — mechanics

| Question | Decision |
|---|---|
| Search | **Postgres full-text** — generated `tsvector`, GIN index, title weighted above body |
| Editor | "How Obsidian does it" — one surface that is already rendered |
| Attachments | **None in v1** |
| Import/export | **None in v1** |

### Round 3 — storage (the one that was nearly missed)

The first two rounds never asked *where notes live*. That gap was caught by the
user, not by me, and it was the most consequential question of the day:

> obsidian stores them as md files in the filesystem and this allows to use all
> sorts of cli tools

| Question | Decision |
|---|---|
| Storage | **Filesystem is canonical, Postgres is an index of it** |
| Freshness | **No watcher.** Web edits index themselves; anything else is picked up by an explicit **Rescan** (button, or a Mix task for cron) |
| Root | `priv/knowledge_base` in the host app, pinned in config rather than resolved from cwd |
| Layout | `system/<vault-slug>/` and `users/<email-slug>/<vault-slug>/` |

Three consequences were accepted knowingly:

- **Titles cannot be unique.** The filesystem allows `research/Ideas.md` and
  `archive/Ideas.md`, so the index must describe that rather than reject it.
  Bare `[[Ideas]]` resolves same-folder first, then shortest path;
  `[[research/Ideas]]` disambiguates.
- **Private vaults are only private in the app.** Membership is enforced by the
  application; anyone with shell access reads every file. Inherent to storing
  notes as files.
- **The web UI can clobber an external edit.** Handled by hashing the file
  before every write and refusing when it moved — detect, never merge silently.

### Later the same day — editing

The editor decision was made twice, because the first one was wrong. I wired
core's `MarkdownEditor` (a plain textarea) and reported that PhoenixKit had no
live preview. The user meant **Leaf** — Alex's editor, which has an
Obsidian-style hybrid live-preview mode *and* inline-suggestion triggers.

Switched to Leaf in hybrid mode. That deleted a hand-rolled server-side `[[`
autocomplete and replaced it with a real caret-anchored popup. Reading view was
then removed entirely, on the same principle: Obsidian has no view/edit split,
so neither should this.

## Direction

Google-Docs-style multi-user editing is the destination, approached in steps.
The blocker is not the CRDT layer — `y_ex` is a mature Yjs port for the BEAM —
but Leaf needing a document model. See
[the Leaf spec](2026-08-25-leaf-collaboration-spec.md).

Storage for that is settled: the CRDT lives in Postgres while a note is open and
is flushed to the file on a timer. **Files are deliberately not real-time.**
