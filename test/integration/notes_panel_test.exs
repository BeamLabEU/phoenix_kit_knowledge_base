defmodule PhoenixKitKnowledgeBase.Integration.NotesPanelTest do
  @moduledoc """
  The drop-in notes panel in a host page that knows nothing about it.

  Leaf's messages are delivered the way `notify: {NotesPanel, id}` delivers
  them — `send_update(NotesPanel, id: …, leaf: message)` — so these tests do not
  depend on which Leaf the lock resolves.
  """
  use PhoenixKitKnowledgeBase.DataCase

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias PhoenixKitKnowledgeBase.{Notes, Places, Storage}
  alias PhoenixKitKnowledgeBase.Schemas.Vault
  alias PhoenixKitKnowledgeBase.Test.HostLive
  alias PhoenixKitKnowledgeBase.Web.NotesPanel

  @endpoint PhoenixKitKnowledgeBase.Test.Endpoint
  @path ["CRM", "Clients", "Acme"]

  setup do
    on_exit(fn -> Application.delete_env(:phoenix_kit_knowledge_base, :authorize) end)
    %{conn: build_conn(), me: user_fixture(), other: user_fixture()}
  end

  defp mount_panel(conn, user, opts \\ []) do
    opts = Keyword.merge([path: @path, poll: 0], opts)
    live_isolated(conn, HostLive, session: %{"user_uuid" => user && user.uuid, "opts" => opts})
  end

  # An event as the browser could send it, to the panel (not the host page).
  defp fire(lv, event, params \\ %{}),
    do: lv |> with_target("#panel") |> render_click(event, params)

  defp submit(lv, form, params),
    do: lv |> form("#panel-#{form}", params) |> render_submit()

  # What Leaf does with `notify` set.
  defp leaf(lv, message) do
    Phoenix.LiveView.send_update(lv.pid, NotesPanel, id: "panel", leaf: message)
    render(lv)
  end

  defp place!(path, visibility) do
    {:ok, place} = Places.parse(path, visibility)
    place
  end

  defp note!(user, title, path \\ @path, visibility \\ :shared, content \\ "") do
    place = place!(path, visibility)
    {:ok, vault} = Places.ensure(place, user)

    {:ok, note} =
      Notes.create_note(
        vault,
        %{title: title, folder_path: place.folder, content: content},
        user.uuid
      )

    {vault, note}
  end

  defp file(vault, note),
    do: File.read!(Path.join(Storage.vault_path(vault.directory), note.relative_path))

  defp vaults, do: Repo.all(from(v in Vault, where: not is_nil(v.path_key)))

  defmodule Hooks do
    def view_only(action, _user, _path), do: action == :view
    def nobody(_action, _user, _path), do: false
  end

  describe "rendering" do
    test "nothing for nobody signed in", %{conn: conn} do
      {:ok, _lv, html} = mount_panel(conn, nil)
      refute html =~ "No notes here"
    end

    test "a path that cannot be used is reported, not raised", %{conn: conn, me: me} do
      {:ok, _lv, html} = mount_panel(conn, me, path: ["CRM", "../etc"])
      assert html =~ "path"
      assert html =~ "not usable"
    end

    test "an empty place offers to start, and creates nothing by being looked at", %{
      conn: conn,
      me: me
    } do
      {:ok, _lv, html} = mount_panel(conn, me)
      assert html =~ "No notes here yet."
      assert html =~ "Everyone here"
      assert html =~ "Only me"
      assert vaults() == []
    end

    test "the label defaults to the last path segment", %{conn: conn, me: me} do
      {:ok, _lv, html} = mount_panel(conn, me)
      assert html =~ "Acme"
      {:ok, _lv, html} = mount_panel(conn, me, label: "Client notes")
      assert html =~ "Client notes"
    end

    test "one visibility hides the switch", %{conn: conn, me: me} do
      {:ok, _lv, html} = mount_panel(conn, me, visibility_options: [:private])
      refute html =~ "Everyone here"
    end
  end

  describe "creating" do
    test "the first note creates the vault, the folder chain and the file", %{conn: conn, me: me} do
      {:ok, lv, _} = mount_panel(conn, me)
      fire(lv, "start", %{"what" => "note"})
      html = submit(lv, "create", %{"title" => "First call"})

      [vault] = vaults()
      assert vault.name == "CRM"
      [note] = Notes.list_notes(vault.uuid)
      assert note.folder_path == "Clients/Acme"

      assert File.exists?(
               Path.join(Storage.vault_path(vault.directory), "Clients/Acme/First call.md")
             )

      # Opened straight away, in an editor keyed to this panel and this note.
      assert html =~ "First call"
      assert html =~ NotesPanel.editor_id("panel", note)
    end

    test "a folder, then a note inside it", %{conn: conn, me: me} do
      {:ok, lv, _} = mount_panel(conn, me)
      fire(lv, "start", %{"what" => "folder"})
      html = submit(lv, "create", %{"name" => "Calls"})
      assert html =~ "Calls"

      html = fire(lv, "open_folder", %{"path" => "Clients/Acme/Calls"})
      assert html =~ "Acme"

      fire(lv, "start", %{"what" => "note"})
      submit(lv, "create", %{"title" => "Kickoff"})

      [vault] = vaults()
      assert [%{folder_path: "Clients/Acme/Calls"}] = Notes.list_notes(vault.uuid)
    end

    test "a name that cannot be a file is explained", %{conn: conn, me: me} do
      {:ok, lv, _} = mount_panel(conn, me)
      fire(lv, "start", %{"what" => "note"})
      html = submit(lv, "create", %{"title" => "a/b"})
      assert html =~ "cannot contain"
    end

    test "a second note with the same title is refused", %{conn: conn, me: me} do
      note!(me, "Same")
      {:ok, lv, _} = mount_panel(conn, me)
      fire(lv, "start", %{"what" => "note"})
      assert submit(lv, "create", %{"title" => "Same"}) =~ "already here"
    end
  end

  describe "the fence around the panel's folder" do
    test "a note elsewhere in the same vault is not listed and cannot be opened", %{
      conn: conn,
      me: me
    } do
      {_vault, outside} = note!(me, "Globex secret", ["CRM", "Clients", "Globex"])
      note!(me, "Acme note")

      {:ok, lv, html} = mount_panel(conn, me)
      assert html =~ "Acme note"
      refute html =~ "Globex secret"

      html = fire(lv, "open_note", %{"uuid" => outside.uuid})
      refute html =~ "Globex secret"
    end

    test "a folder outside, or a path that climbs out, is not opened", %{conn: conn, me: me} do
      note!(me, "Globex secret", ["CRM", "Clients", "Globex"])
      {:ok, lv, _} = mount_panel(conn, me)

      for path <- ["Clients/Globex", "Clients", "", "Clients/Acme/../Globex"] do
        refute fire(lv, "open_folder", %{"path" => path}) =~ "Globex secret"
      end
    end

    test "links and suggestions only know notes inside it", %{conn: conn, me: me} do
      note!(me, "Globex secret", ["CRM", "Clients", "Globex"])
      {_vault, inside} = note!(me, "Acme plan")
      {_vault, open} = note!(me, "Acme call")

      {:ok, lv, _} = mount_panel(conn, me)
      fire(lv, "open_note", %{"uuid" => open.uuid})
      id = NotesPanel.editor_id("panel", open)

      leaf(lv, {:leaf_suggest, %{editor_id: id, trigger: "[[", query: "", seq: 1}})
      assert_push_event(lv, "leaf-suggestions:" <> ^id, %{seq: 1, results: results})
      labels = Enum.map(results, & &1.label)
      assert inside.title in labels
      refute "Globex secret" in labels
      refute "Acme call" in labels

      leaf(
        lv,
        {:leaf_resolve_links, %{editor_id: id, targets: ["Acme plan", "Globex secret"], seq: 2}}
      )

      assert_push_event(lv, "leaf-link-targets:" <> ^id, %{seq: 2, targets: targets})
      assert targets["Acme plan"].exists
      refute targets["Globex secret"].exists
      # No admin URL is handed out.
      assert targets["Acme plan"].href == nil
    end

    test "a followed link opens the note here; a missing one offers to create it", %{
      conn: conn,
      me: me
    } do
      {_vault, plan} = note!(me, "Acme plan", @path, :shared, "the plan")
      {_vault, open} = note!(me, "Acme call")

      {:ok, lv, _} = mount_panel(conn, me)
      fire(lv, "open_note", %{"uuid" => open.uuid})

      html = leaf(lv, {:leaf_link_clicked, %{editor_id: "x", target: "Acme plan"}})
      assert html =~ NotesPanel.editor_id("panel", plan)

      html = leaf(lv, {:leaf_link_clicked, %{editor_id: "x", target: "Not yet written"}})
      assert html =~ ~s(value="Not yet written")
      assert html =~ "Create note"
    end
  end

  describe "access" do
    test "view only: the notes are shown, nothing can be made or saved", %{
      conn: conn,
      me: me,
      other: other
    } do
      {vault, note} = note!(me, "Shared note", @path, :shared, "original")

      Application.put_env(:phoenix_kit_knowledge_base, :authorize, {Hooks, :view_only})
      {:ok, lv, html} = mount_panel(conn, other)
      assert html =~ "Shared note"
      refute html =~ "hero-document-plus"

      # The buttons are gone, and the events behind them are refused anyway.
      assert fire(lv, "start", %{"what" => "note"}) =~ "You cannot do that here."
      fire(lv, "create_note", %{"title" => "Sneaky"})
      assert length(Notes.list_notes(vault.uuid)) == 1

      fire(lv, "open_note", %{"uuid" => note.uuid})
      id = NotesPanel.editor_id("panel", note)
      leaf(lv, {:leaf_changed, %{editor_id: id, markdown: "vandalised", html: "", dirty: true}})
      assert file(vault, note) == "original"
    end

    test "no access: nothing is shown", %{conn: conn, me: me, other: other} do
      note!(me, "Shared note")
      Application.put_env(:phoenix_kit_knowledge_base, :authorize, {Hooks, :nobody})
      {:ok, _lv, html} = mount_panel(conn, other)
      assert html =~ "You do not have access"
      refute html =~ "Shared note"
    end

    test "private notes are each person's own", %{conn: conn, me: me, other: other} do
      note!(me, "My private thought", @path, :private)

      {:ok, lv, html} = mount_panel(conn, me, default_visibility: :private)
      assert html =~ "My private thought"

      {:ok, _lv, html} = mount_panel(conn, other, default_visibility: :private)
      refute html =~ "My private thought"

      # Switching to the shared notes does not show it either.
      refute fire(lv, "visibility", %{"to" => "shared"}) =~ "My private thought"
    end

    test "a forged visibility is ignored", %{conn: conn, me: me} do
      {:ok, lv, _} = mount_panel(conn, me, visibility_options: [:shared])
      fire(lv, "visibility", %{"to" => "private"})
      fire(lv, "start", %{"what" => "note"})
      submit(lv, "create", %{"title" => "Where am I"})
      assert [%{scope: "system"}] = vaults()
    end

    test "a plain user is not shown the admin link", %{conn: conn, me: me} do
      note!(me, "Anything")
      {:ok, _lv, html} = mount_panel(conn, me)
      refute html =~ "Open the whole vault"
    end
  end

  describe "writing" do
    setup %{me: me} do
      {vault, note} = note!(me, "Call notes", @path, :shared, "before")
      %{vault: vault, note: note}
    end

    test "an edit is written to the file", %{conn: conn, me: me, vault: vault, note: note} do
      {:ok, lv, _} = mount_panel(conn, me)
      fire(lv, "open_note", %{"uuid" => note.uuid})
      id = NotesPanel.editor_id("panel", note)

      html = leaf(lv, {:leaf_changed, %{editor_id: id, markdown: "after", html: "", dirty: true}})
      assert file(vault, note) == "after"
      assert html =~ "Saved"
    end

    test "a late edit from another note's editor is dropped", %{
      conn: conn,
      me: me,
      vault: vault,
      note: note
    } do
      {_vault, other} = note!(me, "Other note", @path, :shared, "other")
      {:ok, lv, _} = mount_panel(conn, me)
      fire(lv, "open_note", %{"uuid" => note.uuid})

      leaf(
        lv,
        {:leaf_changed,
         %{editor_id: NotesPanel.editor_id("panel", other), markdown: "wrong", dirty: true}}
      )

      assert file(vault, note) == "before"
      assert file(vault, other) == "other"
    end

    test "opening a note does not rewrite it", %{conn: conn, me: me, vault: vault, note: note} do
      {:ok, lv, _} = mount_panel(conn, me)
      fire(lv, "open_note", %{"uuid" => note.uuid})
      mtime = File.stat!(Path.join(Storage.vault_path(vault.directory), note.relative_path)).mtime

      leaf(
        lv,
        {:leaf_changed,
         %{editor_id: NotesPanel.editor_id("panel", note), markdown: "before", dirty: false}}
      )

      assert File.stat!(Path.join(Storage.vault_path(vault.directory), note.relative_path)).mtime ==
               mtime
    end

    test "a file changed elsewhere is not overwritten until the writer chooses to",
         %{conn: conn, me: me, vault: vault, note: note} do
      {:ok, lv, _} = mount_panel(conn, me)
      fire(lv, "open_note", %{"uuid" => note.uuid})
      id = NotesPanel.editor_id("panel", note)

      # Someone else's save, straight to disk.
      {:ok, _} = Storage.write_note(vault.directory, note.relative_path, "theirs")

      html = leaf(lv, {:leaf_changed, %{editor_id: id, markdown: "mine", html: "", dirty: true}})
      assert html =~ "changed somewhere else"
      assert file(vault, note) == "theirs"

      fire(lv, "overwrite_note")
      assert file(vault, note) == "mine"
    end

    test "rename and trash", %{conn: conn, me: me, vault: vault, note: note} do
      {:ok, lv, _} = mount_panel(conn, me)
      fire(lv, "open_note", %{"uuid" => note.uuid})
      fire(lv, "start_rename")
      assert submit(lv, "rename", %{"title" => "Renamed call"}) =~ "Renamed call"
      assert [%{title: "Renamed call"}] = Notes.list_notes(vault.uuid)

      html = fire(lv, "trash_note")
      assert html =~ "trash"
      assert Notes.list_notes(vault.uuid) == []
    end

    test "without a Leaf that supports notify, the note is shown and no editor is mounted",
         %{conn: conn, me: me, note: note} do
      Application.put_env(:phoenix_kit_knowledge_base, :leaf_notify, false)
      {:ok, lv, _} = mount_panel(conn, me)
      html = fire(lv, "open_note", %{"uuid" => note.uuid})
      assert html =~ "needs Leaf 0.11"
      assert html =~ "before"
      refute html =~ NotesPanel.editor_id("panel", note)
    end

    test "the host page never receives a message meant for the panel", %{
      conn: conn,
      me: me,
      note: note
    } do
      # HostLive has no handle_info/2 at all: anything sent to it would crash it.
      {:ok, lv, _} = mount_panel(conn, me)
      fire(lv, "open_note", %{"uuid" => note.uuid})
      leaf(lv, {:leaf_mode_changed, %{editor_id: "x", mode: :markdown}})
      leaf(lv, {:leaf_focus, %{editor_id: "x"}})
      assert Process.alive?(lv.pid)
    end
  end
end
