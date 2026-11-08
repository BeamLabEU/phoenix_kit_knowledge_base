defmodule PhoenixKitKnowledgeBase.Integration.IndexingLimitsTest do
  @moduledoc """
  What the index refused by raising until 2026-11-08: values longer than the
  `varchar(255)` V1 gave paths and link targets, and bytes Postgres cannot hold
  in `text` at all. Each of these made a save crash the page, and the file it
  left behind made every later rescan of its vault crash too.
  """
  use PhoenixKitKnowledgeBase.DataCase

  # The rescan logs each file it could not index; that is the point here.
  @moduletag :capture_log

  alias PhoenixKitKnowledgeBase.{Links, Notes, Places, Rescan, Storage}
  alias PhoenixKitKnowledgeBase.Schemas.NoteLink

  setup do
    user = user_fixture()
    {:ok, place} = Places.parse(["Limits"], :private)
    {:ok, vault} = Places.ensure(place, user)
    %{vault: vault, user: user, dir: Storage.vault_path(vault.directory)}
  end

  defp create(vault, user, title, content, folder \\ "") do
    Notes.create_note(vault, %{title: title, content: content, folder_path: folder}, user.uuid)
  end

  describe "lengths a path or a link may reach" do
    test "a 300-character [[link]] is stored, not raised over", %{vault: vault, user: user} do
      target = String.duplicate("x", 300)
      assert {:ok, note} = create(vault, user, "Long link", "see [[#{target}]]")

      assert [%NoteLink{target_title: ^target}] =
               Repo.all(from(l in NoteLink, where: l.source_note_uuid == ^note.uuid))
    end

    test "a [[…]] past 1,000 bytes is prose, not a link", %{vault: vault, user: user} do
      assert {:ok, note} = create(vault, user, "Huge", "[[#{String.duplicate("y", 1200)}]]")
      assert Repo.all(from(l in NoteLink, where: l.source_note_uuid == ^note.uuid)) == []
    end

    test "a tag longer than 255 characters is not a tag", %{vault: vault, user: user} do
      long = String.duplicate("t", 300)
      assert {:ok, note} = create(vault, user, "Tagged", "#short and ##{long}")
      assert note.tags == ["short"]
    end

    test "a note nested deeper than 255 characters is indexed by a rescan", %{
      vault: vault,
      dir: dir
    } do
      deep = Enum.map_join(1..6, "/", &String.duplicate("d#{&1}", 30))
      File.mkdir_p!(Path.join(dir, deep))
      File.write!(Path.join([dir, deep, "Deep.md"]), "deep down")

      assert {:ok, %{added: 1, errors: []}} = Rescan.run(vault)
      assert %{title: "Deep"} = Notes.get_note_by_path(vault.uuid, Path.join(deep, "Deep.md"))
      assert Notes.get_folder_by_path(vault.uuid, deep)
    end
  end

  describe "bytes that are not text" do
    test "a NUL from the editor is refused before the file is touched", %{
      vault: vault,
      user: user,
      dir: dir
    } do
      assert {:error, :not_text} = create(vault, user, "Nullish", "a\0b")
      refute File.exists?(Path.join(dir, "Nullish.md"))

      {:ok, note} = create(vault, user, "Fine", "before")
      assert {:error, :not_text} = Notes.update_content(vault, note, "a\0b")
      assert File.read!(Path.join(dir, "Fine.md")) == "before"
    end

    test "one unreadable file is one error, and the rest of the vault is still indexed", %{
      vault: vault,
      dir: dir
    } do
      File.write!(Path.join(dir, "Latin1.md"), <<"caf", 0xE9>>)
      File.write!(Path.join(dir, "Binary.md"), "x\0y")
      File.write!(Path.join(dir, "Fine.md"), "fine")

      assert {:ok, report} = Rescan.run(vault)
      assert report.added == 1
      assert Enum.sort(Enum.map(report.errors, & &1.path)) == ["Binary.md", "Latin1.md"]
      assert Enum.all?(report.errors, &(&1.reason =~ "UTF-8"))
      assert [%{title: "Fine"}] = Notes.list_notes(vault.uuid)

      # And again: the file is still there, and still not a crash.
      assert {:ok, %{errors: [_, _]}} = Rescan.run(vault)
    end

    test "an indexed note edited into binary keeps its last good row", %{
      vault: vault,
      user: user,
      dir: dir
    } do
      {:ok, note} = create(vault, user, "Turns", "good text")
      File.write!(Path.join(dir, "Turns.md"), "bad\0text")

      assert {:ok, %{errors: [%{path: "Turns.md"}]}} = Rescan.run(vault)
      assert %{content: "good text"} = Notes.get_note(vault.uuid, note.uuid)
      # The stale guard still protects the file from a save made against it.
      assert {:error, :stale} = Notes.update_content(vault, note, "overwrite")
    end
  end

  test "a note naming another two ways is one linked mention, not two", %{
    vault: vault,
    user: user
  } do
    {:ok, _} = Notes.create_folder(vault, "", "f")
    {:ok, target} = create(vault, user, "Target", "", "f")
    {:ok, _} = create(vault, user, "Source", "[[Target]] and [[f/Target]]")

    assert [%{title: "Source"}] = Links.backlinks(target)
  end
end
