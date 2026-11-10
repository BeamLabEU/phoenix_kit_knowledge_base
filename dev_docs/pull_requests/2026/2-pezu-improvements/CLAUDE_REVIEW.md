# PR #2 — Numbered names, property lookup, search snippets, and an editing notes_panel

**Author:** alexdont (Sasha Don)
**Reviewer:** Claude (2026-11-10, merge `baa495a`)
**Verdict:** Approve with fixes. Every addition is opt-in (a new option, arity or
function), there is no migration, and the panel's plain editor reuses the Leaf
path's save, stale guard and per-event access check rather than inventing its
own. Three bugs, all in the new code and all fixed and tested:

- `move_note/4` started refusing notes that it used to move.
- `search_with_snippets/3` raised for some valid `:words` values.
- Its front-matter cut missed CRLF files.

The five new tests fail against the PR as submitted and pass after the fixes.

---

## What the PR does, checked against the code

- **`unique: true`** on `create_note/4`, `rename_note/4`, `move_note/4` and
  `restore_note/3`. It tries `Ideas`, `Ideas 2`, … up to 100, then
  `:too_many_duplicates`. The note's own path counts as free, so a rename to
  the same name is still a no-op. **Checked**, with the gap below.
- **`move_note/4` `title:`** renames and moves in one `Storage.move_note`, and
  passes `existing: note` through `move_and_reindex/4`, so it doesn't leave a
  second row behind. **Checked.**
- **`list_trash/2 frontmatter: true`** reads each trashed `.md` through
  `Storage.read_note/2` (`vault_child`-contained). A trashed folder or a read
  error gives `%{}`, never an exception. **Checked.**
- **`list_notes/2` `:property` / `:has_property`, `get_note_by_property/3`.**
  `->>` text comparison and `jsonb_exists_any`, both vault-scoped. Keys and
  values are bound parameters. **Checked.**
- **`search_with_snippets/3`.** `ts_headline` with private-use start and stop
  markers, split into `{:text, _}` / `{:match, _}` segments. No HTML reaches the
  host from a note through this. **Checked**, with the two bugs below.
- **`notes_panel` plain editor.** `plain_edit` matches the open note's uuid,
  asks `Places.authorize(:edit, …)` again, normalises CRLF, and goes through the
  same `save/3`, so `:stale` / `:missing_file` raise the same conflict bar. The
  textarea id is per note, so switching notes does not reuse a buffer. `readonly`
  follows `@can_edit?`. `refresh_editor/2` only `send_update`s Leaf when Leaf is
  in use. **Checked.** The browser side is unverified, as the PR says.
- **README links made absolute** for hexdocs. They point at `BeamLabEU/…/main`,
  which matches `origin`. **Checked.**

## Findings

### BUG - MEDIUM — `move_note/4` refused notes it used to move — **fixed**

Before this PR, the target was `Path.join(folder, Path.basename(path))`, which
keeps the file's own name verbatim. The PR rebuilt it as
`build_note_path(title_from_path(path), folder)`, which runs
`validate_filename/1`. That is the *create* rule. AGENTS.md is explicit that
indexing accepts names verbatim and that the asymmetry is deliberate. So:

- `Meeting #3.md` (`#` is forbidden for creates, common in Obsidian vaults) was
  indexed fine, then refused by every `move_note/4` with
  `{:forbidden_characters, ["#"]}`. This affects plain moves, not only
  `unique: true`, so drag-and-drop in the vault tree broke for such a note.
- `Note.MD` was silently renamed to `Note.md` on move.

`restore_note/3 unique: true` had the same problem.

Fix: a name the file already has is kept verbatim (`kept_name/2`), so the only
change is the ` N` suffix and the extension keeps its case. A name a person
typed (`title:`, `rename_note/4`, `create_note/4`) is still validated
(`typed_name/2`). Both go through one `first_free/4`. Tests: the four tests
under *"a name the file already has is kept verbatim"*, including that a new
`title:` is still validated.

### BUG - MEDIUM — `search_with_snippets/3` raised for `words:` 3–5 — **fixed**

`MinWords=#{min(5, words)}` equals `MaxWords` when `words` ≤ 5, and Postgres
raises `MinWords must be less than MaxWords`. The clamp let 3 through, so the
documented range included values that crashed. Fix: `min(5, words - 1)`. Test:
*"any :words in range is a valid ts_headline"* (1, 3, 4, 5, 6, 60, 500).

### BUG - LOW — the front-matter cut missed CRLF and could eat the body — **fixed**

The SQL regex was `\A---\n.*?\n---\n`.

- **CRLF files.** A note saved from Windows, or one round-tripped through a
  textarea elsewhere, has `\r\n` line endings. For those the regex matched
  nothing, so its front matter (an `id:`, say) showed up in snippets. That is
  what the PR's own test refutes for LF.
- **Trailing blanks and end of file.** It also missed `---` followed by
  trailing spaces, and a note that is only front matter. `Markdown` accepts all
  three.
- **Why a straight port goes wrong.** Copying `Markdown`'s regex across
  (`\r?\n`) turns it greedy: a Postgres ARE takes its greediness from its
  *first* quantifier. `.*?` would then run to the last `---` rule in the note
  and cut the body with it. That was verified against Postgres.

Fix: `@frontmatter_pattern`, wrapped in `{1,1}?` to force non-greedy, passed as
a bound parameter (no `\\?` fragment escaping). It is applied only when the
note's `frontmatter` column is non-empty, so a body that opens with a `---`
rule keeps its text. Test: *"front matter goes, body rules stay"*.

### IMPROVEMENT - LOW — `property:` with a list or map value — **fixed**

`to_string/1` of a list builds a charlist string. For a map it raises
`Protocol.UndefinedError`. Neither matches what `->>` returns for a nested
value. The clause now takes scalars only, so a list or map fails at the guard
instead of silently matching nothing.

### NITPICK — numbering a name that already ends in a number — not changed

`unique: true` on `Ideas 2` gives `Ideas 2 2`, not `Ideas 3`. Obsidian does the
same for a typed name, and parsing the number back out is how PR #1's "Note ٣"
crash happened. Left alone.

### NITPICK — `unique: true` is check-then-write — not changed

Two concurrent `unique: true` creates of one title can both see `Ideas 2` as
free. This is the same race the plain `create_note/3` already has
(`note_exists?` then `write_note`). Closing it needs an exclusive create in
`Storage.write_note/3`. That belongs in its own change, not in a review.

### NOTE — the plain editor and a focused textarea

LiveView does not overwrite a focused input's value. So a remote change only
reaches the textarea once it loses focus, which "Take theirs" causes, since it
is a button click. That is the intended behaviour, but nothing here can assert
it (AGENTS.md: the editor is verified by a person).

## Gate

- `mix precommit`: compile with warnings as errors, gettext up to date,
  `deps.unlock --check-unused`, `hex.audit`, credo strict (no issues), dialyzer
  (0 errors).
- `mix test` against Postgres: 322 tests, 0 failures (PR: 316). An unused
  variable warning in the PR's panel test is fixed too.
- Not run: `scripts/smoke_http.exs` and the live-DB scripts against `/www/app`.
  The fixes are in `Notes` only and are covered by the integration tests.
