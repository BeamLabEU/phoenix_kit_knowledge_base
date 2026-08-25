# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Trash.** Deleted notes and folders move to `.trash/` inside the vault
  instead of being unlinked, under a per-deletion directory that preserves the
  original path — so restore is a move, and deleting the same path twice keeps
  both copies. Trash panel with restore, permanent delete and empty.
- **Leaf collaboration spec** (`docs/leaf-collaboration-spec.md`) — what Leaf
  needs for CRDT multi-user editing, staged, with the Hex ecosystem survey
  (`y_ex`, `prosemirror_ex`, the `y-phoenix-channel` demo) and the settled
  storage model: the CRDT lives in Postgres while a note is open and is flushed
  to disk on a timer.
- **Live sync across browsers and devices.** Each vault page subscribes to a
  PubSub topic; note saves, deletions, folder changes and rescans propagate to
  every open session. A note open in reading view is replaced immediately; one
  being edited raises a banner instead, so unsaved keystrokes are never
  discarded on your behalf. Rescans emit a single message rather than one per
  file, so `mix phoenix_kit_knowledge_base.rescan` in a terminal refreshes open
  browsers without flooding them.

### Changed

- **Reading view removed.** There is one surface — the editor — as in Obsidian.
- **File names are validated, not repaired.** An invalid title is refused with
  the reason instead of having its characters silently stripped, which used to
  file `Ideas: Part 2` as `Ideas Part 2`. Adds Obsidian's link-breaking
  characters (`[ ] # ^`) and Windows device names to the refused set.

### Fixed

- **Every vault page crashed with `BadBooleanError`.** The trash panel added
  `@search_results and not @trash_open` to a section guard; `@search_results` is
  `nil` when no search is running, and `nil and …` raises even though
  `:if={@search_results}` alone is fine. Added `scripts/smoke_http.exs`, which
  renders every page as a logged-in user, because neither the database-free test
  suite nor an unauthenticated request executes a template.
- **Two deletions in the same second lost the first recoverable copy** — trash
  directories are now unique per deletion, not per second.
- **Autosave could silently overwrite a colleague's edit.** Once a conflict was
  flagged, every subsequent autosave passed `force:` — so continuing to type was
  enough to overwrite the other version without ever choosing to. Overwriting is
  now reachable only through an explicit button.

- **Switching notes showed the previous note's text.** Leaf's editing surfaces
  are `phx-update="ignore"`, so LiveView never patches them after mount; with a
  constant component id, patching between notes reused the same hook and every
  note rendered whatever was loaded first. The editor id is now keyed to the
  note, so LiveView mounts a fresh component per note.
- **A late edit could be written into the wrong note.** Leaf debounces, so a
  `:leaf_changed` for the note you just left could arrive after switching and be
  saved into the note now open. Payloads are now matched against the current
  editor id and dropped when stale.

## [0.1.0] - 2026-08-25

First release. Notes are markdown files on disk; Postgres indexes them.

### Added

- **Filesystem storage.** A vault is a directory, a folder is a directory, a note
  is a `<Title>.md` file — so `rg`, `git`, `vim` and Obsidian work on the tree
  directly. Layout: `system/<slug>/` and `users/<email-slug>/<slug>/` under a
  configured root.
- **Rescan** — reconciles the index with the disk, via a button or
  `mix phoenix_kit_knowledge_base.rescan`. Compares `(mtime, size)` before
  hashing, and detects renames by content hash so an external `mv` preserves a
  note's uuid, permalink and backlinks.
- **Stale-write guard** — the web UI refuses to overwrite a file that changed
  underneath it, offering reload or deliberate overwrite.
- **Path safety** — two independent containment checks, symlinks inside a vault
  skipped rather than followed, sanitised filenames, atomic writes.
- **Ambiguity-tolerant link resolution** — titles are not unique on a
  filesystem, so `[[Ideas]]` resolves same-folder first, then shortest path, then
  alphabetically, with `[[folder/Ideas]]` for explicit disambiguation.
- **Vaults** — system (organisation-wide) and personal, sharing one
  `owner`/`editor`/`viewer` membership model. `knowledge_base.manage_system_vaults`
  confers ownership of every system vault, and deliberately grants nothing on
  other people's personal vaults.
- **Notes** in a nested folder tree, with YAML front matter and tags — both
  derived from the markdown on every save, never edited separately.
- **`[[Wiki-links]]`** with aliases and heading anchors, resolved case- and
  whitespace-insensitively within a vault.
- **Backlinks panel** and a per-vault **unresolved links** list, ordered by how
  many notes are asking for each missing title. Creating a note retroactively
  resolves every link already pointing at it; deleting one turns links back into
  unresolved rather than dropping the mentions.
- **`[[` autocomplete** driven entirely server-side, plus a caret-aware
  "Link to note" picker for mid-paragraph inserts.
- **Full-text search** over a generated `tsvector` column with a GIN index,
  title-weighted, parsed with `websearch_to_tsquery`.
- **Read / edit toggle** using core's `MarkdownEditor` and MDEx rendering, with
  autosave that rebuilds the link index in the same transaction.
- Versioned migration coordinator for the five `phoenix_kit_kb_*` tables,
  prefix-aware and stamped via `COMMENT ON TABLE`.
- 126 database-free tests covering markdown parsing, path containment and
  filename sanitisation, link-resolution tie-breaking, changeset invariants,
  behaviour compliance, route ordering and migration version bookkeeping.

[0.1.0]: https://github.com/BeamLabEU/phoenix_kit_knowledge_base/releases/tag/v0.1.0
