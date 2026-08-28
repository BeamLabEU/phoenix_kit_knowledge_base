# A rendered `[[wiki-link]]` cannot be clicked in hybrid mode

Notes for Alex, from wiring Leaf 0.6.0's `wiki_links` into
`phoenix_kit_knowledge_base`.

The rendering is lovely. Clicking is not reachable: neither a plain click nor
Ctrl/Cmd-click ever follows a link in hybrid mode. What happens instead is that
the block swaps to its markdown source, so the link becomes `[[Target]]` text
under the caret and reads as broken.

Reported from the browser by the person using it, twice — once for a plain
click, and again after being told to use Ctrl/Cmd-click.

## Why

`_onWikiLinkClick` is bound to the `click` event on `_visualEl`, and it guards
on the span still being in the document:

```js
var span = e.target && e.target.closest
  ? e.target.closest("[data-leaf-wikilink]")
  : null;

if (!span || !this._visualEl.contains(span)) return;
```

But hybrid's source swap runs off `selectionchange`, and a mouse press updates
the selection **before** `click` is dispatched. So the order is:

1. `mousedown` — the browser places the caret inside the block holding the link
2. `selectionchange` — `_updateSourceBlock()` swaps that block to its
   `<p data-leaf-source="…">` form, replacing the subtree and with it the
   `[data-leaf-wikilink]` span
3. `click` — `_onWikiLinkClick` runs against a span that is no longer in
   `_visualEl`, so `contains(span)` is false and it returns

The modifier never gets considered, which is why `follow: :modifier` and
`follow: :click` fail identically: the failure is upstream of that check. It is
silent from the host's side — no `{:leaf_link_clicked, …}` is ever sent, so
there is nothing to log.

Consistent with the symptom: `_updateSourceBlock` bails early when the mode is
not `hybrid`, so a visual-mode surface should be unaffected, and a read-only
surface probably is too — no caret is placed, so no swap.

## Suggestions

Capturing the span on `mousedown`, before the selection moves, and acting on it
at `click` would survive the swap. Handling the follow on `mousedown` outright
would too, at the cost of firing before a click is really complete.

There may also be a case for `follow: :click` as the default. The code comment
says `:modifier` is "the gesture Obsidian uses in edit mode", but Obsidian's
Live Preview — the mode Leaf's hybrid corresponds to — follows a plain click,
and that is what the person here expected and asked for. It is only a default;
we set `:click` explicitly.

## What we did meanwhile

Set `follow: :click`, which is the behaviour we want and what will happen the
moment the ordering is fixed. Nothing else is available to us: the handler is
inside Leaf's bundle, which is lazy-loaded from jsDelivr by core's vendored
`phoenix_kit.js`, and this module ships no JavaScript of its own by design.

The outgoing-links panel is still the working way to navigate, which is why it
exists.
