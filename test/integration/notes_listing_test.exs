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
