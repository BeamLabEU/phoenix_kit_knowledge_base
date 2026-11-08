# PR #1 — Add notes_panel: notes you can drop into any page; vault page on a phone

**Author:** alexdont (Sasha Don)
**Reviewer:** Claude (2026-11-08, merge `aa4f6b0`)
**Verdict:** Approve with fixes. The design is sound and carefully fenced:
`Places` fails closed, `within?` refuses `..`, links and suggestions resolve
only inside the panel's folder, and two people creating the same place at once
settle on one vault. Four bugs were in the places the tests did not reach: the
poll, a note that moves while open, and a title with a non-ASCII number. Two of
them crash the **host's** page, which the panel's own docs say it must never do.
One of them lets a person read and write outside their folder. All are fixed and
tested. The poll also did more work per tick than it needed to, and is now
narrower.

---

## What the PR does, checked against the code

- **`Places`** (`places.ex`). It turns a panel path into a vault, which is the
  first segment found by `path_key`, plus a folder chain. `ensure/2` asks
  `:edit`, creates the vault and chain on first write, and loses a create race
  gracefully: the unique index refuses the second insert, `settle_race/3`
  re-reads, and the loser's directory is removed only if it is empty and not
  the winner's. The `:authorize` hook fails closed on a raise, throw, exit or
  non-boolean, and it logs without its arguments. **Checked.**
- **Migration v2.** It adds `vaults.path_key` with two partial unique indexes:
  one shared vault per name, and one private vault per owner per name.
  `infer_version/2` recognises v2 by the column, and the down migration drops
  indexes before the column. `path_key` is never cast; `Vault.put_path_key/2`
  sets it and declares both constraints. **Checked.**
- **Fence.** Every panel event asks the hook again and checks `within?`.
  `Links.resolver_from/1` and `list_notes(under:)` keep `[[` suggestions, `#`
  suggestions and link existence inside the folder. `escape_like/1` is applied
  to the subtree prefix. **Checked,** with the gaps below.
- **Gettext.** The module now owns its catalogue, including Leaf's `leaf`
  domain for the panel's editor. `%Tab{gettext_backend:}` was added to core on
  2026-05-08 and is present at v2.64.0 and v2.65.0, so the 2.65.0 floor
  compiles it. `precommit` now checks the POT is current. **Checked.**
- **Vault page on a phone.** The sidebar hides behind a "Files" toggle while a
  note is open, the header buttons drop to icon-only below `sm` (each keeps
  `aria-label` and `title`), and the context panel moves under the note below
  `xl` instead of vanishing. Grid placement checked at `lg` and `xl`. **Checked**
  by reading the markup; not looked at on a device.
- **`Components.notes_panel/1`** passes `{assigns}` through to `live_component`.
  That is safe, because `live_component/1` drops `__changed__`.

## Findings

### BUG - MEDIUM — "+ Note" crashes the host page after a title like "Note ٣" — **fixed**

`numbered_title_regex/0` compiled `(\d+)` with the `u` flag. Under `u`, `\d`
matches any Unicode decimal digit, but `String.to_integer/1` accepts ASCII only.
"Note ٣" and "Note ３" are valid file names that any editor can set by renaming.
After that, every "+ Note" in the folder raised `ArgumentError` in the host
LiveView's process. It kept doing so on reconnect, because the title is still
there.

Fix: `([0-9]+)`. Test: *"a number in another script is not a number here, and
not a crash"*.

### BUG - MEDIUM — "Take theirs" follows a moved note out of the fence — **fixed**

Suppose a note open in the panel is moved elsewhere in the vault, for example
from `Clients/Acme` to `Clients/Globex` on the admin page:

1. The next keystroke fails to save with `:missing_file`, because the old path
   is gone. That raises "changed somewhere else" with **Take theirs**.
2. `reload_note` re-read the note by uuid with `Notes.get_note/2`, with no
   `within?`. That made `@note` the moved note, with its new content, at its new
   path.
3. From then on the person reads, saves, renames and trashes a note in a folder
   the panel was built to keep them out of.

The poll (`check_open_note/1`) had the same blind spot. It compared only
`content_hash`, so a move with unchanged bytes was never noticed.

Fix: both now re-read through `fenced_note/2`. A note that is no longer inside
the fence is let go of, like a deleted one ("That note was moved or deleted.").
Tests: *"a note moved out of the folder is let go of, not followed"* and *"the
poll lets go of an open note the panel's fence no longer holds"*.

### BUG - MEDIUM — vault deleted or view withdrawn under an open note crashes the host page — **fixed**

`load/1` sets `@vault` to `nil` when the vault is gone or `:view` is refused,
but it left `@note` set. `check_open_note/1` has no clause for a nil vault.
`update/2` from a host re-render does not call it at all. The next
`:leaf_changed`, which Leaf may already have debounced, passes
`save_decision/4` (note set, id matches) and reaches `save/3`. That calls
`Notes.update_content(nil, …)`, a function that only matches `%Vault{}`, so the
result is a `FunctionClauseError` in the host's process.

This one is established by reading the code. The new test's first assertion,
that the note closes, failed before the test reached the keystroke.

Fix: `release_note_without_vault/1` in `load/1` closes the note whenever the
vault is dropped, on every path that reloads. Test: *"the vault deleted under
an open note closes the note, not the page"*.

### BUG - LOW — a rename elsewhere raises a false conflict — **fixed**

A note renamed or moved inside the fence by someone else keeps its bytes, so
the poll did nothing. `save/3` writes against `@note.relative_path`, so the next
keystroke failed with `:missing_file` and showed "changed somewhere else" for a
change that did not touch the text. This is the panel's version of the
`refresh_open_note/1` rule in AGENTS.md.

Fix: when the poll finds the same `content_hash`, it takes the fresh row
silently. The buffer is unaffected, and saves go to the new path. Test: *"a
note renamed elsewhere stays open and saves under its new name"*.

### IMPROVEMENT - MEDIUM — what the poll did every 5 s, per open panel — **fixed**

- `assign_admin_href/1` ran `Scope.for_user/1`, which reads role records and
  permissions, plus `Vaults.role_for/2`, all to decide one link. It now runs
  once per vault (`admin_href_for`). A link that outlives a withdrawn role is
  harmless, because the admin page asks again.
- The listing loaded **every note in the folder with its body**. It now uses
  `list_notes(…, content: false)`. The numbering scan does the same.
- The listing loaded **every folder in the vault** and filtered one level in
  Elixir. For one `CRM` vault with a folder per client, that is the whole
  client list per tick. It now uses `list_folders(vault, parent: folder)`, with
  the filter done in SQL and LIKE wildcards escaped.
- `fenced_notes/1` runs for every `[[`/`#` popup and every link check the
  editor makes, and it loaded the bodies of the **whole fenced subtree**, which
  is the whole vault for a one-segment path. It now uses `content: false`. The
  bodies were never read there.

The two new `Notes` options are additive; existing callers are unchanged. Tests
are in `test/integration/notes_listing_test.exs`, including a folder named
`50%_off` that must not match `50ab off`.

### IMPROVEMENT - LOW — the editor's messages skipped the per-event access check — **fixed**

The module doc says every event checks access again, but `update(%{leaf: …})`
did not. A `:leaf_link_clicked` that arrived after the hook started refusing
`:view` still opened the linked note, and suggestions and link checks still
answered. All Leaf messages now go through `:view` first. `:leaf_changed` still
asks `:edit` as well. Test: *"losing view access stops the editor's messages
opening anything"*.

### NOTE — the panel is read-only in every host today — **not fixable here**

Editing needs Leaf 0.11 (`notify`). Every published core caps Leaf below that:
3.4.0 declares `~> 0.10.0`. So the lock resolves Leaf 0.10.1, and
`leaf_notify?/0` correctly turns the editor off. Core `main` already admits
0.11 (`8d0ee6328`), but that is unreleased. The README now says core is the
limit, not only Leaf. The degradation is clean and covered by a test.

### NITPICK — `Places.ensure/2` rebuilds the folder chain on every write — not fixed

Every "+ Note" and "+ Folder" runs `Notes.create_folder/3` for the panel's own
chain. That means `mkdir_p`, an index upsert per segment, and an
`Events.vault_changed/2` broadcast, so every admin page open on that vault
reloads its workspace. It is idempotent and cheap at panel scale. Checking
`locate` plus folder existence first would save the broadcast; left as is.

### NITPICK — shared places are open to any signed-in user unless a hook is set — not changed

This is by design and documented ("as with boards"). It is worth one line in a
host's checklist, because the default answer to "who can read the CRM notes" is
"anyone who can log in".

## Fixed in passing (not from this PR)

`mix precommit` was red on three dialyzer `pattern_match_cov` warnings, all at
the merge (`aa4f6b0`, against core 3.0.0), in files and specs this PR did not
touch.

- `index_live.ex:65`, `other ->` after `Vaults.create/3`. The clause is **not**
  dead. `create/3` returns `{:error, posix}` when `Storage.ensure_vault/1`
  refuses, but its `@spec` listed only the changeset and `:unauthorized` errors,
  and dialyzer trusted the spec. The spec is corrected and the clause stays;
  deleting it, as the warning suggests, would turn a disk error into a crash.
- `storage.ex` `move_folder/3` and `move_note/3`: there the trailing
  `error -> error` really was dead, since every non-match is `true` or
  `{:error, _}`. Each `else` now uses `{:error, _} = error -> error`.

The gettext `#:` references were re-extracted and merged after the line
shifts. Only references changed; no msgid or msgstr did.

## Gate

| Layer | Command | Result |
|---|---|---|
| Static | `mix precommit` (compile `--warnings-as-errors`, `gettext.extract --check-up-to-date`, `deps.unlock --check-unused`, `hex.audit`, format, credo `--strict`, dialyzer) | green, dialyzer 0 errors |
| Unit + integration | `mix test` against Postgres (`phoenix_kit_knowledge_base_test` on `postgres-test`) | 270 tests, 0 failures, none excluded |
| Live DB / HTTP | `scripts/verify_*.exs`, `scripts/smoke_http.exs` | **not run**: they need the host app at `/www/app`, which is not in this environment |

Not verifiable from here, as AGENTS.md says: the editor's client-side
behaviour, and the phone layout on a real screen.
