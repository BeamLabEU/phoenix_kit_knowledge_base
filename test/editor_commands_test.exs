defmodule PhoenixKitKnowledgeBase.EditorCommandsTest do
  @moduledoc """
  The two Leaf settings that are invisible until someone uses the app.

  Both are the same shape of bug as the constant editor id: the server is
  correct, the LiveView renders without error, `mix test` is green, and the
  person in front of the browser sees the wrong thing. Neither can be caught by
  a rendering test — Leaf's surfaces are `phx-update="ignore"` and its
  suggestion matching happens in the client — so what is pinned here is the
  server-side half that has to be right for the client half to work at all.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitKnowledgeBase.Schemas.Note
  alias PhoenixKitKnowledgeBase.Web.VaultLive

  @note %Note{
    uuid: "01a03ad8-7402-7749-ba28-95af9a1a755c",
    content: "# Reloaded from disk"
  }

  describe "push_editor_content/2" do
    test "reloading a note pushes set_content, not just an assign" do
      # Assigning `@content` alone is what the Reload button used to do, and it
      # changed nothing on screen: `phx-update="ignore"` means LiveView never
      # patches the editor, and Leaf's own `update/2` pushes nothing to the
      # client unless the host asks with `:set_content`.
      VaultLive.push_editor_content(:socket, @note)

      assert_received {:phoenix, :send_update, {{Leaf, id}, assigns}}
      assert id == VaultLive.editor_id(@note)
      assert assigns.action == :set_content
      assert assigns.content == "# Reloaded from disk"
    end

    test "the command is addressed to this note's editor, not a shared one" do
      other = %Note{@note | uuid: "01a03ae4-2ada-77f3-911e-ebf42851e4bc"}

      VaultLive.push_editor_content(:socket, @note)
      assert_received {:phoenix, :send_update, {{Leaf, first}, _}}

      VaultLive.push_editor_content(:socket, other)
      assert_received {:phoenix, :send_update, {{Leaf, second}, _}}

      refute first == second
    end

    test "a note with no content pushes an empty string rather than nil" do
      # Leaf sanitises the markdown it is given; nil would raise there instead
      # of clearing the buffer.
      VaultLive.push_editor_content(:socket, %Note{@note | content: nil})

      assert_received {:phoenix, :send_update, {{Leaf, _}, assigns}}
      assert assigns.content == ""
    end
  end

  describe "suggestion tokens" do
    defp config(trigger) do
      Enum.find(VaultLive.suggestion_configs(), &(&1.trigger == trigger))
    end

    # Leaf compiles `:token` into `new RegExp("^" + token + "$", "u")` and tests
    # it against each typed character; anything that fails closes the popup.
    defp accepts?(token, char), do: Regex.match?(Regex.compile!("^" <> token <> "$", "u"), char)

    test "both triggers set a token at all" do
      # The whole bug: Leaf's default is `[\p{L}\p{N}_-]`, which is wrong for
      # both of these, and inheriting it fails nothing.
      assert config("[[").token
      assert config("#").token
    end

    test "[[ keeps completing across a space" do
      # `Attention Is All You Need` is a real note title. Under the default
      # token the popup closed at "Attention".
      assert accepts?(config("[[").token, " ")
    end

    test "[[ keeps completing across the characters a link target may hold" do
      token = config("[[").token

      # `folder/Note` disambiguates, `Note#Heading` anchors, `Note|alias` renames.
      for char <- ["/", "#", "|", "^", ".", ",", "'", "(", "é", "日"] do
        assert accepts?(token, char), "expected #{char} to keep the [[ popup open"
      end
    end

    test "[[ stops at the characters that end a link" do
      token = config("[[").token

      # `]` closes the link — the popup must not swallow it, or `insert_suffix`
      # produces `]]]]`. `[` would mean a second link started.
      refute accepts?(token, "]")
      refute accepts?(token, "[")
      refute accepts?(token, "\n")
    end

    test "[[ matches the parser, so every completion is a link that parses back" do
      # `Markdown.@wiki_link_regex` is `[^\[\]\n]+`. A token looser than the
      # parser would suggest links the parser cannot read.
      assert config("[[").token == "[^\\[\\]\\n]"
    end

    test "# completes nested tags" do
      # `#project/alpha` is one tag, not a tag followed by a path.
      assert accepts?(config("#").token, "/")
    end

    test "# accepts what the tag parser accepts, and no more" do
      token = config("#").token

      for char <- ["a", "Z", "7", "_", "-", "é"], do: assert(accepts?(token, char))
      # A space ends a tag; so does the `#` that would start the next one.
      refute accepts?(token, " ")
      refute accepts?(token, "#")
    end
  end
end
