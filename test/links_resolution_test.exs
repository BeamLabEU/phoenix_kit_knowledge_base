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

    test "an uppercase extension drops the same way, matching the walk" do
      assert Links.path_key("Research/Note.MD") == "research/note"
    end
  end

  describe "re-resolving links after the vault changes" do
    # The bug this exists for: `resolve_for_note/1` only fills rows whose
    # target is nil, so a link that resolved once never reconsiders. Creating a
    # nearer same-named note left the link pointing at the far one, rendered as
    # resolved, with nothing to tell the author it went to the wrong note.

    defp link(uuid, key, from_folder, current) do
      %{
        uuid: uuid,
        target_key: key,
        from_folder: from_folder,
        current: current,
        source_uuid: "archive/A.md"
      }
    end

    test "an already-resolved link moves to a nearer note that has since appeared" do
      # 1. archive/A.md writes [[Ideas]] — nothing to point at
      # 2. research/Ideas.md is created — the link resolves there
      # 3. archive/Ideas.md is created — same folder as the linker, so it wins
      rows = [link("l1", "ideas", "archive", "research/Ideas.md")]
      resolver = resolver(["research/Ideas.md", "archive/Ideas.md"])

      assert [{"l1", "archive/Ideas.md"}] = Links.changed_targets(rows, resolver)
    end

    test "a link already pointing at the right note is left alone" do
      # Nothing to write, so nothing is written — the re-resolve is cheap on
      # the overwhelmingly common case of nothing having changed.
      rows = [link("l1", "ideas", "archive", "archive/Ideas.md")]
      resolver = resolver(["research/Ideas.md", "archive/Ideas.md"])

      assert [] = Links.changed_targets(rows, resolver)
    end

    test "a link resolves when the note it names is finally written" do
      rows = [link("l1", "ideas", "archive", nil)]

      assert [{"l1", "research/Ideas.md"}] =
               Links.changed_targets(rows, resolver(["research/Ideas.md"]))
    end

    test "a link becomes unresolved when the note it pointed at is gone" do
      # Deleting the only Ideas.md: the mention survives the target, which is
      # what makes the unresolved-links list a to-do list.
      rows = [link("l1", "ideas", "archive", "research/Ideas.md")]

      assert [{"l1", nil}] = Links.changed_targets(rows, resolver(["Other.md"]))
    end

    test "deleting one of two same-named notes hands its links to the survivor" do
      # `nilify_all` on the FK unresolves them; that is only right if nothing
      # else answers to the name.
      rows = [link("l1", "ideas", "archive", nil)]

      assert [{"l1", "research/Ideas.md"}] =
               Links.changed_targets(rows, resolver(["research/Ideas.md"]))
    end

    test "a path-qualified link ignores a nearer note entirely" do
      # Writing [[research/Ideas]] is how you say you meant that one; a new
      # archive/Ideas.md must not steal it.
      rows = [
        %{
          uuid: "l1",
          target_key: "research/ideas",
          from_folder: "archive",
          current: "research/Ideas.md",
          source_uuid: "archive/A.md"
        }
      ]

      assert [] =
               Links.changed_targets(rows, resolver(["research/Ideas.md", "archive/Ideas.md"]))
    end

    test "a note that ends up linking to itself is left unresolved, not self-linked" do
      # Reachable by renaming a note to the title it already links to. A
      # self-backlink is noise, and `reindex_note/2` drops those rows too.
      rows = [
        %{
          uuid: "l1",
          target_key: "ideas",
          from_folder: "archive",
          current: nil,
          source_uuid: "archive/Ideas.md"
        }
      ]

      assert [] = Links.changed_targets(rows, resolver(["archive/Ideas.md"]))
    end

    test "several links wanting the same title are all re-pointed" do
      rows = [
        link("l1", "ideas", "archive", "research/Ideas.md"),
        link("l2", "ideas", "archive", "research/Ideas.md")
      ]

      assert [{"l1", "archive/Ideas.md"}, {"l2", "archive/Ideas.md"}] =
               Links.changed_targets(rows, resolver(["research/Ideas.md", "archive/Ideas.md"]))
    end
  end
end
