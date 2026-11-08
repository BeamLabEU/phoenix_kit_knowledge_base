defmodule PhoenixKitKnowledgeBase.Integration.VaultLiveTest do
  @moduledoc """
  The admin pages, mounted. Routed through `Test.Router` with the scope core's
  admin hook would assign; core's chrome (the header bar and its toolbar) is
  not there, so the toolbar is rendered as the component it is.

  The vault page's fixture has a folder with a note in it on purpose: a page
  that renders an empty tree has not rendered the tree (see AGENTS.md on
  `smoke_http.exs`).
  """
  use PhoenixKitKnowledgeBase.DataCase

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitKnowledgeBase.{Notes, Paths, Storage, Vaults}
  alias PhoenixKitKnowledgeBase.Web.VaultLive

  @endpoint PhoenixKitKnowledgeBase.Test.Endpoint

  setup do
    me = user_fixture()
    scope = Scope.for_user(me)
    {:ok, vault} = Vaults.create(%{"name" => "Research"}, scope, :user)
    {:ok, _} = Notes.create_folder(vault, "", "papers")

    {:ok, note} =
      Notes.create_note(
        vault,
        %{title: "Ideas", folder_path: "papers", content: "first draft"},
        me.uuid
      )

    conn = Plug.Test.init_test_session(build_conn(), %{"user_uuid" => me.uuid})
    %{conn: conn, me: me, vault: vault, note: note}
  end

  defp file(vault, relative_path),
    do: File.read!(Path.join(Storage.vault_path(vault.directory), relative_path))

  # What Leaf sends when the buffer changes.
  defp type(lv, note, markdown) do
    send(
      lv.pid,
      {:leaf_changed, %{editor_id: VaultLive.editor_id(note), markdown: markdown, dirty: true}}
    )

    render(lv)
  end

  describe "rendering" do
    test "the vault list", %{conn: conn} do
      {:ok, _lv, html} = live(conn, Paths.vaults())
      assert html =~ "Research"
      assert html =~ "My vaults"
      assert html =~ "1 note"
    end

    test "the vault, with its tree", %{conn: conn, vault: vault, me: me} do
      # At the root, where the collapsed tree still shows it.
      {:ok, _} = Notes.create_note(vault, %{title: "Inbox"}, me.uuid)
      {:ok, _lv, html} = live(conn, Paths.vault(vault.slug))
      assert html =~ "kb-folder-explorer"
      assert html =~ "data-draggable-file"
      assert html =~ "data-drop-folder"
      assert html =~ "Pick a note from the sidebar."
    end

    test "a note", %{conn: conn, vault: vault, note: note} do
      {:ok, _lv, html} = live(conn, Paths.note(vault.slug, note.uuid))
      assert html =~ VaultLive.editor_id(note)
      assert html =~ "papers/Ideas.md"
    end

    test "the members page", %{conn: conn, vault: vault} do
      {:ok, _lv, html} = live(conn, Paths.members(vault.slug))
      assert html =~ "Add someone"
      assert html =~ "kb-member-search-input"
    end

    test "in Russian", %{conn: conn, vault: vault, note: note} do
      conn = Plug.Test.init_test_session(conn, %{"locale" => "ru"})

      {:ok, _lv, html} = live(conn, Paths.note(vault.slug, note.uuid))
      assert html =~ "Обратные ссылки"
      assert html =~ "Наберите [["
      assert html =~ "Корень хранилища"
    end

    test "the header toolbar: the vault's actions, and Rescan only for a writer", %{vault: vault} do
      assigns = %{
        vault: vault,
        role: "owner",
        can_manage: true,
        can_write: true,
        trash_open: false
      }

      html = render_component(&VaultLive.header_toolbar/1, assigns)
      assert html =~ "Members"
      assert html =~ "Rescan"
      assert html =~ "data-drop-trash"

      html =
        render_component(&VaultLive.header_toolbar/1, %{
          assigns
          | can_write: false,
            can_manage: false
        })

      refute html =~ "Rescan"
      refute html =~ "Members"
    end

    test "front matter holding a list of maps renders, and does not take the page down", %{
      conn: conn,
      vault: vault,
      me: me
    } do
      content = "---\nauthors:\n  - name: Ada\n    year: 1843\ntags: [x]\n---\nbody"
      {:ok, note} = Notes.create_note(vault, %{title: "Props", content: content}, me.uuid)

      {:ok, _lv, html} = live(conn, Paths.note(vault.slug, note.uuid))
      assert html =~ "name: Ada; year: 1843"
    end
  end

  describe "someone else saving the note on screen" do
    test "raises the banner and keeps the guard: the next keystroke does not overwrite them", %{
      conn: conn,
      vault: vault,
      note: note
    } do
      {:ok, lv, _} = live(conn, Paths.note(vault.slug, note.uuid))

      # A peer's save — from this test process, so not the page's own.
      {:ok, _} = Notes.update_content(vault, note, "their version")
      assert render(lv) =~ "Someone else just saved this note"

      html = type(lv, note, "first draft, and mine")

      assert file(vault, note.relative_path) == "their version"
      assert html =~ "This note changed since you opened it"
    end

    test "a rename elsewhere is followed: the next keystroke saves under the new name", %{
      conn: conn,
      vault: vault,
      note: note
    } do
      {:ok, lv, _} = live(conn, Paths.note(vault.slug, note.uuid))

      {:ok, renamed} = Notes.rename_note(vault, note, "Better ideas")
      render(lv)

      html = type(lv, note, "first draft, edited")

      refute html =~ "This note changed since you opened it"
      assert file(vault, renamed.relative_path) == "first draft, edited"
    end

    test "a folder moved elsewhere is followed too", %{conn: conn, vault: vault, note: note} do
      {:ok, lv, _} = live(conn, Paths.note(vault.slug, note.uuid))

      folder = Notes.get_folder_by_path(vault.uuid, "papers")
      {:ok, _} = Notes.relocate_folder(vault, folder, "archive")
      render(lv)

      type(lv, note, "moved and edited")
      assert file(vault, "archive/Ideas.md") == "moved and edited"
    end
  end

  describe "moving and creating" do
    test "a hand-sent move to a folder that is not in the index is refused", %{
      conn: conn,
      vault: vault,
      note: note
    } do
      {:ok, lv, _} = live(conn, Paths.note(vault.slug, note.uuid))

      lv |> element("#kb-move-form") |> render_change(%{"folder" => "made:up#folder"})

      refute File.exists?(Path.join(Storage.vault_path(vault.directory), "made:up#folder"))
      assert Notes.get_note(vault.uuid, note.uuid).folder_path == "papers"
    end

    test "the select moves a note to an indexed folder", %{conn: conn, vault: vault, note: note} do
      {:ok, lv, _} = live(conn, Paths.note(vault.slug, note.uuid))

      lv |> element("#kb-move-form") |> render_change(%{"folder" => "root"})
      assert Notes.get_note(vault.uuid, note.uuid).relative_path == "Ideas.md"
    end

    test "an unresolved path-qualified link creates the note in that folder", %{
      conn: conn,
      vault: vault
    } do
      {:ok, lv, _} = live(conn, Paths.new_note(vault.slug, "drafts/Later"))

      lv |> form("#kb-new-note-form", %{"title" => "drafts/Later"}) |> render_submit()

      assert %{title: "Later", folder_path: "drafts"} =
               Notes.get_note_by_path(vault.uuid, "drafts/Later.md")
    end
  end

  describe "place_new_note/2" do
    test "a bare title stays in the selected folder" do
      assert VaultLive.place_new_note("Ideas", "papers") == {:ok, "papers", "Ideas"}
    end

    test "a path names its folder from the vault root, every segment checked" do
      assert VaultLive.place_new_note("a/b/Note", "papers") == {:ok, "a/b", "Note"}
      assert {:error, {:forbidden_characters, [":"]}} = VaultLive.place_new_note("a:b/Note", "")
      assert {:error, :blank} = VaultLive.place_new_note("a//Note", "")
    end
  end
end
