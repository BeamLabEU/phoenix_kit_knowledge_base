defmodule PhoenixKitKnowledgeBase.LinksResolutionTest do
  @moduledoc """
  The tie-break that makes a bare `[[Title]]` unambiguous when the filesystem
  allows two files to share a name.

  Pure: `resolve/3` takes a prebuilt resolver, so these run without a database.
  This is the logic most likely to be quietly wrong — a link that resolves to
  the *wrong* note looks exactly like one that resolved correctly.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitKnowledgeBase.Links

  defp note(path) do
    folder =
      case Path.dirname(path) do
        "." -> ""
        dir -> dir
      end

    %{
      uuid: path,
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

  describe "unambiguous links" do
    test "a single match resolves regardless of where the link was written" do
      resolver = resolver(["research/Ideas.md"])

      assert Links.resolve(resolver, "ideas", "").relative_path == "research/Ideas.md"
      assert Links.resolve(resolver, "ideas", "archive").relative_path == "research/Ideas.md"
    end

    test "no match resolves to nil rather than guessing" do
      assert Links.resolve(resolver(["A.md"]), "missing", "") == nil
    end

    test "an empty or nil key never resolves" do
      resolver = resolver(["A.md"])
      assert Links.resolve(resolver, "", "") == nil
      assert Links.resolve(resolver, nil, "") == nil
    end
  end

  describe "tie-breaking between same-named notes" do
    setup do
      %{resolver: resolver(["Ideas.md", "research/Ideas.md", "archive/deep/Ideas.md"])}
    end

    test "a note in the same folder wins", %{resolver: resolver} do
      assert Links.resolve(resolver, "ideas", "research").relative_path == "research/Ideas.md"

      assert Links.resolve(resolver, "ideas", "archive/deep").relative_path ==
               "archive/deep/Ideas.md"
    end

    test "otherwise the shortest path wins", %{resolver: resolver} do
      # From a folder with no local match, the note nearest the vault root is
      # the more general one and the likelier intent.
      assert Links.resolve(resolver, "ideas", "somewhere/else").relative_path == "Ideas.md"
      assert Links.resolve(resolver, "ideas", "").relative_path == "Ideas.md"
    end

    test "the answer is stable rather than whatever the database returned first" do
      shuffled = resolver(["archive/deep/Ideas.md", "Ideas.md", "research/Ideas.md"])
      assert Links.resolve(shuffled, "ideas", "").relative_path == "Ideas.md"
    end

    test "ambiguity is reported so the UI can flag a guessed link", %{resolver: resolver} do
      assert Links.candidate_count(resolver, "ideas") == 3
      assert Links.candidate_count(resolver, "unique") == 0
    end
  end

  describe "path-qualified links" do
    setup do
      %{resolver: resolver(["Ideas.md", "research/Ideas.md"])}
    end

    test "match the path exactly and are never ambiguous", %{resolver: resolver} do
      assert Links.resolve(resolver, "research/ideas", "").relative_path == "research/Ideas.md"
      assert Links.candidate_count(resolver, "research/ideas") == 1
    end

    test "beat the tie-break, which is the entire point", %{resolver: resolver} do
      # Written from inside research/, a bare [[Ideas]] would pick the local
      # one; the qualified form must be able to reach the root note instead.
      assert Links.resolve(resolver, "ideas", "research").relative_path == "research/Ideas.md"
      assert Links.resolve(resolver, "ideas", "").relative_path == "Ideas.md"
    end

    test "a qualified link to a path that does not exist stays unresolved", %{resolver: resolver} do
      assert Links.resolve(resolver, "nope/ideas", "") == nil
      assert Links.candidate_count(resolver, "nope/ideas") == 0
    end
  end

  describe "path_key/1" do
    test "drops the extension and normalises, so links match paths" do
      assert Links.path_key("Research/My Note.md") == "research/my note"
      assert Links.path_key("Note.md") == "note"
    end
  end
end
