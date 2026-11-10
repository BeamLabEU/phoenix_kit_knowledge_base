defmodule PhoenixKitKnowledgeBase.Integration.NotesNamesTest do
  @moduledoc """
  What a host building on top of notes needs and used to write itself:
  numbered names on demand, rename-and-move in one step, a trash it can
  search by property, and notes found by a front-matter property.
  """
  use PhoenixKitKnowledgeBase.DataCase

  alias PhoenixKitKnowledgeBase.{Notes, Places, Vaults}

  setup do
    user = user_fixture()
    {:ok, place} = Places.parse(["Names"], :private)
    {:ok, vault} = Places.ensure(place, user)
    %{vault: vault, user: user}
  end

  defp create(vault, title, folder \\ "", content \\ "") do
    {:ok, note} = Notes.create_note(vault, %{title: title, folder_path: folder, content: content})
    note
  end

  defp on_disk?(vault, path), do: File.exists?(Path.join(Vaults.absolute_path(vault), path))

  describe "create_note/4 with unique: true" do
    test "numbers a taken name instead of refusing", %{vault: vault, user: user} do
      create(vault, "Ideas")

      assert {:error, :already_exists} = Notes.create_note(vault, %{title: "Ideas"})

      assert {:ok, %{title: "Ideas 2", relative_path: "Ideas 2.md"}} =
               Notes.create_note(vault, %{title: "Ideas"}, user.uuid, unique: true)

      assert {:ok, %{title: "Ideas 3"}} =
               Notes.create_note(vault, %{title: "Ideas"}, user.uuid, unique: true)
    end

    test "a free name is used as is; an invalid one is still refused", %{vault: vault} do
      assert {:ok, %{title: "Fresh"}} =
               Notes.create_note(vault, %{title: "Fresh"}, nil, unique: true)

      assert {:error, {:forbidden_characters, _}} =
               Notes.create_note(vault, %{title: "a/b"}, nil, unique: true)
    end
  end

  describe "rename_note/4 with unique: true" do
    test "numbers a taken name; renaming to its own name is a no-op", %{vault: vault} do
      create(vault, "Beta")
      alpha = create(vault, "Alpha")

      assert {:error, :target_exists} = Notes.rename_note(vault, alpha, "Beta")

      assert {:ok, %{title: "Beta 2"} = renamed} =
               Notes.rename_note(vault, alpha, "Beta", unique: true)

      assert {:ok, %{title: "Beta 2"}} = Notes.rename_note(vault, renamed, "Beta 2", unique: true)
    end
  end

  describe "move_note/4 with title: and unique:" do
    test "moves and renames in one step", %{vault: vault} do
      note = create(vault, "Draft", "inbox", "text")

      assert {:ok, moved} = Notes.move_note(vault, note, "work", title: "Report")

      assert moved.uuid == note.uuid
      assert moved.relative_path == "work/Report.md"
      assert moved.folder_path == "work"
      assert on_disk?(vault, "work/Report.md")
      refute on_disk?(vault, "inbox/Draft.md")
      refute on_disk?(vault, "inbox/Report.md")
    end

    test "numbers a name taken in the target folder", %{vault: vault} do
      create(vault, "Report", "work")
      note = create(vault, "Report", "inbox")

      assert {:error, :target_exists} = Notes.move_note(vault, note, "work")

      assert {:ok, %{relative_path: "work/Report 2.md"}} =
               Notes.move_note(vault, note, "work", unique: true)
    end

    test "a name taken only in the SOURCE folder doesn't count", %{vault: vault} do
      create(vault, "Report 2", "inbox")
      note = create(vault, "Report", "inbox")

      assert {:ok, %{relative_path: "work/Report 2.md"}} =
               Notes.move_note(vault, note, "work", title: "Report 2", unique: true)
    end
  end

  describe "the trash, by property" do
    test "list_trash/2 can carry each entry's front matter", %{vault: vault} do
      note = create(vault, "Task", "", "---\nid: abc-123\nstatus: open\n---\n# Task\n")
      {:ok, _} = Notes.delete_note(vault, note)

      assert [entry] = Notes.list_trash(vault, frontmatter: true)
      assert entry.frontmatter == %{"id" => "abc-123", "status" => "open"}
      refute Map.has_key?(hd(Notes.list_trash(vault)), :frontmatter)
    end

    test "restore_note/3 with unique: true comes back numbered beside a newer note", %{
      vault: vault
    } do
      old = create(vault, "Plan", "", "old")
      {:ok, _} = Notes.delete_note(vault, old)
      create(vault, "Plan", "", "new")

      [entry] = Notes.list_trash(vault)
      assert {:error, :target_exists} = Notes.restore_note(vault, entry)

      assert {:ok, %{title: "Plan 2", content: "old"}} =
               Notes.restore_note(vault, entry, unique: true)

      assert Notes.list_trash(vault) == []
    end
  end

  describe "notes by front-matter property" do
    test "list_notes/2 :property and :has_property, get_note_by_property/3", %{vault: vault} do
      a = create(vault, "A", "", "---\nid: one\n---\n")
      _b = create(vault, "B", "", "---\nid: two\nkind: task\n---\n")
      _c = create(vault, "C", "", "---\nlevel: 7\n---\n")
      _d = create(vault, "D", "", "no front matter")

      titles = fn opts -> vault.uuid |> Notes.list_notes(opts) |> Enum.map(& &1.title) end

      assert titles.(property: {"id", "one"}) == ["A"]
      assert titles.(property: {"level", 7}) == ["C"]
      assert titles.(property: {"id", "nope"}) == []
      assert titles.(has_property: "id") == ["A", "B"]
      assert titles.(has_property: ["kind", "level"]) == ["B", "C"]

      assert Notes.get_note_by_property(vault.uuid, "id", "one").uuid == a.uuid
      assert Notes.get_note_by_property(vault.uuid, "id", "zzz") == nil
    end

    test "never reaches into another vault", %{vault: vault, user: user} do
      {:ok, place} = Places.parse(["Elsewhere"], :private)
      {:ok, other} = Places.ensure(place, user)
      create(other, "Theirs", "", "---\nid: one\n---\n")

      assert Notes.get_note_by_property(vault.uuid, "id", "one") == nil
      assert Notes.list_notes(vault.uuid, has_property: "id") == []
    end
  end
end
