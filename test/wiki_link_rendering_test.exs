defmodule PhoenixKitKnowledgeBase.WikiLinkRenderingTest do
  @moduledoc """
  What a `[[wiki-link]]` renders as inside the editor.

  Leaf decorates the links and asks the host which targets exist; this is the
  answer. It has to agree with the stored link index — same resolver, same
  same-folder tie-break — or a link renders as pointing at one note while the
  backlinks panel says another.

  Pure: `link_targets/4` takes a prebuilt resolver, so these run without a
  database, the same split as `Links.resolve/3`.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitKnowledgeBase.Links
  alias PhoenixKitKnowledgeBase.Web.VaultLive

  defp note(path) do
    folder =
      case Path.dirname(path) do
        "." -> ""
        dir -> dir
      end

    %{
      uuid: "uuid-for-" <> path,
      title_key: path |> Path.basename(".md") |> String.downcase(),
      relative_path: path,
      folder_path: folder
    }
  end

  defp resolver(paths) do
    notes = Enum.map(paths, &note/1)

    %{
      by_title: Enum.group_by(notes, & &1.title_key),
      by_path: Map.new(notes, &{Links.path_key(&1.relative_path), &1})
    }
  end

  defp targets(paths, from_folder, asked, can_write? \\ true) do
    VaultLive.link_targets(resolver(paths), "research-vault", from_folder, asked, can_write?)
  end

  describe "a target that exists" do
    test "is marked as existing and points at that note" do
      %{"Ideas" => link} = targets(["research/Ideas.md"], "", ["Ideas"])

      assert link.exists
      assert link.href =~ "uuid-for-research/Ideas.md"
      assert link.href =~ "research-vault"
    end

    test "resolves by the same tie-break the link index uses" do
      # Same folder as the linking note wins over a shorter path — the rule
      # `Links.resolve/3` documents. A link that rendered by a different rule
      # would disagree with the backlinks panel.
      %{"Ideas" => link} =
        targets(["Ideas.md", "archive/Ideas.md"], "archive", ["Ideas"])

      assert link.href =~ "uuid-for-archive/Ideas.md"
    end

    test "a path-qualified target is exact" do
      %{"research/Ideas" => link} =
        targets(["research/Ideas.md", "archive/Ideas.md"], "archive", ["research/Ideas"])

      assert link.href =~ "uuid-for-research/Ideas.md"
    end

    test "the tooltip names the note, so a guessed link says where it went" do
      %{"Ideas" => link} = targets(["research/Ideas.md"], "", ["Ideas"])
      assert link.title =~ "research/Ideas.md"
    end

    test "an ambiguous title says so, and says which note won" do
      # The link still resolves — but it was guessed at, and the author is the
      # only one who can tell whether the guess was right.
      %{"Ideas" => link} =
        targets(["research/Ideas.md", "archive/Ideas.md"], "archive", ["Ideas"])

      assert link.title =~ "2 notes share this title"
      assert link.title =~ "archive/Ideas.md"
    end
  end

  describe "how to open it" do
    # A plain click follows — `follow: :click`, which is Obsidian's Live Preview
    # behaviour and what this vault wants. The tooltip therefore carries the
    # destination rather than a gesture; there is only one gesture.

    test "the tooltip names the destination, not a gesture" do
      %{"Ideas" => link} = targets(["research/Ideas.md"], "", ["Ideas"], true)

      assert link.title == "research/Ideas.md"
      refute link.title =~ "Ctrl"
    end

    test "an unresolved target invites the reader to create it" do
      %{"Nowhere" => link} = targets(["Ideas.md"], "", ["Nowhere"], true)
      assert link.title =~ "click to create it"
    end

    test "a viewer is not told to create a note they cannot create" do
      %{"Nowhere" => link} = targets(["Ideas.md"], "", ["Nowhere"], false)

      assert link.title =~ "No note with this title yet"
      refute link.title =~ "create"
    end
  end

  describe "a target that does not exist" do
    test "is marked as missing and points at the create page" do
      %{"Nowhere" => link} = targets(["Ideas.md"], "", ["Nowhere"])

      refute link.exists
      assert link.href =~ "notes/new"
      assert link.href =~ "title=Nowhere"
    end

    test "carries wording of our own, since Leaf ships none" do
      %{"Nowhere" => link} = targets(["Ideas.md"], "", ["Nowhere"])
      assert link.title =~ "create"
    end

    test "a title needing escaping survives into the create link" do
      %{"Attention Is All You Need" => link} =
        targets([], "", ["Attention Is All You Need"])

      assert link.href =~ "Attention+Is+All+You+Need"
    end
  end

  describe "the batch" do
    test "every asked-for target is answered" do
      # Leaf keys its cache by target; a target left out of the reply is asked
      # for again on the next keystroke, forever.
      asked = ["Ideas", "Nowhere", "research/Ideas"]
      answered = targets(["research/Ideas.md"], "", asked)

      assert Enum.sort(Map.keys(answered)) == Enum.sort(asked)
    end

    test "targets differing only in case and spacing resolve to the same note" do
      # `normalize_title/1` is what makes "My  Note" and "my note" one note, and
      # the rendered link has to agree with that.
      answered = targets(["My Note.md"], "", ["my note", "My  Note"])

      assert answered["my note"].href == answered["My  Note"].href
      assert answered["my note"].exists
    end

    test "no targets is not an error" do
      assert targets(["Ideas.md"], "", []) == %{}
    end
  end
end
