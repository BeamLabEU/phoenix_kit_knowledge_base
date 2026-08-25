defmodule PhoenixKitKnowledgeBase.EditorIdentityTest do
  @moduledoc """
  Regression tests for two bugs that were invisible from the server's side and
  had to be found by using the app.

  Leaf's editing surfaces are `phx-update="ignore"`, so LiveView never patches
  them after mount. Under a constant component id, patching between notes reused
  the same hook and every note displayed whatever was loaded first — while the
  server happily believed it was showing the right one. Keying the id to the
  note fixes that, and makes a late-arriving edit from the previous note
  identifiable instead of being written into the note now open.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitKnowledgeBase.Web.VaultLive

  @note_a %{uuid: "01a03ad8-7402-7749-ba28-95af9a1a755c"}
  @note_b %{uuid: "01a03ae4-2ada-77f3-911e-ebf42851e4bc"}

  describe "editor_id/1" do
    test "two notes never share an editor id" do
      # The constant id was the bug: same id, same component, same hook, and
      # the second note rendered the first one's text.
      refute VaultLive.editor_id(@note_a) == VaultLive.editor_id(@note_b)
    end

    test "the id is stable for a given note" do
      assert VaultLive.editor_id(@note_a) == VaultLive.editor_id(@note_a)
    end

    test "the id contains the note uuid, which is what makes staleness detectable" do
      assert VaultLive.editor_id(@note_a) =~ @note_a.uuid
    end

    test "a missing note still yields a usable id rather than raising" do
      assert is_binary(VaultLive.editor_id(nil))
    end
  end

  describe "save_decision/3" do
    defp payload(note, markdown, opts \\ []) do
      %{
        editor_id: VaultLive.editor_id(note),
        markdown: markdown,
        dirty: Keyword.get(opts, :dirty, true)
      }
    end

    test "a genuine edit to the open note is saved" do
      assert :save = VaultLive.save_decision(payload(@note_a, "new text"), @note_a, "old text")
    end

    test "an edit from a note that is no longer open is dropped" do
      # The data-loss case: Leaf debounces, so B can still be open when A's
      # keystrokes arrive. Saving them would write A's text into B's file.
      assert :stale = VaultLive.save_decision(payload(@note_a, "A's text"), @note_b, "B's text")
    end

    test "anything arriving with no note open is dropped" do
      assert :stale = VaultLive.save_decision(payload(@note_a, "text"), nil, "")
    end

    test "a non-dirty report is not a save" do
      # Leaf sends this when the buffer still matches what it loaded — opening a
      # note must not rewrite its file and bump its mtime.
      assert :unchanged =
               VaultLive.save_decision(payload(@note_a, "same", dirty: false), @note_a, "same")
    end

    test "content identical to what is already assigned is not a save" do
      assert :unchanged = VaultLive.save_decision(payload(@note_a, "same"), @note_a, "same")
    end

    test "a payload with no dirty flag is treated as a real edit" do
      # Older Leaf builds omit it; defaulting to \"not an edit\" would silently
      # stop saving altogether.
      bare = %{editor_id: VaultLive.editor_id(@note_a), markdown: "typed"}
      assert :save = VaultLive.save_decision(bare, @note_a, "before")
    end
  end
end
