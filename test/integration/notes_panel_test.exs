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
    {locale, opts} = Keyword.pop(opts, :locale)
    opts = Keyword.merge([path: @path, poll: 0], opts)

    live_isolated(conn, HostLive,
      session: %{"user_uuid" => user && user.uuid, "opts" => opts, "locale" => locale}
    )
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

  # One beat of the poll, without waiting for it (the tests mount with `poll: 0`).
  defp tick(lv) do
    Phoenix.LiveView.send_update(lv.pid, NotesPanel, id: "panel", tick: true)
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
    test "one click makes \"Note 1\": the vault, the folder chain and the file", %{
      conn: conn,
      me: me
    } do
      {:ok, lv, _} = mount_panel(conn, me)
      html = fire(lv, "new_note")

      [vault] = vaults()
      assert vault.name == "CRM"
      [note] = Notes.list_notes(vault.uuid)
      assert note.title == "Note 1"
      assert note.folder_path == "Clients/Acme"

      assert File.exists?(
               Path.join(Storage.vault_path(vault.directory), "Clients/Acme/Note 1.md")
             )

      # Opened straight away, in an editor keyed to this panel and this note.
      assert html =~ NotesPanel.editor_id("panel", note)
    end

    test "the next note takes the next free number in the folder", %{conn: conn, me: me} do
      note!(me, "Note 1")
      note!(me, "Note 3")
      note!(me, "Note 7", ["CRM", "Clients", "Globex"])

      {:ok, lv, _} = mount_panel(conn, me)
      fire(lv, "new_note")
      fire(lv, "close_note")
      fire(lv, "new_note")

      [vault] = vaults()
      titles = vault.uuid |> Notes.list_notes(folder_path: "Clients/Acme") |> Enum.map(& &1.title)
      assert Enum.sort(titles) == ["Note 1", "Note 3", "Note 4", "Note 5"]
    end

    # `\d` under the `u` flag is any Unicode decimal digit, and
    # `String.to_integer/1` takes ASCII only: "Note ٣" (a valid file name) used
    # to raise inside the host's process on the next click.
    test "a number in another script is not a number here, and not a crash", %{
      conn: conn,
      me: me
    } do
      note!(me, "Note ٣")
      note!(me, "Note ３")

      {:ok, lv, _} = mount_panel(conn, me)
      fire(lv, "new_note")
      assert Process.alive?(lv.pid)

      [vault] = vaults()
      titles = vault.uuid |> Notes.list_notes() |> Enum.map(& &1.title) |> Enum.sort()
      assert titles == ["Note 1", "Note ٣", "Note ３"]
    end

    test "a new note can be given a real name straight away", %{conn: conn, me: me} do
      {:ok, lv, _} = mount_panel(conn, me)
      fire(lv, "new_note")
      fire(lv, "start_rename")
      assert submit(lv, "rename", %{"title" => "First call"}) =~ "First call"

      [vault] = vaults()

      assert File.exists?(
               Path.join(Storage.vault_path(vault.directory), "Clients/Acme/First call.md")
             )
    end

    test "a folder, then a note inside it", %{conn: conn, me: me} do
      {:ok, lv, _} = mount_panel(conn, me)
      fire(lv, "start", %{"what" => "folder"})
      html = submit(lv, "create", %{"name" => "Calls"})
      assert html =~ "Calls"

      html = fire(lv, "open_folder", %{"path" => "Clients/Acme/Calls"})
      assert html =~ "Acme"

      fire(lv, "new_note")

      [vault] = vaults()

      assert [%{folder_path: "Clients/Acme/Calls", title: "Note 1"}] =
               Notes.list_notes(vault.uuid)
    end

    test "a name that cannot be a file is explained", %{conn: conn, me: me} do
      {:ok, lv, _} = mount_panel(conn, me)
      fire(lv, "new_note")
      fire(lv, "start_rename")
      assert submit(lv, "rename", %{"title" => "a/b"}) =~ "cannot contain"
    end

    test "an event the panel does not know is ignored, not a crash of the page", %{
      conn: conn,
      me: me
    } do
      {:ok, lv, _} = mount_panel(conn, me)
      fire(lv, "start", %{"what" => "note"})
      fire(lv, "create_note", %{"title" => "x"})
      fire(lv, "no_such_event", %{})
      assert Process.alive?(lv.pid)
      assert vaults() == []
    end
  end

  describe "in the reader's language" do
    test "Russian: the panel, the default title, and the editor's own toolbar", %{
      conn: conn,
      me: me
    } do
      {:ok, lv, html} = mount_panel(conn, me, locale: "ru")
      assert html =~ "Только мои"
      assert html =~ "Здесь пока нет заметок."

      html = fire(lv, "new_note")
      [vault] = vaults()
      assert [%{title: "Заметка 1"}] = Notes.list_notes(vault.uuid)
      # The Leaf inside the panel is given this module's catalogue.
      assert html =~ "Жирный"

      fire(lv, "close_note")
      fire(lv, "new_note")
      titles = vault.uuid |> Notes.list_notes() |> Enum.map(& &1.title) |> Enum.sort()
      assert titles == ["Заметка 1", "Заметка 2"]
    end

    test "Estonian", %{conn: conn, me: me} do
      {:ok, lv, html} = mount_panel(conn, me, locale: "et")
      assert html =~ "Ainult minu"
      fire(lv, "new_note")
      [vault] = vaults()
      assert [%{title: "Märge 1"}] = Notes.list_notes(vault.uuid)
    end

    test "dates use the reader's month names", %{conn: conn, me: me} do
      note!(me, "Dated")
      {:ok, _lv, html} = mount_panel(conn, me, locale: "ru")

      # Core's `Date.short/1` and core's catalogue, as everywhere else in the
      # admin; its capitalisation is core's call.
      month =
        Enum.at(~w(янв фев мар апр мая июн июл авг сен окт ноя дек), Date.utc_today().month - 1)

      assert String.downcase(html) =~ month
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

    test "a followed link opens the note here; a missing one is created here", %{
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
      [vault] = vaults()
      created = Notes.get_note_by_title(vault.uuid, "Not yet written")
      assert created.folder_path == "Clients/Acme"
      assert html =~ NotesPanel.editor_id("panel", created)
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
      assert fire(lv, "new_note") =~ "You cannot do that here."
      assert fire(lv, "start", %{"what" => "folder"}) =~ "You cannot do that here."
      leaf(lv, {:leaf_link_clicked, %{editor_id: "x", target: "Sneaky"}})
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
      fire(lv, "new_note")
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

    test "without a Leaf that supports notify, a plain markdown editor edits in place",
         %{conn: conn, me: me, vault: vault, note: note} do
      Application.put_env(:phoenix_kit_knowledge_base, :leaf_notify, false)
      on_exit(fn -> Application.delete_env(:phoenix_kit_knowledge_base, :leaf_notify) end)

      {:ok, lv, _} = mount_panel(conn, me)
      html = fire(lv, "open_note", %{"uuid" => note.uuid})
      refute html =~ NotesPanel.editor_id("panel", note)
      assert has_element?(lv, "#panel-plain-#{note.uuid}", "before")
      assert html =~ "Saved as you type"

      # What the textarea sends (browsers use CRLF).
      html =
        lv
        |> form("#panel-plain-form", %{"note" => note.uuid, "content" => "line one\r\nline two"})
        |> render_change()

      assert file(vault, note) == "line one\nline two"
      assert html =~ "Saved"
    end

    test "the plain editor drops a late change for a note no longer open, and keeps the guard",
         %{conn: conn, me: me, vault: vault, note: note} do
      Application.put_env(:phoenix_kit_knowledge_base, :leaf_notify, false)
      on_exit(fn -> Application.delete_env(:phoenix_kit_knowledge_base, :leaf_notify) end)
      {_vault, other} = note!(me, "Other note", @path, :shared, "other")

      {:ok, lv, _} = mount_panel(conn, me)
      fire(lv, "open_note", %{"uuid" => note.uuid})

      # A debounced change naming another note: ignored.
      fire(lv, "plain_edit", %{"note" => other.uuid, "content" => "wrong"})
      assert file(vault, note) == "before"
      assert file(vault, other) == "other"

      # Someone else's save, straight to disk: not overwritten until chosen.
      {:ok, _} = Storage.write_note(vault.directory, note.relative_path, "theirs")
      html = fire(lv, "plain_edit", %{"note" => note.uuid, "content" => "mine"})
      assert html =~ "changed somewhere else"
      assert file(vault, note) == "theirs"

      fire(lv, "overwrite_note")
      assert file(vault, note) == "mine"
    end

    test "the plain editor is read-only, and refuses, for view-only access",
         %{conn: conn, other: other, vault: vault, note: note} do
      Application.put_env(:phoenix_kit_knowledge_base, :leaf_notify, false)
      on_exit(fn -> Application.delete_env(:phoenix_kit_knowledge_base, :leaf_notify) end)
      Application.put_env(:phoenix_kit_knowledge_base, :authorize, {Hooks, :view_only})

      {:ok, lv, _} = mount_panel(conn, other)
      fire(lv, "open_note", %{"uuid" => note.uuid})
      assert has_element?(lv, "#panel-plain-#{note.uuid}[readonly]")

      fire(lv, "plain_edit", %{"note" => note.uuid, "content" => "forged"})
      assert file(vault, note) == "before"
    end

    test "a note moved out of the folder is let go of, not followed", %{
      conn: conn,
      me: me,
      vault: vault,
      note: note
    } do
      {:ok, lv, _} = mount_panel(conn, me)
      fire(lv, "open_note", %{"uuid" => note.uuid})
      id = NotesPanel.editor_id("panel", note)

      # Moved elsewhere in the vault, on the admin page, while it is open here.
      {:ok, _} = Notes.create_folder(vault, "Clients", "Globex")
      {:ok, moved} = Notes.move_note(vault, note, "Clients/Globex")
      {:ok, _} = Notes.update_content(vault, moved, "Globex's now")

      # The next save fails (the file is gone from here), which offers "Take
      # theirs". Taking it must not open the note where it went.
      leaf(lv, {:leaf_changed, %{editor_id: id, markdown: "mine", html: "", dirty: true}})
      html = fire(lv, "reload_note")
      refute html =~ "Globex&#39;s now"
      refute html =~ id
      assert html =~ "moved or deleted"

      # And the poll lets go of it too.
      fire(lv, "open_note", %{"uuid" => note.uuid})
      refute tick(lv) =~ id
    end

    test "the poll lets go of an open note the panel's fence no longer holds", %{
      conn: conn,
      me: me,
      vault: vault,
      note: note
    } do
      {:ok, lv, _} = mount_panel(conn, me)
      fire(lv, "open_note", %{"uuid" => note.uuid})
      id = NotesPanel.editor_id("panel", note)

      {:ok, _} = Notes.create_folder(vault, "Clients", "Globex")
      {:ok, _} = Notes.move_note(vault, note, "Clients/Globex")

      html = tick(lv)
      refute html =~ id
      assert html =~ "moved or deleted"
    end

    test "a note renamed elsewhere stays open and saves under its new name", %{
      conn: conn,
      me: me,
      vault: vault,
      note: note
    } do
      {:ok, lv, _} = mount_panel(conn, me)
      fire(lv, "open_note", %{"uuid" => note.uuid})
      id = NotesPanel.editor_id("panel", note)

      {:ok, renamed} = Notes.rename_note(vault, note, "Renamed elsewhere")
      assert tick(lv) =~ "Renamed elsewhere"

      html = leaf(lv, {:leaf_changed, %{editor_id: id, markdown: "after", html: "", dirty: true}})
      refute html =~ "changed somewhere else"
      assert file(vault, renamed) == "after"
    end

    test "the vault deleted under an open note closes the note, not the page", %{
      conn: conn,
      me: me,
      vault: vault,
      note: note
    } do
      {:ok, lv, _} = mount_panel(conn, me)
      fire(lv, "open_note", %{"uuid" => note.uuid})
      id = NotesPanel.editor_id("panel", note)

      {:ok, _} = PhoenixKitKnowledgeBase.Vaults.delete(vault)
      refute tick(lv) =~ id

      # A keystroke Leaf had already debounced arrives after.
      leaf(lv, {:leaf_changed, %{editor_id: id, markdown: "late", html: "", dirty: true}})
      assert Process.alive?(lv.pid)
    end

    test "losing view access stops the editor's messages opening anything", %{
      conn: conn,
      me: me,
      note: note
    } do
      {_vault, plan} = note!(me, "Acme plan", @path, :shared, "the plan")
      {:ok, lv, _} = mount_panel(conn, me)
      fire(lv, "open_note", %{"uuid" => note.uuid})

      Application.put_env(:phoenix_kit_knowledge_base, :authorize, {Hooks, :nobody})
      html = leaf(lv, {:leaf_link_clicked, %{editor_id: "x", target: "Acme plan"}})
      refute html =~ NotesPanel.editor_id("panel", plan)
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
