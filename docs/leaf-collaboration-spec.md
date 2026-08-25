# What Leaf needs for multi-user editing

Notes for Alex, from building `phoenix_kit_knowledge_base` on Leaf 0.5.1.

The goal is Google-Docs-style editing: two people in the same note, both typing,
both seeing each other's characters appear, nothing lost. This document is what
that requires from Leaf, staged so it can be built in order — each stage is
independently useful, and the vault gets better at every step.

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

## Staged plan

### Stage 0 — `[[wiki-link]]` rendering (unrelated, but the thing we want most)

Not collaboration, listed first because it is the biggest single improvement and
is independent of everything below.

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
  navigates. Unresolved targets styled distinctly (Obsidian shows them muted).

We already have the server half of this working and tested —
`PhoenixKitKnowledgeBase.Markdown.to_html/2` resolves `[[…]]` against a vault,
including the ambiguity rules — so the host side is ready the day Leaf can ask.

### Stage 1 — a document model

The prerequisite for everything after it. Replace raw `contenteditable` with an
editor core that has addressable positions and a transaction log:
**ProseMirror** (or Tiptap over it), or **Lexical**.

This is the expensive step and it is a rewrite of Leaf's core, not an addition.
Toolbar, hybrid live preview, suggestions and the markdown round-trip all get
rebuilt on top of the new model. Worth being honest about that up front rather
than discovering it in week three.

Why not build a CRDT directly on contenteditable: `y-prosemirror`, `y-quill` and
`y-lexical` all exist because those editors expose document models. There is no
`y-contenteditable`, and that is not an oversight.

### Stage 2 — operations on the wire

Once there is a model, emit changes as operations rather than snapshots:

```elixir
{:leaf_ops, %{editor_id: id, version: 42, ops: [...]}}
```

Keep `content_changed` as it is — hosts that only want "give me the markdown"
should not have to care. This is additive.

At this point the host can persist meaningfully more often and, importantly, can
tell *what* changed.

### Stage 3 — CRDT as the source of truth

Bind the model to **Yjs** (`y-prosemirror` is the well-trodden path). The Y.Doc
becomes authoritative; the editor renders it; markdown becomes a projection.

Transport is the host's problem, not Leaf's — we already have Phoenix PubSub
carrying per-vault messages and would carry Yjs updates the same way. What Leaf
needs to expose:

- a way to hand it a `Y.Doc` (or a provider) at mount
- emit local updates as opaque binary for the host to broadcast
- accept remote updates and apply them **without moving the local caret**

That last point is the one that makes or breaks the feel. It is why this cannot
be `set_content` with extra steps.

### Stage 4 — awareness

Remote cursors, selections and names. Yjs has `awareness` built in; this is
mostly rendering once Stage 3 exists. Cheap, and it is the part that makes
collaboration *feel* like Google Docs rather than merely be it.

## One design decision worth settling early

**A CRDT and file-based storage pull against each other**, and this vault is
file-based on purpose — notes are `.md` files on disk so `rg`, `git`, `vim` and
Obsidian all work on them directly.

If a Y.Doc is authoritative, then:

- the CRDT state has to be persisted somewhere (a blob in Postgres), and
- the `.md` file becomes a derived export, needing a flush policy, and
- an edit made in `vim` while a CRDT session is live has no defined merge — the
  file changed underneath a document whose history knows nothing about it.

It is not a coincidence that Obsidian is file-based and has no live co-editing;
Obsidian Sync resolves at file level, exactly as we do today.

A workable answer, if you want both: treat the CRDT as a **session** artifact
rather than the permanent record. The file stays authoritative at rest; opening
a note for collaborative editing hydrates a Y.Doc from it; the doc is flushed
back on idle and torn down when the last participant leaves. External edits are
then only ambiguous while a session is live, which is a much smaller problem than
the general one — and can be handled by refusing to start a session on a file
whose hash has moved.

Worth deciding before Stage 3, because it determines whether the Y.Doc needs
durable storage at all.

## What the host already provides

So the Leaf work is not blocked on us:

- **Per-vault PubSub** — note saves, deletes, folder changes and rescans already
  propagate to every open session, with origin tracking so a session ignores its
  own writes.
- **Conflict detection** — every write compares the file's hash against the one
  indexed when it was opened; the second writer is stopped rather than merged,
  and gets an explicit reload-or-overwrite choice.
- **Link resolution** — `[[…]]` targets resolved against a vault, including
  same-folder and shortest-path tie-breaking for ambiguous titles, plus
  path-qualified `[[folder/Note]]`.

Stage 0 could ship against that today.

## Suggested first conversation

If only one thing gets built, make it **Stage 0**. It is independent, it is the
feature users notice most, and it does not commit anyone to the rewrite in
Stage 1.

Stages 1–4 are worth scoping as a Leaf 1.0 rather than a point release.
