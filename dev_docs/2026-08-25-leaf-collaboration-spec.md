# What Leaf needs for multi-user editing

> **Superseded, 2026-08-28.** Leaf 0.6.0 shipped live editing. It went a
> different way than this document proposes — operational rebasing rather than
> a CRDT, so no `y_ex` — but the storage model here is what it built: a room
> holds the document while people are editing, the file is a lagging export,
> and flushing is on a pause-and-interval timer. See
> [2026-08-28-leaf-0.6-findings.md](2026-08-28-leaf-0.6-findings.md).

Notes for Alex, from building `phoenix_kit_knowledge_base` on Leaf 0.5.1.

The goal is Google-Docs-style editing: two people in the same note, both typing,
both seeing each other's characters appear, nothing lost.

**The headline, which changed after surveying Hex: the CRDT side is close to
solved, and almost all the remaining difficulty is in Leaf.** Everything
downstream of a document model is assembly with existing libraries.

## Where things stand

Leaf today is excellent at what it does and structurally cannot do this yet.
Three facts, all verified against 0.5.1:

| Fact | Consequence |
|---|---|
| The edit surface is a raw `contenteditable` div (plus textareas for markdown/HTML). There is no document model. | No stable positions. "Character 400" means nothing once somebody else inserts at character 12. |
| The wire contract is snapshot-only: `content_changed` sends the whole `markdown` + `html` after a debounce. There are no operation-shaped events. | Two concurrent snapshots cannot be merged. You cannot recover *what changed* from a before and an after — insert, delete and rewrite are indistinguishable. |
| `set_content` does `this._visualEl.innerHTML = html` wholesale, then re-baselines. | Applying a remote change while someone types destroys their caret and selection. |

The underlying issue is which way the truth flows. In Leaf the DOM is
authoritative and markdown is derived from it. Collaborative editing needs the
inverse: a shared document is authoritative and the editor renders it.

## What the ecosystem already provides

Surveyed on Hex, August 2026:

| Package | Version | Downloads | What it gives us |
|---|---|---|---|
| [`y_ex`](https://hex.pm/packages/y_ex) | 0.10.5 (Apr 2026) | 139k | **Yjs on the BEAM**, wrapping the `y-crdt` Rust core. Near-full parity with yjs 13.6: YText with formatting deltas and embeds, YMap, YArray, subdocuments, snapshots, sticky indexes, undo manager, document observers, transaction origins, **and Awareness**. |
| [`prosemirror_ex`](https://hex.pm/packages/prosemirror_ex) | 0.3.0 (Jul 2026) | 6.2k | Elixir port of `prosemirror-model` + `prosemirror-transform`, wire-compatible — server-side document manipulation if we ever want it |
| [`delta_crdt`](https://hex.pm/packages/delta_crdt) | — | 2.4M | δ-CRDTs for distributed *state* (what Horde uses). Different problem; useful later for cluster-wide session ownership, not for text. |

`y_ex` is by [satoren](https://github.com/satoren/y_ex), who works in the Yjs
ecosystem proper — this is not a weekend port.

**The decisive find**:
[`y-phoenix-channel`](https://github.com/satoren/y-phoenix-channel) is a working
demo of `y_ex` + Phoenix Channels driving **Excalidraw, Quill, BlockNote,
Lexical, Tiptap and ProseMirror**, all collaborating. It is a demo app rather
than a Hex package, so the transport layer is copy-paste today — but it proves
the whole Elixir half works, against six editors.

Two of those six are ProseMirror-based. Which means:

> If Leaf's core becomes ProseMirror (or Lexical), collaboration is largely
> **already built**. `y-prosemirror` binds the editor to a Y.Doc, `y_ex` holds
> it server-side, a Phoenix Channel carries the updates.

That inverts the cost estimate in the first draft of this document. The
expensive part is not the CRDT. It is Stage 1.

## Staged plan

### Stage 0 — `[[wiki-link]]` rendering

Not collaboration, listed first because it is the biggest single improvement,
independent of everything below, and shippable against Leaf as it stands.

Leaf already proves the mechanism: configuring a `#` suggestion trigger makes
hashtags render as tinted tokens in the visual and hybrid surfaces while the
markdown stays `#tag`. A `[[…]]` decoration would work the same way.

What we would need:

- `[[Target]]`, `[[Target|Alias]]`, `[[Target#Heading]]` rendered as a link token
  in hybrid and visual modes, with the source markers behaving as they do for
  other inline formatting.
- A host hook to resolve them, because only the host knows which targets exist:

  ```elixir
  # config, mirroring the suggestions API
  wiki_links: %{resolve: true}

  # Leaf asks
  {:leaf_resolve_links, %{editor_id: id, targets: ["ideas", "research/ideas"], seq: n}}

  # host answers, echoing seq
  send_update(Leaf, id: id, action: :link_targets, seq: n, targets: %{
    "ideas" => %{href: "/admin/knowledge-base/v/notes/abc", exists: true},
    "research/ideas" => %{href: "/…/notes/new?title=…", exists: false}
  })
  ```
- Clicking one emits `{:leaf_link_clicked, %{editor_id, target}}` so the host
  navigates. Unresolved targets styled distinctly, as Obsidian mutes them.

The server half of this is already built and tested here —
`PhoenixKitKnowledgeBase.Markdown.to_html/2` resolves `[[…]]` against a vault,
including the ambiguity rules — so the host side is ready the day Leaf can ask.

### Stage 1 — a document model

**This is the whole job.** Replace raw `contenteditable` with an editor core that
has addressable positions and a transaction log: **ProseMirror** (or Tiptap over
it) or **Lexical**.

It is a rewrite of Leaf's core, not an addition. Toolbar, hybrid live preview,
suggestions and the markdown round-trip all get rebuilt on top of the new model.
Worth being honest about that up front rather than discovering it in week three.

Why not build a CRDT directly on contenteditable: `y-prosemirror`, `y-quill` and
`y-lexical` all exist because those editors expose document models. There is no
`y-contenteditable`, and that is not an oversight.

Both viable targets have first-class Yjs bindings and both appear in the
`y-phoenix-channel` demo, so either choice keeps Stage 2 cheap. ProseMirror has
the richer markdown story; Lexical is lighter and newer.

### Stage 2 — bind to Yjs

Once there is a model, this is mostly assembly:

- `y-prosemirror` (or `y-lexical`) binds the editor to a `Y.Doc`
- the host holds the authoritative `Y.Doc` in `y_ex`
- a Phoenix Channel carries binary updates both ways
- `y_ex`'s Awareness carries cursors and presence

What Leaf needs to expose, and it is a short list:

1. **Accept a `Y.Doc` and an awareness instance at mount** — or expose the
   underlying editor view so the host can install the binding plugin itself.
   Built-in is friendlier; an escape hatch is enough.
2. **Emit local updates** as opaque binary for the host to broadcast.
3. **Apply remote updates without moving the local caret.** This is the point
   that makes or breaks the feel, and it is why this cannot be `set_content`
   with extra steps.
4. **Surface awareness state** so remote cursors can be drawn.

`content_changed` should stay exactly as it is. Hosts that only want "give me
the markdown" must not have to care — this whole path is additive.

### Stage 3 — awareness UI

Remote carets, selections, names, colours. Rendering work on top of data Yjs
already carries. Cheap, and it is what makes collaboration *feel* like Google
Docs rather than merely be it.

## Storage: settled

The first draft flagged a tension — a CRDT and file-based storage pull against
each other, and this vault is file-based on purpose so `rg`, `git`, `vim` and
Obsidian work directly on the notes.

**Resolved: the CRDT lives in Postgres while a note is being edited, and is
flushed to the file on a timer. The files are deliberately not real-time.**

That gives a clean rule for which copy is authoritative:

| Situation | Source of truth |
|---|---|
| No live editing session | the `.md` file |
| A session is open | the `Y.Doc` in Postgres; the file is a lagging export |

And a lifecycle:

1. **Hydrate** — first person opens a note with no live session: read the file,
   build a `Y.Doc` from its text, record the file's hash.
2. **Edit** — updates flow browser → channel → `y_ex` → fan-out to peers.
   Persisted to Postgres as they arrive, so a crash loses seconds, not work.
3. **Flush** — write the file, debounced after the last change and capped by a
   maximum interval, plus immediately when the last participant leaves and on
   graceful shutdown. Flushing also reindexes: hash, mtime, front matter, tags,
   links.
4. **Retire** — after an idle period with no participants, flush and drop the
   `Y.Doc`. The next session re-hydrates from the file.

Retiring rather than keeping CRDT state forever keeps storage bounded and
tombstones from accumulating across months. The cost is that a client which was
offline across a session boundary cannot merge its local updates — acceptable
when the document only exists in the browser while the page is open, which is
the case here.

Two details this leaves for the host, both ours to handle, neither Leaf's
problem:

- **External edits during a live session.** Someone runs `vim` on a file whose
  `Y.Doc` is live. Detect it at flush time by comparing the file's current hash
  against the one recorded at hydration — the same guard the app already uses
  for ordinary saves — and raise a conflict rather than letting the flush
  silently overwrite. Rescan should skip notes with a live session, or flush
  them first.
- **One session per note, cluster-wide.** The `Y.Doc` owner should be a single
  supervised process per note, registered globally. `Horde` (built on
  `delta_crdt`, already in the ecosystem) is the obvious fit if this ever runs
  on more than one node.

## What the host already provides

So the Leaf work is not blocked on us:

- **Per-vault PubSub** — note saves, deletes, folder changes and rescans already
  propagate to every open session, with origin tracking so a session ignores its
  own writes.
- **Conflict detection** — every write compares the file's hash against the one
  indexed when it was opened; the second writer is stopped rather than merged,
  and gets an explicit reload-or-overwrite choice. The flush guard above is the
  same mechanism.
- **Link resolution** — `[[…]]` targets resolved against a vault, including
  same-folder and shortest-path tie-breaking for ambiguous titles, plus
  path-qualified `[[folder/Note]]`.

Stage 0 could ship against that today.

## Practical notes

- `y_ex` depends on `rustler_precompiled`, so it downloads a prebuilt NIF on
  common targets and falls back to a source build otherwise — the same
  arrangement as `mdex`, which PhoenixKit already carries. On a machine that
  forces source builds, expect a Rust toolchain requirement.
- The transport layer in `y-phoenix-channel` is a demo, not a package. Whoever
  builds Stage 2 will be extracting it. That extraction — document lifecycle,
  Ecto persistence adapter, awareness fan-out, packaged JS — is a genuine gap on
  Hex and would be worth publishing once it has run in production. Worth doing
  *after* it works here, not before.

## Suggested first conversation

If only one thing gets built, make it **Stage 0**. It is independent, it is the
feature users notice most, and it commits nobody to the rewrite in Stage 1.

For Stage 1, the decision to make is narrow: **ProseMirror or Lexical.** Once
that lands, Stages 2 and 3 are largely wiring together libraries that already
exist and already work with Phoenix.
