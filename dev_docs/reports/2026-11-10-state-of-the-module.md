# State of the module — 2026-11-10

Written for the `pezu-improvements` pull request. This report has two parts:

- **What changed since `6f97be6`**: four commits, made while building Pezu
  (pezu.app, a private repository) on top of this module.
- **Where the module stands for its first Hex release**: what is done, and
  what is still open.

Pezu is a task and life-log app. Every task in it is a markdown file in a
workspace vault, bound to its database row by a front-matter `id:`. That makes
it the first host to drive this module hard through its context API rather
than its admin pages. Each addition below is something Pezu first had to work
around in its own code; Pezu now uses the module's version instead.

## What this pull request adds

### 1. Numbered names on demand: `unique: true` (`22599a6`)

These four functions take `unique: true`:

- `create_note/4` (new arity: `create_note(vault, attrs, actor_uuid, opts)`)
- `rename_note/4`
- `move_note/4`
- `restore_note/3` (new arity)

With it, a taken name is numbered instead of refused: `Ideas`, then `Ideas 2`,
`Ideas 3`, and so on. That is Obsidian's rule, and the panel's "Note 1, Note 2"
already followed it.

- **Without the option, nothing changes.** The refusals are still
  `:already_exists` and `:target_exists`.
- **A note's own path counts as free**, so renaming `Ideas` to `Ideas` stays a
  no-op.
- **Past 100 attempts** the result is `:too_many_duplicates`, which has its own
  message in `Errors`, translated into en, et and ru.

Pezu had written this numbering three separate times, for create, restore and
move-to-project.

### 2. Rename and move in one step: `move_note/4` with `title:` (`22599a6`)

Before, moving a note into a folder where its name was taken meant a rename
followed by a move. Between the two, the note sat renamed in the old folder,
or failed there if the new name was taken in the old folder as well. Now it is
one file move, combined with `unique:` when wanted.

### 3. A trash a host can search: `list_trash/2` with `frontmatter: true` (`22599a6`)

Each trash entry can now carry its parsed front matter. A host that binds
notes by a property can find the trashed copy of "the note with `id: X`"
without reading `.trash/` itself. Before this, Pezu opened every trashed file
on each restore.

`delete_note/2` keeps its return value, so existing callers are unaffected.

### 4. Notes by front-matter property (`22599a6`)

Two additions:

- `list_notes/2` takes `property: {key, value}`, compared as text so YAML `7`
  matches `"7"`. It also takes `has_property: key | [keys]`, which uses
  `jsonb_exists_any`.
- `get_note_by_property/3` returns the first match.

Pezu had been querying `frontmatter->>'id'` in this module's tables with its
own SQL. That broke invariant 3 in spirit, even if not in the letter.

**Tests for 1–4:** `test/integration/notes_names_test.exs`, 10 tests:

- numbering on create, rename, move and restore
- a name taken only in the source folder not counting
- move with `title:`
- trash front matter
- `:property` and `:has_property`
- no reach into another vault

### 5. Search snippets: `search_with_snippets/3` (`acf3f3e`)

Each match comes back with a snippet of its body around the matched words:
`ts_headline`, with the front matter stripped first.

- **The shape is segments, not HTML:** `[{:text, _} | {:match, _}]`. The host
  renders and escapes them its own way, so nothing from a note's text reaches
  a page unescaped through this function.
- **The match markers are private-use code points** (`U+E000`/`U+E001`), which
  nobody types by accident.
- **`ts_headline` strips HTML tags** in the body and keeps their words. The
  test pins that behaviour.

`search/3` is unchanged. 2 tests.

### 6. The docs build cleanly (`d122ae9`)

The README linked to `dev_docs/…` and `AGENTS.md` with relative links. Neither
is in the Hex package (`dev_docs` is excluded on purpose), so on hexdocs those
links were dead, and `mix docs` warned 14 times. They are now absolute GitHub
URLs, which work from both places. `mix docs` is warning-free.

### 7. `notes_panel` edits on today's PhoenixKit (`bf43f9c`)

**The problem.** Without a Leaf that supports `notify` (0.11), the drop-in
panel showed notes read-only. Core 3.4.0 caps Leaf at `~> 0.10.0`, so on every
current install the widget was a viewer rather than a widget.

**The fix.** It now edits in a plain markdown textarea, through the same paths
as the Leaf editor:

- **Autosave** goes through `save/3` (debounced, 700 ms).
- **The stale-write guard** is the same, with the same **Take theirs / Keep
  mine** choice. `reload_note` only sends `:set_content` to Leaf when Leaf is
  the editor; the textarea re-renders from `@content`.
- **Access is asked again on every change.** The textarea is `readonly`
  without `:edit`, and a forged change is refused.
- **A late change is dropped:** a debounced change that names a note no
  longer open is ignored, like `save_decision/3` does for Leaf.
- **Line breaks:** CRLF from the browser is normalised to LF.

What the textarea lacks is Leaf's: the formatting toolbar, and `[[`/`#`
autocomplete. Typed links and tags still work, since they are only text. With
Leaf 0.11 the Leaf editor takes over, unchanged.

**Tests:** 3 new ones (edit and CRLF; late change and the guard; read-only and
refused), replacing the read-only test. One string was retired and one added,
in en, et and ru.

The README's "Needs Leaf 0.11" bullet now describes both editors.

## How it was verified

| Check | Result |
|---|---|
| `mix test`, unit and integration against Postgres 18 (`PGPOOL=5`) | **316 tests, 0 failures** (302 before; 14 added, net) |
| `mix precommit` (warnings as errors, gettext up to date, `deps.unlock --check-unused`, `hex.audit`, format, credo strict, dialyzer) | passes |
| `mix hex.build` | builds `phoenix_kit_knowledge_base-0.1.0` |
| `mix docs` | no warnings |
| Pezu's suite, compiled against this branch as a path dependency | 152 tests, 0 failures. Pezu's CI also checks out this branch. |

Not verified: the notes panel in a real browser (layer 4 in AGENTS.md). Its
LiveView tests drive the real component, but not a browser.

## What is still open

In order of how much it matters for a first release.

### Should be fixed before 0.1.0

1. **Rescan's quick check can miss an edit.** `Rescan` skips a file whose size
   and second-truncated mtime match the index (`rescan.ex:196`). An edit that
   keeps the size and lands in the same second as the last indexing stays
   invisible until something else touches the file. Examples are a script, a
   fast sync client, or a test. Pezu's tests ran into it.
   - Possible fixes: compare mtimes at microsecond resolution where the
     filesystem provides it, or always re-hash files modified in the last few
     seconds before the scan started.
   - Small and local, but it is a correctness bug in invariant 1.
2. **Move `[Unreleased]` to `## [0.1.0] - <date>`** in the CHANGELOG, tag
   `v0.1.0`, and check who owns the `phoenix_kit_knowledge_base` name on Hex
   before `mix hex.publish`.

### Worth doing, not blocking

3. **Search language per vault.** `'english'` is hard-wired, in both the
   generated `search_vector` and the queries. An Estonian vault gets English
   stemming, so Estonian words only match as written. Postgres has no Estonian
   dictionary, so the realistic option is `'simple'`.
   - Doing this means a column on `vaults`, a migration that regenerates the
     column, and the config passed as a literal per query. A `regconfig`
     can't be a bound parameter; see the gotcha in AGENTS.md.
4. **A file watcher** (optional, behind config). Today outside edits wait for
   an explicit rescan: Pezu rescans every 15 minutes. `file_system` and
   `inotify` would make it live. "Not in this version" in the README already
   lists it.
5. **Rich editing in the panel and the vault page needs Leaf 0.11**, which
   needs a core release that admits it (3.4.0 stops at `~> 0.10.0`). Nothing to
   change here; the floor note in AGENTS.md explains why the lock holds Leaf
   back. Once core moves, the panel switches to Leaf by itself.

### Housekeeping, for the maintainer

6. **AGENTS.md and CLAUDE.md** still describe the original host app
   ("a path dependency of `/www/app` (`DmitriDon`)", a `MIX_ENV=dev` set
   container-wide). They are not in the package, so they don't block a
   release. They are this repository's working notes, so they are left as
   they are for their author.
7. **The open question** in AGENTS.md, `vault_members.user_uuid`'s FK to core,
   is still open.
8. **"Not in this version"** in the README is unchanged: attachments, graph
   view, note history, collaborative editing and presence. Each is a clean
   addition later.

## Compatibility

- **Nothing existing changed shape.** Every addition is a new option, a new
  arity or a new function.
- **One behaviour change, in the panel only:** without Leaf 0.11 it now
  edits, where before it showed notes read-only.
- **No migration.** The module stays at its current schema version.
