# Module audit — 2026-11-08

A full pass over the module after the notes-panel PR landed: every file in
`lib/`, the catalogues, the tests and the docs, checked against core 3.4.0
(what the lock resolves), Leaf 0.10.1, and the sibling modules' conventions
(`phoenix_kit_hello_world`, `phoenix_kit_inbox`, `phoenix_kit_crm`,
`phoenix_kit_projects`). Working tree was clean on `main` at `6fb513d`.

Two side reviews ran in parallel and fed this one: a core-components
conformance sweep of the four UI files, and a quality read of the ru/et
catalogues.

## Overall

The invariants still hold in the code: files first, index from what landed,
no DDL outside `phoenix_kit_kb_*`. Access checks are per event and re-resolved
from the scope. The security-critical path code (`safe_relative/1` +
`resolve/2`, symlink skipping, atomic writes, trash containment) is sound.

What was not sound was the **edges of the data**: lengths and bytes the schema
could not hold, which turned into raised exceptions — in a save, and then in
every rescan after it. And one real data-loss path in the vault page's
peer-change handling. And the admin UI was untranslated, and drew its own
header under core's.

## Bugs fixed

### HIGH — one long path or long `[[link]]` crashed saves and every rescan

V1 created paths, link targets, `title_key` and `vaults.directory` as
`varchar(255)`, while the changesets allowed 1,000. Confirmed against
Postgres before fixing:

- a note body containing a 300-character `[[…]]` → `Postgrex.Error 22001` from
  `Links.reindex_note/2`, after the file was already written; the page crashed;
- a 300-character `#tag` → the same, from the note insert;
- a note nested deeper than 255 characters of path → `Rescan.run/1` raised.

Because a rescan has no per-file guard, the file left behind made **every**
later rescan of that vault raise, from the button and from the mix task, until
someone found the file by hand.

Fix: migration **V3** retypes those seven columns to `text` (binary-coercible,
no rewrite; `title` stays 255 — one filename — and cannot be retyped anyway, the
generated `search_vector` reads it). `relative_path` is now capped in bytes
(2,000, under the ~2.7 KB B-tree entry limit), and `Markdown` no longer treats
a `[[…]]` past 1,000 bytes as a link or a `#…` past 255 characters as a tag —
both would otherwise reach an index entry limit instead. `infer_version/2`
recognises V3 by `note_links.target_key` being `text`.

### HIGH — a NUL byte or a non-UTF-8 file crashed saves and every rescan

Postgres refuses both in `text`, by raising (`22021`). A Latin-1 export or a
binary renamed `.md` raised `ArgumentError` earlier still, in the tag regexes.
Same consequence as above: a permanent rescan crash.

Fix: `Storage.text?/1`; `Note.changeset/2` adds a `:content` error (and skips
deriving front matter and tags from unreadable bytes); `Notes.create_note/3`
and `update_content/4` refuse `{:error, :not_text}` **before** writing, so the
file is never left ahead of its row. `Rescan` now guards every file — an
exception is one entry in `report.errors`, not the end of the scan.

### HIGH — "Someone else just saved" disarmed the stale-write guard (data loss)

`VaultLive.apply_remote_note_change/1` replaced `@note` with the peer's fresh
row. `@note.content_hash` is what the stale guard compares the file against, so
the next keystroke found the file "current" and **overwrote the peer's save** —
exactly what the banner and the README promise cannot happen. (The notes panel
does this right; only the vault page was wrong.)

Fix: raise `remote_change` and leave `@note` alone; the next save is refused as
`:stale` and the conflict banner offers the choice. Test: *"raises the banner
and keeps the guard"* — fails on the old code, passes on the new.

### MEDIUM — a rename or folder move by someone else raised a false conflict

The PR #1 review fixed this for the panel; the vault page had the same hole. A
rename keeps the bytes, so `:kb_note_saved` arrived with the same hash and was
dropped; a folder move or a rescan's rename detection only sends
`:kb_vault_changed`, which did nothing to the open note. `@note.relative_path`
then named a file that no longer existed, and the next keystroke failed with
`:missing_file`.

Fix: `follow_open_note/1` takes the fresh row on both messages — only while its
hash is still the buffer's. Tests for both.

### MEDIUM — a YAML property holding a list of maps crashed the note page

`format_property/1` did `to_string/1` on list elements; `authors: [{name: …}]`
raised `Protocol.UndefinedError` on every render of that note. Now total and
recursive.

### MEDIUM — the rescan logged the whole note

`add_error/3` logged `inspect(reason)`, and the reason for a refused file is a
changeset carrying its entire content: a private note (or a multi-MB file) in
the log. Same in two other log lines. `Errors.for_log/1` reduces a changeset to
its messages; every log site uses it.

### LOW — fixed

- **Duplicate backlinks.** A note linking `[[Ideas]]` and `[[research/Ideas]]`
  is two link rows; `Links.backlinks/1` listed the source twice.
- **`File.rm_rf/1`'s three-tuple** (`{:error, reason, path}`) leaked out of
  `Storage.delete_folder/2`, `purge/2` and `empty_trash/1`, past specs that
  promise `{:error, reason}`. Normalised once.
- **`move_note` took any path from the client.** `Storage.move_note/3` creates
  the target directory, so a hand-sent event made folders named however the
  sender liked, past `validate_filename/1`. Only an indexed folder is a
  destination now.
- **An unresolved `[[research/Ideas]]` could not be created** — the create page
  refused the `/`. A path-qualified title now creates the note in that folder,
  every segment validated.
- **Raw terms shown to users.** The panel's fallback showed `"That did not work
  (:target_exists)."`; the vault page's `"Could not save: …inspect…"`. Both now
  go through `Errors.message/1`, which logs an unknown reason and shows a
  sentence.
- **Rescan button shown to viewers**, then refused with a flash. Hidden.

## Conformance with core

- **Header trail.** The three admin pages drew their own `<h1>` under core's
  admin bar, and MembersLive's title carried a trail (`"Research · Members"`).
  Now `page_section` / `page_crumbs` / `page_title` per core's
  `2026-09-25-admin-header-trail.md`, and each page's actions are a
  `page_toolbar` (`header_toolbar/1`). Core applies the admin layout to
  external module views (`maybe_apply_plugin_layout/2`); `phoenix_kit_projects`
  uses `page_toolbar` the same way.
- **Components.** `<.input>`, `<.select>`, `<.search_toolbar>`,
  `<.form_section>`, `<.form_actions>` (adds `phx-disable-with`) and
  `<.empty_state>` replace the hand-rolled equivalents. The daisyUI 4 leftovers
  (`input-bordered`, `select-bordered`) went with them.
- **Accessibility.** Every control now has a label or `aria-label`; toggles
  carry `aria-pressed`; alerts carry `role="alert"`/`"status"`.
- **Dates.** The panel's hand-built month names → core's `Date.short/1`; trash
  dates → `format_datetime_with_user_format/1` (site format and zone).
- **`Folder`'s virtual `:color`** is gone: core reads it with `Map.get/2` since
  2.13.14, and the floor is 2.65.0.
- **No DB in `mount/3`.** IndexLive and MembersLive queried there (twice per
  page); they load in `handle_params/3` now.

## Translations

The admin pages had **no gettext calls at all** — ~2,700 lines of UI in English
only, while the panel shipped ru/et. All three pages, every flash, error,
confirm and tooltip, the rescan summary and its error reasons, role names, and
`permission_metadata/0` (with `gettext_backend:`, inbox's pattern, so core's
roles screens show it translated) are now in the module's catalogue, with ru
and et. 183 new messages. The vault page's Leaf editor is given the module's
backend too; it got English before. The suggestion headings are translated in
one place (`VaultLive.suggestion_configs/0`) instead of the panel matching the
English labels.

Wording fixes from the catalogue review: the visibility switch (ru
"Общие / Только мои", et "Ühised / Ainult minu" — they answer "whose notes"),
ru gender on the trash message, Estonian closing quotes („…“), a few Leaf
strings (et "Reasisene kood", "Muud lisamised", "Päiserida sisse/välja"; ru/et
"Clean up" as a heading), and one word for URL in each language. The
sub-permission label now reads "Manage organisation vaults", matching the UI.

Still English, and not fixable here: the module name on core's Modules page
(core translates it only from its own catalogue), and the custom validation
messages in this module's changesets.

## Docs corrected

- README / moduledoc / mix task: a terminal `mix …rescan` does **not** reach
  open browsers — it is its own OS process with no PubSub (it only logged a
  broadcast warning; `Events` now skips quietly when no PubSub runs). Said so,
  with the `rpc` alternative.
- README: "tests are database-free by design" and "`mix test` has no endpoint"
  were no longer true; "Folder rename in the UI" was listed as missing but is
  there; Leaf's image button no longer exists (0.10 draws it only when the host
  lists it in `toolbar`). New Translations section.
- `Storage` claimed `resolve/2` catches "a base that itself contains symlinks";
  `Path.expand/1` is lexical. Reworded.
- `Collab` / `Events` / `Collab.Store` described Leaf 0.6 as current.
- AGENTS.md: new Postgres section, the header-trail and gettext-backend
  gotchas, the remote-change rule, the test router.

## Tests

270 → **302**, 0 failures (223 unit, 79 integration against Postgres). New:

- `integration/indexing_limits_test.exs` — every crash above, plus "one bad
  file is one error" and "an indexed note edited into binary keeps its row".
- `integration/vault_live_test.exs` — **the admin pages mounted for the first
  time**, through `test/support/router.ex` (scope assigned the way core's hook
  does). Renders with a folder and a note, in Russian, the toolbar as a
  component, and the peer-change, move and create fixes. The two peer-change
  tests were run against the old code and fail there.
- `errors_test.exs`, plus unit cases in `storage_test.exs` / `markdown_test.exs`.
- `integration/migrations_test.exs` (was `_v2_`) — V3 shape and inference.

## Gate

| Layer | Command | Result |
|---|---|---|
| Static | `mix precommit` (compile `--warnings-as-errors`, `gettext.extract --check-up-to-date`, `deps.unlock --check-unused`, `hex.audit`, format, credo `--strict`, dialyzer) | green; dialyzer 0 |
| Unit + integration | `mix test` against `postgres-test` | 302 tests, 0 failures |
| Live DB / HTTP | `scripts/verify_*.exs`, `scripts/smoke_http.exs` | **not run** — need the host at `/www/app`, absent here |

**Run `smoke_http.exs` against the host before release.** The test router does
not apply core's admin chrome, so the one thing nothing here has rendered is
the header toolbar *inside* the admin bar (Members, Trash, Rescan, New note now
live there). Its "trash receives" check (`data-drop-trash`) covers it.

## Open items

Carried over, unchanged — each a decision rather than a bug:

- Rescan runs in the LiveView process; a large vault freezes that tab.
- No file-size cap on indexing (`stat_note/2` reads whole files).
- `root` defaults to a cwd-relative `priv/knowledge_base` — wrong for a release.
- Folder restore is per-note; empty directories are not restored.
- Global slug uniqueness across everyone's personal vaults.
- `search_vector` includes front matter.
- The `vault_members.user_uuid` FK question (AGENTS.md).
- Collab is groundwork; when wired, pass `idle_after:` and handle
  `{:leaf_conflict, _}`.

Closed: the "dead image/video toolbar buttons" item — Leaf 0.10 does not draw
them unless the host lists them in `toolbar`, and this module lists none.

New, not fixed:

- **Create is check-then-write.** `Notes.create_note/3` asks
  `note_exists?/2`, then renames a temp file into place, which clobbers. Two
  people creating the same title in the same instant: the second overwrites the
  first, and both end up on one row. Rare (the panel's "Note N" retries on
  `:already_exists`, but only when the check catches it). A no-clobber create
  (`File.ln/2` the temp file into place, which fails on an existing name, then
  remove the temp) would close it; `move_note/3` has the same shape.
- Windows reserved names are checked on the whole title (`CON`), not on the
  stem before the first dot (`CON.backup`), which Windows also refuses.
- The move target is still a flat `<select>`; core's guide prefers its
  `TreePicker`. Drag-and-drop covers the common case.
- Empty trash / delete permanently use `data-confirm`; core's
  `<.confirm_modal danger>` would suit the irreversible two.
- `Migrations` escapes the prefix with `\'` (the ecosystem's shared snippet);
  standard SQL is `''`. Only matters for a prefix containing a quote.
