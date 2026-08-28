# A refused flush is silent, and the session's work is then discarded

Notes for Alex, from wiring Leaf 0.6.0's live editing into
`phoenix_kit_knowledge_base`. Reproduced against a real database and
filesystem; the script is `scripts/verify_collab.exs` in that repo.

The store contract is right and the room honours it: a `{:error, :conflict}`
from `flush/2` does stop it overwriting somebody else's work. What is missing is
that **nobody is ever told**, and the work it protected is thrown away.

## What happens

`Leaf.Collab.Room.flush/1`:

```elixir
{:error, :conflict} ->
  # Somebody edited the document outside this session. Both copies are
  # somebody's work, and this one is not more entitled to exist, so it
  # stays in memory and stops trying to overwrite theirs.
  %{state | deadline: nil, timer: nil, conflict: true}
```

`conflict: true` is set on the state and read by nothing. There is no
broadcast on the room's topic, no reply to any session, and `conflict` does not
appear anywhere in `Leaf.Collab` — so no assign changes and no host hook fires.

Then:

- **`flush_now/1` reports success regardless.** `handle_call(:flush_now, _from,
  state) do {:reply, :ok, flush(state)} end` discards what `flush/1` produced.
  A host doing save-before-navigate is told the save worked.
- **`dirty` stays true**, so the next keystroke reschedules a flush, which
  conflicts again, forever. Silently.
- **`terminate/2` calls `flush/1` one last time**, which conflicts one last
  time. The room then dies holding the only copy of everything typed since the
  conflict.

## The sequence, as observed

1. Two people are editing a note; the room flushes normally
2. The file changes underneath — `git checkout`, an editor, another tool
3. Everything typed from here on is never written to disk
4. Nothing in the UI differs. There is no way for a host to notice
5. The last person closes the tab; the room stops and the work is gone

Checks 10–15 of `verify_collab.exs` walk exactly this, ending with a fresh room
loading the outside copy and the session's text nowhere.

This matters more for a vault than for most hosts: notes are files precisely so
that `rg`, `git`, `vim` and the Obsidian client can work on them directly.
"Somebody edited the file outside the app" is a designed-for event here, not an
edge case.

## Suggestions

The room already knows. Any of these would be enough, cheapest first:

- **Broadcast it.** The room has a topic and every session is on it. A
  `{:leaf_conflict, %{document_id:}}` consumed by `Leaf.Collab`'s hook into a
  `@leaf_collab.conflict` assign would let a host render a banner, which is all
  most hosts need.
- **Return it from `flush_now/1`.** `{:reply, result, new_state}` rather than a
  hardcoded `:ok`. This one is nearly free and makes save-before-navigate
  honest.
- **Say something on the way down.** `terminate/2` discarding the document
  after a conflict is the part that actually loses work. Even a
  `Logger.warning` naming the document id would turn silent loss into a
  diagnosable one.

The asymmetry is worth noting on its own: `{:error, _reason}` for any *other*
store failure leaves the room dirty so the next change retries, which is right.
Conflict is the one case that can never succeed on its own and it is the one
case nobody is told about.

## What we did meanwhile

Our store broadcasts on our own PubSub topic before returning the conflict, so
the editor can raise a banner. That is a workaround in the one place we control
— it only exists because our store is ours; a host using
`Leaf.Collab.Store.File` has no such hook and would have no warning at all.
