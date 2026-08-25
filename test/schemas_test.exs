defmodule PhoenixKitKnowledgeBase.SchemasTest do
  @moduledoc """
  Changeset behaviour — no database needed. These cover the rules that keep the
  derived fields (`title_key`, `tags`, `frontmatter`, `slug`) honest, plus the
  two invariants the access model depends on.
  """
  use ExUnit.Case, async: true

  alias Ecto.Changeset
  alias PhoenixKitKnowledgeBase.Schemas.{Folder, Note, Vault, VaultMember}

  @owner "0198f0a0-0000-7000-8000-000000000001"
  @vault "0198f0a0-0000-7000-8000-000000000002"

  describe "Vault.slugify/1" do
    test "produces a URL-safe slug" do
      assert Vault.slugify("Research Notes") == "research-notes"
      assert Vault.slugify("Café & Ideas!") == "cafe-ideas"
      assert Vault.slugify("  spaced   out  ") == "spaced-out"
    end

    test "returns nil when nothing slug-able survives" do
      assert Vault.slugify("日本語") == nil
      assert Vault.slugify("!!!") == nil
    end
  end

  describe "Vault.changeset/2" do
    test "derives a slug from the name" do
      changeset =
        Vault.changeset(%Vault{}, %{
          "name" => "My Research",
          "scope" => "user",
          "owner_uuid" => @owner
        })

      assert changeset.valid?
      assert Changeset.get_field(changeset, :slug) == "my-research"
    end

    test "falls back to a generated slug for a name that slugifies to nothing" do
      # Rejecting the vault would be worse: the slug is a URL token, the name
      # is what people read.
      changeset =
        Vault.changeset(%Vault{}, %{"name" => "日本語", "scope" => "user", "owner_uuid" => @owner})

      assert changeset.valid?
      assert Changeset.get_field(changeset, :slug) =~ ~r/^vault-[a-z0-9]+$/
    end

    test "a system vault must not have an owner" do
      changeset =
        Vault.changeset(%Vault{}, %{"name" => "Org", "scope" => "system", "owner_uuid" => @owner})

      refute changeset.valid?
      assert %{owner_uuid: ["must be blank for a system vault"]} = errors(changeset)
    end

    test "a personal vault must have an owner" do
      # Both directions matter: either shape would make every access check
      # ambiguous, which is why it is rejected at the edge.
      changeset = Vault.changeset(%Vault{}, %{"name" => "Mine", "scope" => "user"})

      refute changeset.valid?
      assert %{owner_uuid: ["is required for a personal vault"]} = errors(changeset)
    end

    test "rejects an unknown scope" do
      changeset =
        Vault.changeset(%Vault{}, %{"name" => "X", "scope" => "team", "owner_uuid" => @owner})

      refute changeset.valid?
    end
  end

  describe "Note.changeset/2 derived fields" do
    test "title, title_key and folder_path all come from the path" do
      # The filename *is* the title, so nothing here is separately settable —
      # a row that disagreed with its file would be a lie about the disk.
      changeset =
        Note.changeset(%Note{}, %{
          "vault_uuid" => @vault,
          "relative_path" => "research/My   Note.md"
        })

      assert changeset.valid?
      assert Changeset.get_field(changeset, :title) == "My   Note"
      assert Changeset.get_field(changeset, :title_key) == "my note"
      assert Changeset.get_field(changeset, :folder_path) == "research"
    end

    test "a note at the vault root has an empty folder_path" do
      changeset = Note.changeset(%Note{}, %{"vault_uuid" => @vault, "relative_path" => "Note.md"})

      assert Changeset.get_field(changeset, :folder_path) == ""
    end

    test "front matter and tags are parsed out of the content" do
      content = "---\ntags: [alpha]\nstatus: draft\n---\n\nBody with #beta\n"

      changeset =
        Note.changeset(%Note{}, %{
          "vault_uuid" => @vault,
          "relative_path" => "T.md",
          "content" => content
        })

      assert Changeset.get_field(changeset, :frontmatter) == %{
               "tags" => ["alpha"],
               "status" => "draft"
             }

      assert Changeset.get_field(changeset, :tags) == ["alpha", "beta"]
    end

    test "a move re-derives the path fields but leaves the parsed content alone" do
      # Re-parsing from a `content` that was never loaded would wipe the front
      # matter every time a note changed folder.
      note = %Note{
        vault_uuid: @vault,
        relative_path: "Old.md",
        content: "---\na: 1\n---\n",
        frontmatter: %{"a" => 1},
        tags: ["x"]
      }

      changeset = Note.changeset(note, %{"relative_path" => "sub/Old.md"})

      assert Changeset.get_field(changeset, :folder_path) == "sub"
      assert Changeset.get_field(changeset, :frontmatter) == %{"a" => 1}
      assert Changeset.get_field(changeset, :tags) == ["x"]
    end

    test "rejects a path that escapes the vault" do
      for bad <- ["../escape.md", "/etc/passwd.md", "a/../../b.md"] do
        changeset = Note.changeset(%Note{}, %{"vault_uuid" => @vault, "relative_path" => bad})
        refute changeset.valid?, "accepted #{inspect(bad)}"
      end
    end

    test "rejects anything that is not a markdown file" do
      changeset =
        Note.changeset(%Note{}, %{"vault_uuid" => @vault, "relative_path" => "image.png"})

      refute changeset.valid?
    end

    test "rejects a path with no filename before the extension" do
      changeset = Note.changeset(%Note{}, %{"vault_uuid" => @vault, "relative_path" => ".md"})
      refute changeset.valid?
    end
  end

  describe "Folder.changeset/2" do
    test "derives the display name from the path" do
      changeset =
        Folder.changeset(%Folder{}, %{"vault_uuid" => @vault, "relative_path" => "a/b/Research"})

      assert changeset.valid?
      assert Changeset.get_field(changeset, :name) == "Research"
    end

    test "rejects the vault root, which is not a folder row" do
      changeset = Folder.changeset(%Folder{}, %{"vault_uuid" => @vault, "relative_path" => ""})
      refute changeset.valid?
    end

    test "rejects a traversing path" do
      changeset =
        Folder.changeset(%Folder{}, %{"vault_uuid" => @vault, "relative_path" => "../outside"})

      refute changeset.valid?
    end
  end

  describe "VaultMember" do
    test "roles are ordered most capable first" do
      assert VaultMember.roles() == ["owner", "editor", "viewer"]
    end

    test "rejects an unknown role" do
      changeset =
        VaultMember.changeset(%VaultMember{}, %{
          "vault_uuid" => @vault,
          "user_uuid" => @owner,
          "role" => "admin"
        })

      refute changeset.valid?
    end
  end

  defp errors(changeset) do
    Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
