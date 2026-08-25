defmodule PhoenixKitKnowledgeBase.StorageTest do
  @moduledoc """
  Path containment, filename sanitisation and the real file operations.

  The traversal cases are the reason this file exists: everything here is built
  from user-supplied text, and a miss is a server compromise rather than a bad
  page.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitKnowledgeBase.Storage

  setup do
    root = Path.join(System.tmp_dir!(), "kb_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous = Application.get_env(:phoenix_kit_knowledge_base, :root)
    Application.put_env(:phoenix_kit_knowledge_base, :root, root)

    on_exit(fn ->
      File.rm_rf(root)

      if previous,
        do: Application.put_env(:phoenix_kit_knowledge_base, :root, previous),
        else: Application.delete_env(:phoenix_kit_knowledge_base, :root)
    end)

    directory = "system/test-vault"
    :ok = Storage.ensure_vault(directory)
    %{root: root, directory: directory}
  end

  describe "safe_relative/1 rejects traversal" do
    test "parent references at any depth" do
      for attempt <- ["..", "../etc/passwd", "a/../../etc", "a/b/../../../x", "./../x"] do
        assert :error = Storage.safe_relative(attempt), "accepted #{inspect(attempt)}"
      end
    end

    test "absolute paths" do
      assert :error = Storage.safe_relative("/etc/passwd")
      assert :error = Storage.safe_relative("/")
    end

    test "NUL bytes, which truncate the path at the C boundary" do
      assert :error = Storage.safe_relative("notes\0/../../etc/passwd")
    end

    test "nil and non-binaries" do
      assert :error = Storage.safe_relative(nil)
      assert :error = Storage.safe_relative(:atom)
    end

    test "ordinary relative paths survive, normalised" do
      assert {:ok, "a/b.md"} = Storage.safe_relative("a/b.md")
      assert {:ok, "a/b.md"} = Storage.safe_relative("./a/./b.md")
      assert {:ok, ""} = Storage.safe_relative("")
      assert {:ok, ""} = Storage.safe_relative(".")
    end

    test "a name that merely starts with .. is not traversal" do
      # `..hidden` is a legal filename; only the exact `..` segment escapes.
      assert {:ok, "..hidden.md"} = Storage.safe_relative("..hidden.md")
    end
  end

  describe "resolve/2 confinement" do
    test "keeps results under the base", %{root: root} do
      assert {:ok, path} = Storage.resolve(root, "system/vault/note.md")
      assert String.starts_with?(path, root <> "/")
    end

    test "refuses to escape even via a path the string check might miss", %{root: root} do
      assert {:error, :unsafe_path} = Storage.resolve(root, "../outside.md")
      assert {:error, :unsafe_path} = Storage.resolve(root, "/etc/passwd")
    end

    test "a sibling directory sharing the root's prefix is not inside it" do
      # `/tmp/kb` must not be treated as containing `/tmp/kb-evil`.
      assert {:error, :unsafe_path} = Storage.resolve("/tmp/kb", "../kb-evil/x.md")
    end
  end

  describe "validate_filename/1" do
    test "accepts an ordinary title, trimmed" do
      assert {:ok, "My Note"} = Storage.validate_filename("  My Note  ")
    end

    test "keeps spaces, punctuation and unicode, as Obsidian does" do
      assert {:ok, "Réunion, 2026 — notes!"} = Storage.validate_filename("Réunion, 2026 — notes!")
      assert {:ok, "日本語のノート"} = Storage.validate_filename("日本語のノート")
    end

    test "rejects filesystem-hostile characters instead of silently stripping them" do
      # The old behaviour turned `Ideas: Part 2` into `Ideas Part 2` with no
      # explanation, leaving a note whose title was not what anyone typed.
      assert {:error, {:forbidden_characters, [":"]}} = Storage.validate_filename("Ideas: Part 2")
      assert {:error, {:forbidden_characters, _}} = Storage.validate_filename("a/b")
      assert {:error, {:forbidden_characters, _}} = Storage.validate_filename("what?")
    end

    test "rejects characters that would break link syntax" do
      # A note called `Ideas [draft]` cannot be written as `[[Ideas [draft]]]`,
      # which makes it unlinkable in a vault whose point is linking.
      assert {:error, {:forbidden_characters, _}} = Storage.validate_filename("Ideas [draft]")
      assert {:error, {:forbidden_characters, ["#"]}} = Storage.validate_filename("C# notes")
      assert {:error, {:forbidden_characters, ["^"]}} = Storage.validate_filename("a^b")
      assert {:error, {:forbidden_characters, ["|"]}} = Storage.validate_filename("a|b")
    end

    test "reports every offending character, not just the first" do
      assert {:error, {:forbidden_characters, found}} = Storage.validate_filename("a:b?c")
      assert Enum.sort(found) == [":", "?"]
    end

    test "rejects a leading dot, which would hide the file from the walk" do
      assert {:error, :leading_dot} = Storage.validate_filename(".secret")
    end

    test "rejects a trailing dot" do
      assert {:error, :trailing_dot} = Storage.validate_filename("Note.")
    end

    test "rejects blank input" do
      assert {:error, :blank} = Storage.validate_filename("   ")
      assert {:error, :blank} = Storage.validate_filename(nil)
    end

    test "rejects a name too long for a filename" do
      assert {:error, :too_long} = Storage.validate_filename(String.duplicate("a", 300))
    end

    test "rejects Windows device names, which cannot exist as files there" do
      # The vault may well be synced to Windows by Obsidian.
      assert {:error, :reserved} = Storage.validate_filename("CON")
      assert {:error, :reserved} = Storage.validate_filename("com1")
      assert {:ok, _} = Storage.validate_filename("Console")
    end
  end

  describe "directory layout" do
    test "system vaults sit under system/" do
      assert Storage.build_directory(:system, "research", nil) == "system/research"
    end

    test "personal vaults sit under users/<email-slug>/" do
      assert Storage.build_directory(:user, "my-notes", "fotkin@gmail.com") ==
               "users/fotkin-gmail-com/my-notes"
    end

    test "an unusable email still produces a well-formed path" do
      assert Storage.build_directory(:user, "notes", nil) == "users/user/notes"
      assert Storage.build_directory(:user, "notes", "@@@") == "users/user/notes"
    end
  end

  describe "note paths" do
    test "title and folder become a path" do
      assert {:ok, "research/My Note.md"} = Storage.note_relative_path("My Note", "research")
      assert {:ok, "My Note.md"} = Storage.note_relative_path("My Note", nil)
    end

    test "a traversing folder is refused" do
      assert {:error, _} = Storage.note_relative_path("Note", "../../etc")
    end

    test "an invalid title is refused with the reason, not silently repaired" do
      assert {:error, {:forbidden_characters, _}} = Storage.note_relative_path("a/b", nil)
    end

    test "path round-trips back to title and folder" do
      assert Storage.title_from_path("research/My Note.md") == "My Note"
      assert Storage.folder_from_path("research/My Note.md") == "research"
      assert Storage.folder_from_path("My Note.md") == ""
    end
  end

  describe "read and write" do
    test "writes atomically and stats what landed", %{directory: dir} do
      assert {:ok, stat} = Storage.write_note(dir, "Alpha.md", "# Alpha\n")
      assert stat.hash == Storage.hash("# Alpha\n")
      assert stat.size == byte_size("# Alpha\n")
      assert {:ok, "# Alpha\n"} = Storage.read_note(dir, "Alpha.md")
    end

    test "leaves no temp files behind", %{root: root, directory: dir} do
      {:ok, _} = Storage.write_note(dir, "Alpha.md", "content")
      files = File.ls!(Path.join(root, dir))
      assert files == ["Alpha.md"]
    end

    test "creates intermediate folders", %{directory: dir} do
      assert {:ok, _} = Storage.write_note(dir, "a/b/Deep.md", "x")
      assert {:ok, "x"} = Storage.read_note(dir, "a/b/Deep.md")
    end

    test "refuses to write outside the vault", %{directory: dir} do
      assert {:error, :unsafe_path} = Storage.write_note(dir, "../../escape.md", "x")
    end

    test "trashing a missing note is success with nothing to recover", %{directory: dir} do
      assert {:ok, nil} = Storage.trash_note(dir, "NeverExisted.md")
    end
  end

  describe "move_note/3" do
    test "renames within the vault", %{directory: dir} do
      {:ok, _} = Storage.write_note(dir, "Old.md", "body")
      assert :ok = Storage.move_note(dir, "Old.md", "sub/New.md")
      assert {:ok, "body"} = Storage.read_note(dir, "sub/New.md")
      refute Storage.note_exists?(dir, "Old.md")
    end

    test "refuses to overwrite an existing note", %{directory: dir} do
      # Silently destroying the target would lose a note during an ordinary
      # rename.
      {:ok, _} = Storage.write_note(dir, "A.md", "a")
      {:ok, _} = Storage.write_note(dir, "B.md", "b")
      assert {:error, :target_exists} = Storage.move_note(dir, "A.md", "B.md")
      assert {:ok, "b"} = Storage.read_note(dir, "B.md")
    end
  end

  describe "list_notes/1" do
    test "finds markdown recursively with change-detection metadata", %{directory: dir} do
      {:ok, _} = Storage.write_note(dir, "Root.md", "r")
      {:ok, _} = Storage.write_note(dir, "sub/Nested.md", "n")

      {:ok, entries} = Storage.list_notes(dir)
      paths = entries |> Enum.map(& &1.relative_path) |> Enum.sort()

      assert paths == ["Root.md", "sub/Nested.md"]
      assert Enum.all?(entries, &(&1.size > 0 and match?(%DateTime{}, &1.mtime)))
    end

    test "ignores non-markdown and dot-directories", %{root: root, directory: dir} do
      {:ok, _} = Storage.write_note(dir, "Keep.md", "k")
      File.write!(Path.join([root, dir, "image.png"]), "binary")
      File.mkdir_p!(Path.join([root, dir, ".obsidian"]))
      File.write!(Path.join([root, dir, ".obsidian", "config.md"]), "config")

      {:ok, entries} = Storage.list_notes(dir)
      assert Enum.map(entries, & &1.relative_path) == ["Keep.md"]
    end

    test "skips symlinks rather than following them", %{root: root, directory: dir} do
      # A planted link would otherwise pull an arbitrary file into the index,
      # and its content into search results.
      secret = Path.join(root, "secret.md")
      File.write!(secret, "classified")
      File.ln_s!(secret, Path.join([root, dir, "Innocent.md"]))

      {:ok, entries} = Storage.list_notes(dir)
      assert entries == []
    end

    test "a vault whose directory vanished reads as empty, not an error" do
      assert {:ok, []} = Storage.list_notes("system/never-created")
    end
  end

  describe "list_folders/1" do
    test "returns nested directories relative to the vault", %{directory: dir} do
      :ok = Storage.create_folder(dir, "a/b")
      {:ok, folders} = Storage.list_folders(dir)
      assert Enum.sort(folders) == ["a", "a/b"]
    end
  end

  describe "delete_folder/2" do
    test "removes the folder and its contents", %{directory: dir} do
      {:ok, _} = Storage.write_note(dir, "sub/Note.md", "x")
      assert :ok = Storage.delete_folder(dir, "sub")
      assert {:ok, []} = Storage.list_notes(dir)
    end

    test "refuses to delete the vault root", %{directory: dir} do
      # `""` and `.` both resolve to the vault directory; an rm_rf there would
      # take the whole vault with it.
      {:ok, _} = Storage.write_note(dir, "Note.md", "x")
      assert {:error, :refuse_vault_root} = Storage.delete_folder(dir, "")
      assert {:error, :refuse_vault_root} = Storage.delete_folder(dir, ".")
      assert Storage.note_exists?(dir, "Note.md")
    end
  end

  describe "trash" do
    test "deleting moves the file rather than unlinking it", %{directory: dir} do
      {:ok, _} = Storage.write_note(dir, "research/Doomed.md", "still here")

      assert {:ok, trash_path} = Storage.trash_note(dir, "research/Doomed.md")
      refute Storage.note_exists?(dir, "research/Doomed.md")
      # The bytes survive — that is the entire point.
      assert {:ok, "still here"} = Storage.read_note(dir, trash_path)
    end

    test "trashed notes are invisible to the walk, so they leave the index", %{directory: dir} do
      {:ok, _} = Storage.write_note(dir, "Doomed.md", "x")
      {:ok, _} = Storage.trash_note(dir, "Doomed.md")

      assert {:ok, []} = Storage.list_notes(dir)
    end

    test "the listing reports where it came from and when", %{directory: dir} do
      {:ok, _} = Storage.write_note(dir, "research/Doomed.md", "x")
      {:ok, _} = Storage.trash_note(dir, "research/Doomed.md")

      assert {:ok, [entry]} = Storage.list_trash(dir)
      assert entry.original_path == "research/Doomed.md"
      assert entry.title == "Doomed"
      assert %DateTime{} = entry.deleted_at
    end

    test "restore puts it back exactly where it was", %{directory: dir} do
      {:ok, _} = Storage.write_note(dir, "research/Doomed.md", "recovered")
      {:ok, _} = Storage.trash_note(dir, "research/Doomed.md")
      {:ok, [entry]} = Storage.list_trash(dir)

      assert :ok = Storage.restore(dir, entry.trash_path, entry.original_path)
      assert {:ok, "recovered"} = Storage.read_note(dir, "research/Doomed.md")
      assert {:ok, []} = Storage.list_trash(dir)
    end

    test "restore refuses to overwrite a note written since", %{directory: dir} do
      {:ok, _} = Storage.write_note(dir, "Note.md", "original")
      {:ok, _} = Storage.trash_note(dir, "Note.md")
      {:ok, _} = Storage.write_note(dir, "Note.md", "the replacement")
      {:ok, [entry]} = Storage.list_trash(dir)

      assert {:error, :target_exists} =
               Storage.restore(dir, entry.trash_path, entry.original_path)

      assert {:ok, "the replacement"} = Storage.read_note(dir, "Note.md")
    end

    test "deleting the same path twice keeps both copies", %{directory: dir} do
      # Per-deletion timestamp directories, so the second delete does not
      # overwrite the first one's recoverable copy.
      {:ok, _} = Storage.write_note(dir, "Note.md", "first")
      {:ok, first} = Storage.trash_note(dir, "Note.md")
      {:ok, _} = Storage.write_note(dir, "Note.md", "second")
      {:ok, second} = Storage.trash_note(dir, "Note.md")

      refute first == second
      assert {:ok, "first"} = Storage.read_note(dir, first)
      assert {:ok, "second"} = Storage.read_note(dir, second)
    end

    test "a trashed folder keeps its subtree", %{directory: dir} do
      {:ok, _} = Storage.write_note(dir, "research/papers/Deep.md", "nested")

      assert {:ok, trash_path} = Storage.trash_folder(dir, "research")
      assert {:ok, "nested"} = Storage.read_note(dir, Path.join(trash_path, "papers/Deep.md"))
    end

    test "trashing the vault root is refused", %{directory: dir} do
      {:ok, _} = Storage.write_note(dir, "Note.md", "x")

      assert {:error, :refuse_vault_root} = Storage.trash_folder(dir, "")
      assert Storage.note_exists?(dir, "Note.md")
    end

    test "purge only works inside the trash", %{directory: dir} do
      # A purge aimed at a live note is a delete wearing the wrong name.
      {:ok, _} = Storage.write_note(dir, "Live.md", "x")

      assert {:error, :not_in_trash} = Storage.purge(dir, "Live.md")
      assert Storage.note_exists?(dir, "Live.md")
    end

    test "purge removes one item for good", %{directory: dir} do
      {:ok, _} = Storage.write_note(dir, "Note.md", "x")
      {:ok, _} = Storage.trash_note(dir, "Note.md")
      {:ok, [entry]} = Storage.list_trash(dir)

      assert :ok = Storage.purge(dir, entry.trash_path)
      assert {:ok, []} = Storage.list_trash(dir)
    end

    test "empty_trash clears everything", %{directory: dir} do
      {:ok, _} = Storage.write_note(dir, "A.md", "a")
      {:ok, _} = Storage.write_note(dir, "B.md", "b")
      {:ok, _} = Storage.trash_note(dir, "A.md")
      {:ok, _} = Storage.trash_note(dir, "B.md")

      assert :ok = Storage.empty_trash(dir)
      assert {:ok, []} = Storage.list_trash(dir)
    end
  end
end
