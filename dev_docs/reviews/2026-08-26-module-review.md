# Module review — 2026-08-26

End of day one, looking at the module as a whole rather than a diff. Working
tree was clean on `main`. The question was: what did we build, and what is
worth fixing or deciding next.

## Overall

This is a strong day-one module. The three invariants — files are the source of
truth, the markdown is the derivation source, this module never touches core —
are actually held in the code, not just in `AGENTS.md`. Path safety is
double-checked, the stale-write guard is real, rename-by-hash on rescan is the
right call, and the Leaf bugs already paid for (`editor_id`, `save_decision`, no
`force:` on autosave) are the ones that usually ship.

The set I would not change:

- Files as source of truth, Postgres as a disposable index
- No transactions around disk-then-index
- Refuse names rather than sanitise them
- Unresolved links as rows
- Membership enforced in the app, with the filesystem caveat stated plainly
- No JavaScript bundle of this module's own
- Trash as `.trash/<stamp>/original/path`
- One LiveView for the workspace so the sidebar does not remount

That set is coherent. What follows is the stuff I would fix or decide next, not
a rewrite.

## Bugs worth fixing this week

### 1. "Reload" does not reload the editor

Leaf's editing surfaces are `phx-update="ignore"`. `AGENTS.md` already says
replacing content needs `send_update(Leaf, action: :set_content, …)`.
`reload_open_note/1` only assigns `@content`:

```elixir
defp reload_open_note(socket) do
  case Notes.get_note(socket.assigns.vault.uuid, socket.assigns.note.uuid) do
    nil -> ...
    note -> open_note(socket, note)
  end
end
```

That is the **Discard mine, reload** button, rescan-while-open, and any later
`open_note` of the same note. Server assigns update; the buffer on screen does
not. Same class of bug as the constant editor id, just on the same note.

Leaf's default `update/2` assigns `content` and uses `assign_new` for the
rendered HTML. It does not push a `set_content` command unless the host asks.
The fix is:

```elixir
send_update(Leaf, id: editor_id(note), action: :set_content, content: note.content || "")
```

`mix test` cannot catch this. Click **Discard mine, reload** in two browsers
before calling it done.

### 2. `[[` autocomplete dies on spaces and slashes

`@suggestion_configs` does not set `:token`. Leaf's default is
`~r/[\p{L}\p{N}_-]/u`, so the popup closes on space and `/`.

Titles like `Attention Is All You Need` and path-qualified `research/Ideas`
will not complete. Nested tags (`#project/alpha`) have the same problem on `#`.

For notes, something like "anything except `]` and newline"; for tags, include
`/`. Pin the configs in a test so a default Leaf token cannot regress.

### 3. Viewers can rename a note

`create_note`, `delete_note`, `move_note`, folders, and trash all go through
`require_write/1`. `rename_note` does not. The title input is
`readonly={not @can_write}`, but a crafted `phx-blur` is enough.

`rescan` is also ungated. A viewer can sit on the Rescan button and block the
LiveView for the length of a vault walk. That should be `:write` or `:manage`.

`MembersLive` checks `:manage` on mount only. `IndexLive.delete_vault`
re-resolves the role on the event; membership add/update/remove should too.

### 4. Incremental link resolution does not re-tie-break

`Links.resolve_for_note/1` only fills `target_note_uuid IS NULL`.
Already-resolved links stay pointed at whoever got there first.

Sequence:

1. `archive/A.md` contains `[[Ideas]]` → unresolved
2. Create `research/Ideas.md` → that link now points at research
3. Create `archive/Ideas.md` → same-folder should win; the row is already
   resolved, so it does not move until a full rescan

That contradicts the resolution rules documented in the README and
`Links`. Cheapest fix: after create/rename/move, rebuild the vault's links the
same way rescan does (`Links.reindex_vault/1`). A note has a handful of links;
a vault-sized rebuild is the version that is actually right, and the rescan
comment already says that.

### 5. Vault directory is created after the row

The comment in `insert_vault/3` says directory first, row second. The `with` is
insert then `Storage.ensure_vault/1`. If mkdir fails you have a vault row
pointing at nothing. Swap the order to match the comment: an empty directory
with no row is inert; a row with no directory fails on the first read.

### 6. Copy that contradicts the model

- New-note pane: *"Titles are unique within a vault — that is what makes
  `[[links]]` unambiguous."* They are not; that is a founding decision.
- Folder delete confirm: *"from disk… cannot be undone."* It goes to `.trash/`.
- Note delete flash: *"deleted from disk."* Same.

The README is honest about trash and non-unique titles. The UI is not.

## Design nits for next week

**`VaultLive` is 1,543 lines.** `web/components/` is empty. Sidebar, note pane,
and context panel are already function components in the same file — they can
move. The LiveView should be events and loading.

**Rescan runs in the LiveView process.** A large vault will freeze that browser
tab. `Task.async` plus `handle_info`, or Oban, with the existing one-shot
`:rescan` PubSub event at the end.

**Global slug uniqueness.** The URL is `/admin/knowledge-base/:vault`, so two
people cannot both have a personal vault `research` without a suffix. Fine if
flat URLs are the point; if personal vaults should feel private, the URL needs
an owner segment. Worth deciding before anyone bookmarks `research-xkcd`.

**No file-size cap.** `stat_note/2` reads the whole file. One huge `.md` (or a
YAML bomb in front matter) takes down indexing. A few-MB ceiling on index and
save, with the oversize file reported in the rescan error list, is enough.

**Image button is a dead control.** `preset={:advanced}` still shows image and
video; `{:leaf_insert_request, _}` is swallowed. Deny those toolbar items, or
flash "no uploads in this version."

**Context panel is `hidden xl:block`.** Backlinks and outgoing links vanish on
anything short of a wide desktop, and those are the navigation path until Leaf
renders `[[wiki-links]]`. A collapsible strip under the editor on smaller
breakpoints would help.

**`root` default is cwd-relative `priv/knowledge_base`.** Fine in
`mix phx.server`; a release's cwd is not the project. Make a missing `:root`
loud at enable time, or resolve via `:code.priv_dir`.

**Catch-all `handle_info`.** `leaf_insert_request` is already special-cased so
an unmatched Leaf message does not kill the view. A new Leaf version will add
another. A log-and-ignore fallback is cheaper than another round of "the
editor disappeared."

**Folder restore is per-note, not per-subtree.** The README says deleting a
folder trashes the whole subtree so it can be restored intact. `list_trash/1`
walks markdown files and restore moves one file. Restoring notes one by one
recreates the folder chain via `index_folder_chain/2`, but empty directories
and the original tree-as-a-unit are not restored. Either restore the stamp
directory as a unit, or stop claiming that in the README.

**N+1 on the vault list.** `IndexLive` calls `Notes.count_notes/1` per card.
One grouped count for the visible set.

**`search_vector` is built from `content`, which includes YAML front matter.**
Searching for a property key can hit notes that never mention it in the prose.
Strip the body, or weight front matter separately, if that starts to matter.

**`reindex_vault/1` is one delete-plus-insert per note.** Fine at hundreds of
notes; the thing to change if a vault ever outgrows it, not before. Callers
would not change.

## The open FK question

`phoenix_kit_kb_vault_members.user_uuid` has a real foreign key to
`phoenix_kit_users` with `on_delete: :delete_all`. Boards and Inbox both use a
bare `:binary_id`.

I would keep the FK and close the question. Theirs is attribution; an orphaned
membership row here is a dangling permission grant. Document the deviation as a
decision rather than leaving it open. The coupling to core's users table is
real, and it is the documented public schema contract the rest of the admin
already depends on.

## Tests and verification

The 156 database-free tests are well aimed: path traversal, filename refusal,
tie-break, `save_decision`, behaviour compliance, `notes/new` before
`notes/:id`. That is the right split.

The gap is still the gap already named in the day-one progress report:
**indexing, rescan, membership, and save/conflict are only exercised by ad-hoc
scripts that are not in the repo.** The two user-facing bugs (constant editor
id, `BadBooleanError`) were in surfaces those tests cannot see.

Highest-value additions, in order:

1. A test (or a small helper) that `reload_open_note` issues `set_content` —
   even a unit assertion on an extracted function.
2. Check `:token` on the `[[` and `#` configs so a default Leaf token cannot
   regress.
3. Commit the live-DB scripts already run (or a `mix test` path against a
   throwaway Postgres) for rescan rename-detection and `resolve_for_note` vs a
   later same-folder note.
4. `scripts/smoke_http.exs` is hardcoded to `DmitriDon` and a signing salt.
   Fine as a private hammer; a config or env block at the top would make it
   copy-pasteable for the next host.

Three layers, and none of them alone is sufficient — that remains true. Nothing
here can verify the editor. Two of the day-one bugs were found by a person
using the app, and the Reload-button bug is exactly that class.

## What I would not start next

Google-Docs-style co-editing is the destination, and the Leaf spec already maps
the route. The blocker is still Leaf needing a document model, not the CRDT
layer, and nothing in this review changes that.

The next *visible* win is still Leaf Stage 0 (`[[wiki-link]]` rendering) —
`Markdown.to_html/2` is already the server half. Presence and a soft lock are
the cheap collision reducer while Stage 1 is out of reach.

Do the reload `set_content` path, the `[[`/`#` tokens, and the `rename_note`
write check first. Those three are small and user-visible.
