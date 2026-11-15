defmodule PhoenixKitKnowledgeBase.Integration.NotesListingTest do
  @moduledoc """
  The two narrowed reads a notes panel polls with: one level of folders, and
  notes without their bodies.
  """
  use PhoenixKitKnowledgeBase.DataCase

  alias PhoenixKitKnowledgeBase.{Notes, Places}

  setup do
    user = user_fixture()
    {:ok, place} = Places.parse(["Listing"], :private)
    {:ok, vault} = Places.ensure(place, user)
    %{vault: vault, user: user}
  end

  defp folders(vault, parent),
    do: vault.uuid |> Notes.list_folders(parent: parent) |> Enum.map(& &1.relative_path)

  describe "list_folders/2 with :parent" do
    test "only the level directly inside, at the root and below", %{vault: vault} do
      {:ok, _} = Notes.create_folder(vault, "a/b", "c")
      {:ok, _} = Notes.create_folder(vault, "", "d")

      assert folders(vault, "") == ["a", "d"]
      assert folders(vault, "a") == ["a/b"]
      assert folders(vault, "a/b") == ["a/b/c"]
      assert folders(vault, "a/b/c") == []
    end

    test "a name with LIKE's wildcards in it matches only itself", %{vault: vault} do
      {:ok, _} = Notes.create_folder(vault, "50%_off", "x")
      {:ok, _} = Notes.create_folder(vault, "50ab off", "y")

      assert folders(vault, "50%_off") == ["50%_off/x"]
    end

    test "without it, every folder, as before", %{vault: vault} do
      {:ok, _} = Notes.create_folder(vault, "a", "b")
      assert vault.uuid |> Notes.list_folders() |> Enum.map(& &1.relative_path) == ["a", "a/b"]
    end
  end

  describe "relocate_folder/3" do
    test "the folder and everything under it keep their uuids", %{vault: vault, user: user} do
      {:ok, parent} = Notes.create_folder(vault, "", "research")
      {:ok, child} = Notes.create_folder(vault, "research", "notes")

      {:ok, note} =
        Notes.create_note(
          vault,
          %{title: "Ideas", folder_path: "research/notes", content: "kept"},
          user.uuid
        )

      assert {:ok, moved} = Notes.relocate_folder(vault, parent, "archive")
      assert moved.uuid == parent.uuid
      assert moved.relative_path == "archive"
      assert moved.name == "archive"

      assert %{uuid: child_uuid, name: "notes", relative_path: "archive/notes"} =
               Notes.get_folder(vault.uuid, child.uuid)

      assert child_uuid == child.uuid

      saved = Notes.get_note(vault.uuid, note.uuid)
      assert saved.relative_path == "archive/notes/Ideas.md"
      assert saved.folder_path == "archive/notes"
      assert saved.content == "kept"

      refute Notes.get_folder_by_path(vault.uuid, "research")
      refute Notes.get_folder_by_path(vault.uuid, "research/notes")
    end

    test "a name with LIKE's wildcards in it does not take a neighbour along", %{vault: vault} do
      {:ok, wild} = Notes.create_folder(vault, "", "50%_off")
      {:ok, inner} = Notes.create_folder(vault, "50%_off", "x")
      {:ok, neighbour} = Notes.create_folder(vault, "", "50ab off")
      {:ok, beside} = Notes.create_folder(vault, "50ab off", "y")

      assert {:ok, moved} = Notes.relocate_folder(vault, wild, "sale")
      assert moved.uuid == wild.uuid
      assert Notes.get_folder(vault.uuid, inner.uuid).relative_path == "sale/x"
      assert Notes.get_folder(vault.uuid, neighbour.uuid).relative_path == "50ab off"
      assert Notes.get_folder(vault.uuid, beside.uuid).relative_path == "50ab off/y"
    end
  end

  describe "list_notes/2 with content: false" do
    test "everything a listing needs, and not the body", %{vault: vault, user: user} do
      {:ok, note} =
        Notes.create_note(vault, %{title: "Big", content: "#tagged\n\nthe whole text"}, user.uuid)

      assert [listed] = Notes.list_notes(vault.uuid, content: false)
      assert listed.content == ""
      assert listed.uuid == note.uuid
      assert listed.title == "Big"
      assert listed.relative_path == note.relative_path
      assert listed.title_key == note.title_key
      assert listed.tags == ["tagged"]
      assert listed.updated_at == note.updated_at

      assert [%{content: "#tagged\n\nthe whole text"}] = Notes.list_notes(vault.uuid)
    end
  end
end
