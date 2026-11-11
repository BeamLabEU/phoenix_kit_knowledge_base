defmodule PhoenixKitKnowledgeBase.Web.NotesPanel do
  @moduledoc """
  Notes you can drop into any page: a small file list and an editor for one
  folder of a vault, named by a path.

      <PhoenixKitKnowledgeBase.Web.Components.notes_panel
        id="client-notes"
        current_user={@current_user}
        path={["CRM", "Clients", @client.name]}
      />

  The first segment of `path` is the vault, the rest the folder the panel shows;
  the first note or folder creates whatever is missing (`Places`). People make
  subfolders and write notes here, with autosave; they never see above `path`.
  Notes are ordinary files of an ordinary vault, so the admin vault page, links,
  tags and backlinks all work on them.

  ## Attributes

    * `id` (required)
    * `current_user` (required) — `%PhoenixKit.Users.Auth.User{}`; `nil` renders nothing
    * `path` (required) — `[vault, folder, …]`. Notes are kept by path: put
      something stable in it (an id), since a renamed segment is a new folder
    * `label` — the heading; defaults to the last path segment
    * `show_label` — default `true`
    * `visibility_options` — `[:private, :shared]` (default); the switch is
      hidden when there is one. Shared notes ask the host's `:authorize` hook
      (see `Places`); private ones are each person's own
    * `default_visibility` — `:shared` (default)
    * `poll` — ms between refreshes of the list, default `5_000`; `0` turns it off
    * `vault_link` — `false` (default). `true` adds a button at the top right
      that opens the whole vault on the admin pages, shown only to someone who
      may open it there
    * `class`

  ## How it runs inside someone else's page

  A LiveComponent shares the host LiveView's process. It cannot subscribe to
  PubSub or receive `handle_info`, so it polls, and its editor is Leaf with
  `notify: {__MODULE__, id}` — Leaf's messages arrive in `update/2` as
  `%{leaf: message}` instead of in the host's `handle_info`. A component's
  `put_flash` never reaches the page, so every message is shown inline.

  Every event checks access again (`Places.authorize/3`) and checks that what
  it names lies inside the panel's folder (`Places.within?/2`): the page is not
  trusted to have offered only what it was allowed to.
  """

  use PhoenixKitWeb, :live_component
  use Gettext, backend: PhoenixKitKnowledgeBase.Gettext

  import PhoenixKitWeb.Components.FolderExplorer, only: [folder_explorer: 1]

  alias Phoenix.LiveView.JS
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitKnowledgeBase.{Errors, Links, Markdown, Notes, Paths, Places, Storage, Vaults}
  alias PhoenixKitKnowledgeBase.Schemas.Note
  alias PhoenixKitKnowledgeBase.Web.VaultLive

  @default_poll 5_000
  @visibilities [:shared, :private]

  @doc false
  # Keyed to the panel and the note: two panels on a page may open the same
  # note, and a component id must be unique on the page. Per note for the same
  # reasons as `VaultLive.editor_id/1` — a fresh editor per note, and stale
  # `:leaf_changed` messages recognisable.
  @spec editor_id(String.t(), map()) :: String.t()
  def editor_id(panel_id, %{uuid: uuid}), do: "#{panel_id}-note-#{uuid}"

  @doc false
  # Whether the installed Leaf can send its messages to this component
  # (`notify`, Leaf 0.11). An older Leaf sends them to the LiveView hosting the
  # panel — a page that never asked for them, and crashes on them without a
  # catch-all `handle_info`. Without it the panel shows a note's text and no
  # editor. Read from Leaf's own attribute declarations rather than its version,
  # so an unreleased checkout that has the feature counts.
  #
  # `config :phoenix_kit_knowledge_base, :leaf_notify, true | false` overrides
  # the detection; the tests use it to exercise both sides with one Leaf.
  @spec leaf_notify?() :: boolean()
  def leaf_notify? do
    case Application.get_env(:phoenix_kit_knowledge_base, :leaf_notify, :auto) do
      value when is_boolean(value) -> value
      _ -> detect_leaf_notify()
    end
  end

  defp detect_leaf_notify do
    with true <- function_exported?(Leaf, :__components__, 0),
         %{attrs: attrs} <- Map.get(Leaf.__components__(), :leaf_editor) do
      Enum.any?(attrs, &(&1.name == :notify))
    else
      _ -> false
    end
  end

  @doc false
  # `VaultLive.save_decision/3`, with this panel's editor ids.
  @spec save_decision(String.t(), map(), map() | nil, String.t()) :: :save | :stale | :unchanged
  def save_decision(panel_id, payload, note, current_content) do
    cond do
      is_nil(note) or Map.get(payload, :editor_id) != editor_id(panel_id, note) -> :stale
      not Map.get(payload, :dirty, true) -> :unchanged
      Map.get(payload, :markdown) == current_content -> :unchanged
      true -> :save
    end
  end

  # ── Lifecycle ─────────────────────────────────────────────────────────────

  # The editor's messages are events like any other, and are asked about like
  # them: one arriving after access was withdrawn opens, offers and resolves
  # nothing. (`:leaf_changed` goes on to ask for `:edit` itself.)
  @impl true
  def update(%{leaf: message}, socket) do
    %{place: place, user: user} = socket.assigns

    if place && Places.authorize(:view, user, place),
      do: {:ok, handle_leaf(message, socket)},
      else: {:ok, socket}
  end

  # One chain of timers per panel: a tick clears the flag and re-arms, and a
  # host re-render in between finds it set and does not start a second chain.
  def update(%{tick: true}, socket) do
    {:ok, socket |> assign(:timer_armed?, false) |> load() |> check_open_note() |> arm_timer()}
  end

  def update(assigns, socket) do
    socket =
      socket
      |> assign_config(assigns)
      |> init_once()
      |> place_for_visibility()
      |> load()
      |> arm_timer()

    {:ok, socket}
  end

  defp assign_config(socket, assigns) do
    options = visibility_options(Map.get(assigns, :visibility_options, @visibilities))

    socket
    |> assign(:id, assigns.id)
    |> assign(:user, Map.get(assigns, :current_user))
    |> assign(:path, Map.get(assigns, :path))
    |> assign(:label, Map.get(assigns, :label))
    |> assign(:show_label?, Map.get(assigns, :show_label, true))
    |> assign(:visibility_options, options)
    |> assign(:default_visibility, Map.get(assigns, :default_visibility, :shared))
    |> assign(:poll, Map.get(assigns, :poll, @default_poll))
    |> assign(:vault_link?, Map.get(assigns, :vault_link, false) == true)
    |> assign(:class, Map.get(assigns, :class))
  end

  defp visibility_options(list) when is_list(list) do
    case Enum.filter(list, &(&1 in @visibilities)) do
      [] -> @visibilities
      valid -> Enum.uniq(valid)
    end
  end

  defp visibility_options(_), do: @visibilities

  defp init_once(%{assigns: %{initialized?: true}} = socket), do: socket

  defp init_once(socket) do
    options = socket.assigns.visibility_options
    default = socket.assigns.default_visibility

    socket
    |> assign(:initialized?, true)
    |> assign(:visibility, if(default in options, do: default, else: hd(options)))
    |> assign(:current_folder, nil)
    |> assign(:note, nil)
    |> assign(:content, "")
    |> assign(:save_status, :saved)
    |> assign(:conflict, false)
    |> assign(:remote_change, false)
    |> assign(:creating, nil)
    |> assign(:draft_title, "")
    |> assign(:just_created?, false)
    |> assign(:renaming?, false)
    |> assign(:notice, nil)
    |> assign(:vault, nil)
    |> assign(:folders, [])
    |> assign(:folder_stats, %{})
    |> assign(:notes, [])
    |> assign(:people, %{})
    |> assign(:admin_href, nil)
    |> assign(:admin_href_for, nil)
    |> assign(:timer_armed?, false)
    # Core's FolderExplorer, rooted at the panel's folder. `expanded_folders`
    # holds folder uuids, which is the component's contract.
    |> assign(:tree, [])
    |> assign(:tree_folders, %{})
    |> assign(:tree_items, %{})
    |> assign(:expanded_folders, MapSet.new())
    # Collapsed until opened: the list is what the panel is for, and on a
    # page the tree's 240px is taken from it.
    |> assign(:sidebar_collapsed, true)
    |> assign(:renaming_folder, nil)
    |> assign(:renaming_source, nil)
    |> assign(:renaming_text, "")
  end

  # The path and the visibility together name the place. Re-parsed whenever
  # either may have changed; a path the host got wrong is shown, not raised —
  # the rest of the host's page should not go down with this panel.
  defp place_for_visibility(socket) do
    case Places.parse(socket.assigns.path, socket.assigns.visibility) do
      {:ok, place} ->
        folder = socket.assigns.current_folder

        socket
        |> assign(:place, place)
        |> assign(:config_error, nil)
        |> assign(
          :current_folder,
          if(is_binary(folder) and Places.within?(place, folder), do: folder, else: place.folder)
        )

      {:error, reason} ->
        socket |> assign(:place, nil) |> assign(:config_error, reason)
    end
  end

  # ── Loading ───────────────────────────────────────────────────────────────

  defp load(%{assigns: %{place: nil}} = socket), do: socket
  defp load(%{assigns: %{user: nil}} = socket), do: socket

  defp load(socket) do
    %{place: place, user: user} = socket.assigns
    can_view? = Places.authorize(:view, user, place)
    can_edit? = can_view? and Places.authorize(:edit, user, place)
    vault = if can_view?, do: Places.locate(place, user)

    socket
    |> assign(:can_view?, can_view?)
    |> assign(:can_edit?, can_edit?)
    |> assign(:vault, vault)
    |> release_note_without_vault()
    |> load_listing()
    |> assign_admin_href()
  end

  defp load_listing(%{assigns: %{vault: nil}} = socket) do
    socket
    |> assign(:folders, [])
    |> assign(:folder_stats, %{})
    |> assign(:notes, [])
    |> assign(:tree, [])
    |> assign(:tree_folders, %{})
    |> assign(:tree_items, %{})
  end

  # Runs on every poll. Two queries: every folder below the panel's, and every
  # note in it without its body (the open note is read on its own). The tree
  # shows all of them; the listing is the current folder's share.
  defp load_listing(socket) do
    %{vault: vault, current_folder: current, place: place} = socket.assigns

    tree = Notes.folder_tree(vault.uuid, under: place.folder)
    folders = flatten_tree(tree)
    all_notes = Notes.list_notes(vault.uuid, under: place.folder, content: false)
    notes = Enum.filter(all_notes, &(&1.folder_path == current))

    shown_folders = Enum.filter(folders, &(parent_path(&1.relative_path) == current))
    folder_stats = folder_stats(shown_folders, all_notes)

    socket
    |> assign(:folders, shown_folders)
    |> assign(:folder_stats, folder_stats)
    |> assign(:notes, notes)
    |> assign(:tree, tree)
    |> assign(:tree_folders, Map.new(folders, &{&1.uuid, &1}))
    |> assign(:tree_items, tree_items(all_notes, folders, place.folder))
    |> assign_people(notes ++ Enum.flat_map(Map.values(folder_stats), &List.wrap(&1.latest)))
  end

  # What a folder's row says besides its name: how many notes are in it (all
  # the way down) and the latest change among them — when, and by whom. Read
  # from the notes the poll has already loaded, so it costs no query. A folder
  # records no author of its own (it is a directory on disk), so its
  # "Created" column has a date and no name.
  defp folder_stats(folders, notes) do
    Map.new(folders, fn folder ->
      prefix = folder.relative_path <> "/"

      inside =
        Enum.filter(
          notes,
          &(&1.folder_path == folder.relative_path or String.starts_with?(&1.folder_path, prefix))
        )

      {folder.uuid,
       %{
         count: length(inside),
         latest: Enum.max_by(inside, & &1.updated_at, DateTime, fn -> nil end)
       }}
    end)
  end

  defp flatten_tree(nodes),
    do: Enum.flat_map(nodes, &[&1.folder | flatten_tree(&1.children)])

  defp parent_path(relative_path) do
    case Path.dirname(relative_path) do
      "." -> ""
      parent -> parent
    end
  end

  # The explorer's leaves: notes keyed by their folder's uuid, the panel's own
  # folder as `"root"`. Plain maps — the component reads `:id` off each one for
  # `data-draggable-file`.
  defp tree_items(notes, folders, root) do
    uuid_by_path = Map.new(folders, &{&1.relative_path, &1.uuid})

    Enum.group_by(
      notes,
      fn note ->
        if note.folder_path == root, do: "root", else: Map.get(uuid_by_path, note.folder_path)
      end,
      &%{id: &1.uuid, label: &1.title}
    )
  end

  # Who wrote and who last changed each note, by name. Names are kept across
  # polls and only the people not yet known are read, so a listing that does
  # not change costs no query here. A uuid with no user behind it (deleted, or
  # written from outside the app) is remembered as unknown rather than asked
  # about again on every poll.
  defp assign_people(socket, notes) do
    known = socket.assigns.people

    missing =
      notes
      |> Enum.flat_map(&[&1.created_by, &1.updated_by])
      |> Enum.reject(&(is_nil(&1) or Map.has_key?(known, &1)))
      |> Enum.uniq()

    if missing == [] do
      socket
    else
      found = Map.new(Auth.get_users_by_uuids(missing), &{&1.uuid, Vaults.user_label(&1)})
      fetched = Map.new(missing, &{&1, Map.get(found, &1)})
      assign(socket, :people, Map.merge(known, fetched))
    end
  end

  # Only for someone who could open the vault on the admin pages anyway: the
  # `knowledge_base` permission and a role on this vault. Everyone else is never
  # shown a link to a page that would turn them away.
  #
  # Worked out once per vault, not on every poll: `Scope.for_user/1` reads the
  # person's roles and permissions, and a panel polls every few seconds. A link
  # that outlives a withdrawn role is harmless — the admin page asks again.
  #
  # Dialyzer reads the `MapSet` inside the `Scope` that `Scope.for_user/1` builds
  # as breaking its opacity when the struct is handed back to core. Core's own
  # types, not a fault here — a panel is given a user, not a scope, so it has to
  # build one.
  @dialyzer {:nowarn_function, assign_admin_href: 1}
  # Not asked for: no link, and no `Scope.for_user/1` to build one.
  defp assign_admin_href(%{assigns: %{vault_link?: false}} = socket),
    do: socket |> assign(:admin_href, nil) |> assign(:admin_href_for, nil)

  defp assign_admin_href(%{assigns: %{vault: nil}} = socket),
    do: socket |> assign(:admin_href, nil) |> assign(:admin_href_for, nil)

  defp assign_admin_href(%{assigns: %{vault: %{uuid: uuid}, admin_href_for: uuid}} = socket),
    do: socket

  defp assign_admin_href(%{assigns: %{vault: vault, user: user}} = socket) do
    scope = Scope.for_user(user)

    href =
      if Scope.has_module_access?(scope, "knowledge_base") and Vaults.role_for(vault, scope),
        do: Paths.vault(vault.slug)

    socket |> assign(:admin_href, href) |> assign(:admin_href_for, vault.uuid)
  end

  # The open note's file may have been changed by someone else. Announced,
  # never applied: the editor may hold keystrokes not yet saved, and replacing
  # them behind the writer's back loses them. Reloading is theirs to ask for.
  #
  # Re-read through the fence: a note moved out of the panel's folder on the
  # admin page is somebody else's now, and is let go of like a deleted one.
  defp check_open_note(%{assigns: %{note: nil}} = socket), do: socket

  defp check_open_note(%{assigns: %{note: note, vault: vault}} = socket) when not is_nil(vault) do
    case fenced_note(socket, note.uuid) do
      nil ->
        socket |> close_note() |> notice(:info, gettext("That note was moved or deleted."))

      %Note{content_hash: hash} when hash != note.content_hash ->
        assign(socket, :remote_change, true)

      # Same bytes, maybe a new name or folder (renamed elsewhere, still inside
      # the fence). Taken silently — the buffer is unaffected, and `save/3`
      # writes against `@note.relative_path`, which would otherwise be a path
      # that no longer exists.
      %Note{} = fresh ->
        assign(socket, :note, fresh)
    end
  end

  defp check_open_note(socket), do: socket

  # A note stays open only while its vault is in hand. `load/1` drops the vault
  # when it is deleted or this person may no longer see it; an open note left
  # behind would send a late keystroke from the editor to `save/3` with nothing
  # to write into — a clause error in the host's process.
  defp release_note_without_vault(%{assigns: %{vault: nil, note: %Note{}}} = socket),
    do: close_note(socket)

  defp release_note_without_vault(socket), do: socket

  defp arm_timer(%{assigns: %{poll: ms}} = socket) when is_integer(ms) and ms > 0 do
    if connected?(socket) and socket.assigns[:timer_armed?] != true do
      Phoenix.LiveView.send_update_after(__MODULE__, [id: socket.assigns.id, tick: true], ms)
      assign(socket, :timer_armed?, true)
    else
      socket
    end
  end

  defp arm_timer(socket), do: socket

  # ── Events ────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("visibility", %{"to" => to}, socket) do
    visibility = Enum.find(socket.assigns.visibility_options, &(Atom.to_string(&1) == to))

    if visibility do
      {:noreply,
       socket
       |> close_note()
       |> assign(:visibility, visibility)
       |> assign(:current_folder, nil)
       |> assign(:creating, nil)
       |> assign(:notice, nil)
       |> place_for_visibility()
       |> load()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("open_folder", %{"path" => path}, socket) do
    with_access(socket, :view, fn socket ->
      if Places.within?(socket.assigns.place, path),
        do: show_folder(socket, path),
        else: socket
    end)
  end

  # ── Events: core's FolderExplorer ─────────────────────────────────────────
  #
  # Its event names are MediaBrowser's and cannot be renamed by a consumer, so
  # the panel speaks them. Folders are named by uuid there and by path
  # everywhere else; `@tree_folders` holds only folders below the panel's own,
  # so a uuid not in it is outside the fence (or forged) and does nothing.

  def handle_event("navigate_folder", %{"folder-uuid" => uuid}, socket) do
    with_access(socket, :view, fn socket ->
      case Map.get(socket.assigns.tree_folders, uuid) do
        nil ->
          socket

        folder ->
          socket
          |> update(:expanded_folders, &MapSet.put(&1, uuid))
          |> show_folder(folder.relative_path)
      end
    end)
  end

  def handle_event("navigate_root", _params, socket) do
    with_access(socket, :view, &show_folder(&1, &1.assigns.place.folder))
  end

  def handle_event("toggle_folder_expand", %{"folder-uuid" => uuid}, socket)
      when is_binary(uuid) do
    expanded = socket.assigns.expanded_folders

    {:noreply,
     assign(
       socket,
       :expanded_folders,
       if(MapSet.member?(expanded, uuid),
         do: MapSet.delete(expanded, uuid),
         else: MapSet.put(expanded, uuid)
       )
     )}
  end

  def handle_event("toggle_sidebar", _params, socket),
    do: {:noreply, update(socket, :sidebar_collapsed, &(not &1))}

  # The explorer's "+": a folder in the folder being looked at.
  def handle_event("open_new_folder_modal", _params, socket) do
    handle_event("start", %{"what" => "folder"}, socket)
  end

  def handle_event("start_rename_folder", %{"folder-uuid" => uuid} = params, socket) do
    with_access(socket, :edit, fn socket ->
      case Map.get(socket.assigns.tree_folders, uuid) do
        nil ->
          socket

        folder ->
          socket
          |> assign(:renaming_folder, uuid)
          |> assign(:renaming_source, params["source"])
          |> assign(:renaming_text, folder.name)
      end
    end)
  end

  def handle_event("rename_folder_input", %{"name" => name}, socket) when is_binary(name),
    do: {:noreply, assign(socket, :renaming_text, name)}

  def handle_event("cancel_rename_folder", _params, socket),
    do: {:noreply, cancel_folder_rename(socket)}

  # A rename is a move to a sibling path: same parent, new last segment.
  def handle_event("rename_folder", %{"folder_uuid" => uuid, "name" => name}, socket)
      when is_binary(name) do
    with_access(socket, :edit, fn socket ->
      with %{} = folder <- Map.get(socket.assigns.tree_folders, uuid),
           {:ok, clean} <- Storage.validate_filename(name),
           target = Path.join(parent_path(folder.relative_path), clean),
           {:ok, _moved} <- Notes.relocate_folder(socket.assigns.vault, folder, target) do
        socket |> cancel_folder_rename() |> after_folder_move(folder.relative_path, target)
      else
        {:error, :unchanged} ->
          cancel_folder_rename(socket)

        nil ->
          cancel_folder_rename(socket)

        {:error, reason} ->
          socket |> cancel_folder_rename() |> notice(:error, error_message(reason))
      end
    end)
  end

  # ── Events: drag and drop (core's `MediaDragDrop` hook) ───────────────────
  #
  # The hook looks for drop targets across the whole document, so a note dragged
  # from this panel can be let go over another panel's folder — the target is
  # checked against this panel's fence like everything else. `""` is the hook's
  # name for the top of the tree: this panel's folder.

  def handle_event("move_file_to_folder", %{"file_uuid" => uuid} = params, socket) do
    with_access(socket, :edit, fn socket ->
      with {:ok, target} <- drop_target(socket, params["folder_uuid"]),
           %Note{} = note <- fenced_note(socket, uuid),
           true <- note.folder_path != target,
           {:ok, moved} <-
             Notes.move_note(socket.assigns.vault, note, target,
               actor_uuid: socket.assigns.user.uuid
             ) do
        socket |> follow_moved_note(moved) |> load_listing()
      else
        {:error, reason} -> notice(socket, :error, error_message(reason))
        _ -> socket
      end
    end)
  end

  def handle_event("move_folder_to_folder", %{"folder_uuid" => uuid} = params, socket) do
    with_access(socket, :edit, fn socket ->
      with %{} = folder <- Map.get(socket.assigns.tree_folders, uuid),
           {:ok, parent} <- drop_target(socket, params["target_uuid"]),
           # Into itself or below itself: nowhere to put it.
           false <-
             parent == folder.relative_path or
               String.starts_with?(parent, folder.relative_path <> "/"),
           target = Path.join(parent, folder.name),
           {:ok, _moved} <- Notes.relocate_folder(socket.assigns.vault, folder, target) do
        after_folder_move(socket, folder.relative_path, target)
      else
        {:error, :unchanged} -> socket
        {:error, reason} -> notice(socket, :error, error_message(reason))
        _ -> socket
      end
    end)
  end

  # A folder needs a name to be any use, so it asks for one. A note does not:
  # see "new_note".
  def handle_event("start", %{"what" => "folder"}, socket) do
    with_access(socket, :edit, fn socket ->
      socket
      |> assign(:creating, :folder)
      |> assign(:draft_title, "")
      |> assign(:notice, nil)
    end)
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, socket |> assign(:creating, nil) |> assign(:renaming?, false)}
  end

  # A new note is written in at once: it is created as "Note N" (the next
  # number free in this folder) and opened with the caret in it. What is in it
  # matters more than what it is called — the title can be changed afterwards,
  # from the pencil or by clicking it.
  def handle_event("new_note", _params, socket) do
    with_access(socket, :edit, &create_and_open(&1, :numbered))
  end

  def handle_event("create_folder", %{"name" => name}, socket) do
    with_access(socket, :edit, fn socket ->
      with {:ok, vault} <- Places.ensure(socket.assigns.place, socket.assigns.user),
           {:ok, _folder} <- Notes.create_folder(vault, socket.assigns.current_folder, name) do
        socket
        |> assign(:vault, vault)
        |> assign(:creating, nil)
        |> load_listing()
        |> assign_admin_href()
      else
        {:error, reason} -> notice(socket, :error, error_message(reason))
      end
    end)
  end

  def handle_event("open_note", %{"uuid" => uuid}, socket) do
    with_access(socket, :view, fn socket ->
      case fenced_note(socket, uuid) do
        %Note{} = note -> open_note(socket, note)
        nil -> socket
      end
    end)
  end

  def handle_event("close_note", _params, socket) do
    {:noreply, socket |> close_note() |> load_listing()}
  end

  def handle_event("start_rename", _params, socket) do
    with_access(socket, :edit, &assign(&1, :renaming?, true))
  end

  # From Enter, or from leaving the field (`phx-blur` sends `value`). A blur
  # that arrives after Escape already cancelled finds `renaming?` off and does
  # nothing; an unchanged title just closes the field.
  def handle_event("rename_note", %{"value" => title}, socket),
    do: if(socket.assigns.renaming?, do: rename(socket, title), else: {:noreply, socket})

  def handle_event("rename_note", %{"title" => title}, socket), do: rename(socket, title)

  def handle_event("trash_note", _params, socket) do
    with_open_note(socket, :edit, fn socket, vault, note ->
      case Notes.delete_note(vault, note) do
        {:ok, _} ->
          socket
          |> close_note()
          |> load_listing()
          |> notice(:info, gettext("Moved “%{title}” to the vault's trash.", title: note.title))

        {:error, reason} ->
          notice(socket, :error, error_message(reason))
      end
    end)
  end

  # The file changed underneath. Either take theirs… — through the fence: the
  # usual reason a save fails with `:missing_file` is that the note was moved,
  # and where it went may be outside this panel's folder.
  def handle_event("reload_note", _params, socket) do
    with_open_note(socket, :view, fn socket, _vault, note ->
      case fenced_note(socket, note.uuid) do
        nil ->
          socket |> close_note() |> notice(:info, gettext("That note was moved or deleted."))

        fresh ->
          refresh_editor(socket, fresh)

          socket
          |> assign(:note, fresh)
          |> assign(:content, fresh.content || "")
          |> assign(:conflict, false)
          |> assign(:remote_change, false)
          |> assign(:save_status, :saved)
      end
    end)
  end

  # …or keep mine. Never inferred from the conflict flag: autosave means saving
  # again is just typing on, and forcing on a raised flag would overwrite a
  # colleague's work without anyone choosing to. Only this button forces, once.
  def handle_event("overwrite_note", _params, socket) do
    with_open_note(socket, :edit, fn socket, _vault, _note ->
      save(socket, socket.assigns.content, force: true)
    end)
  end

  # The plain editor (no Leaf `notify`): what Leaf's `:leaf_changed` does,
  # from a textarea. The note it names must be the one open — a debounced
  # change can arrive after switching notes — and access is asked again.
  def handle_event("plain_edit", %{"note" => uuid, "content" => markdown}, socket)
      when is_binary(uuid) and is_binary(markdown) do
    # Browsers send a textarea's line breaks as CRLF.
    markdown = String.replace(markdown, "\r\n", "\n")
    %{note: note, place: place, user: user, content: current} = socket.assigns

    cond do
      is_nil(note) or note.uuid != uuid or markdown == current ->
        {:noreply, socket}

      place && Places.authorize(:edit, user, place) ->
        {:noreply, socket |> assign(:content, markdown) |> save(markdown)}

      true ->
        {:noreply,
         socket
         |> assign(:save_status, :unsaved)
         |> notice(:error, gettext("You cannot change these notes."))}
    end
  end

  def handle_event("dismiss", _params, socket), do: {:noreply, assign(socket, :notice, nil)}

  # Anything else — an old page's event, a forged one — is ignored. The panel
  # runs in the host's process: a clause error here would take the host's whole
  # page down.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp rename(socket, title) when is_binary(title) do
    with_open_note(socket, :edit, fn socket, vault, note ->
      if String.trim(title) == note.title,
        do: assign(socket, :renaming?, false),
        else: apply_rename(socket, vault, note, title)
    end)
  end

  defp rename(socket, _title), do: {:noreply, socket}

  defp apply_rename(socket, vault, note, title) do
    case Notes.rename_note(vault, note, title, actor_uuid: socket.assigns.user.uuid) do
      {:ok, renamed} -> socket |> assign(:note, renamed) |> assign(:renaming?, false)
      {:error, reason} -> notice(socket, :error, error_message(reason))
    end
  end

  # The listing of one folder. Leaving an open note for it is what clicking a
  # folder in a file manager does; autosave has already written what was typed.
  defp show_folder(socket, path) do
    socket
    |> close_note()
    |> expand_branch(path)
    |> assign(:current_folder, path)
    |> assign(:creating, nil)
    |> load_listing()
  end

  # Open the tree down to `path`, so it shows where the listing is even when it
  # was reached from the list or a crumb. Only on navigating: collapsing a
  # branch afterwards stays collapsed.
  defp expand_branch(socket, path) do
    on_branch =
      for {uuid, folder} <- socket.assigns.tree_folders,
          path == folder.relative_path or String.starts_with?(path, folder.relative_path <> "/"),
          do: uuid

    update(socket, :expanded_folders, &MapSet.union(&1, MapSet.new(on_branch)))
  end

  defp drop_target(socket, target) when target in [nil, "", "root"],
    do: {:ok, socket.assigns.place.folder}

  defp drop_target(socket, uuid) do
    case Map.get(socket.assigns.tree_folders, uuid) do
      nil -> :error
      folder -> {:ok, folder.relative_path}
    end
  end

  defp cancel_folder_rename(socket) do
    socket
    |> assign(:renaming_folder, nil)
    |> assign(:renaming_source, nil)
    |> assign(:renaming_text, "")
  end

  # A folder moved from `from` to `to`: the listing follows it if it was being
  # looked at (or something inside it was), and an open note inside it is
  # re-read — `save/3` writes against `@note.relative_path`, which just changed.
  defp after_folder_move(socket, from, to) do
    current = socket.assigns.current_folder

    socket =
      cond do
        current == from ->
          assign(socket, :current_folder, to)

        String.starts_with?(current, from <> "/") ->
          assign(socket, :current_folder, to <> String.replace_prefix(current, from, ""))

        true ->
          socket
      end

    socket = load_listing(socket)

    case socket.assigns.note do
      %Note{uuid: uuid} -> follow_moved_note(socket, fenced_note(socket, uuid))
      nil -> socket
    end
  end

  # The open note's row after a move: same bytes, new path. Only the row is
  # taken — the editor's buffer is untouched.
  defp follow_moved_note(
         %{assigns: %{note: %Note{uuid: uuid}}} = socket,
         %Note{uuid: uuid} = fresh
       ),
       do: assign(socket, :note, fresh)

  defp follow_moved_note(%{assigns: %{note: %Note{}}} = socket, nil),
    do: socket |> close_note() |> notice(:info, gettext("That note was moved or deleted."))

  defp follow_moved_note(socket, _moved), do: socket

  @numbered_attempts 20

  defp create_and_open(socket, title) do
    with {:ok, vault} <- Places.ensure(socket.assigns.place, socket.assigns.user),
         {:ok, note} <- create_note(socket, vault, title) do
      socket
      |> assign(:vault, vault)
      |> assign(:creating, nil)
      |> load_listing()
      |> assign_admin_href()
      |> open_note(note)
      |> assign(:just_created?, true)
    else
      {:error, reason} -> notice(socket, :error, error_message(reason))
    end
  end

  # "Note N" after the highest N already in the folder — in the reader's
  # language ("Заметка 3"), since the title is the file name they see. Two
  # people clicking at once both pick the same N; the second finds the file
  # taken and moves on to the next number rather than failing.
  defp create_note(socket, vault, :numbered) do
    folder = socket.assigns.current_folder
    numbered = numbered_title_regex()

    first =
      vault.uuid
      |> Notes.list_notes(folder_path: folder, content: false)
      |> Enum.flat_map(fn note ->
        case Regex.run(numbered, note.title) do
          [_, n] -> [String.to_integer(n)]
          nil -> []
        end
      end)
      |> Enum.max(fn -> 0 end)
      |> Kernel.+(1)

    Enum.reduce_while(first..(first + @numbered_attempts - 1), {:error, :already_exists}, fn n,
                                                                                             _ ->
      case create_note(socket, vault, numbered_title(n)) do
        {:error, :already_exists} = taken -> {:cont, taken}
        result -> {:halt, result}
      end
    end)
  end

  defp create_note(socket, vault, title) when is_binary(title) do
    Notes.create_note(
      vault,
      %{title: title, folder_path: socket.assigns.current_folder},
      socket.assigns.user.uuid
    )
  end

  defp numbered_title(n), do: gettext("Note %{number}", number: n)

  # The translated "Note %{number}" with the number as a capture, so the next
  # number is found whatever the language is. `[0-9]`, not `\d`: under the `u`
  # flag `\d` is any Unicode digit ("Note ٣" is a valid title), and
  # `String.to_integer/1` raises on those — in the host's process.
  defp numbered_title_regex do
    [before, after_] =
      case String.split(gettext("Note %{number}", number: "\0"), "\0", parts: 2) do
        [before, after_] -> [before, after_]
        _ -> ["Note ", ""]
      end

    Regex.compile!("^" <> Regex.escape(before) <> "([0-9]+)" <> Regex.escape(after_) <> "$", "u")
  end

  # Access is asked again on every event: it is the host's, and may have
  # changed since the panel rendered.
  defp with_access(socket, action, fun) do
    %{place: place, user: user} = socket.assigns

    if place && Places.authorize(action, user, place) do
      {:noreply, fun.(socket)}
    else
      {:noreply, notice(socket, :error, gettext("You cannot do that here."))}
    end
  end

  defp with_open_note(socket, action, fun) do
    with_access(socket, action, fn socket ->
      case socket.assigns do
        %{note: %Note{} = note, vault: vault} when not is_nil(vault) -> fun.(socket, vault, note)
        _ -> socket
      end
    end)
  end

  defp fenced_note(%{assigns: %{vault: nil}}, _uuid), do: nil

  defp fenced_note(%{assigns: %{vault: vault, place: place}}, uuid) do
    case Notes.get_note(vault.uuid, uuid) do
      %Note{} = note -> if Places.within?(place, note.folder_path), do: note
      nil -> nil
    end
  end

  defp open_note(socket, note) do
    socket
    |> assign(:note, note)
    |> assign(:content, note.content || "")
    |> assign(:save_status, :saved)
    |> assign(:conflict, false)
    |> assign(:remote_change, false)
    |> assign(:renaming?, false)
    |> assign(:notice, nil)
    |> assign(:just_created?, false)
  end

  defp close_note(socket) do
    socket
    |> assign(:note, nil)
    |> assign(:content, "")
    |> assign(:conflict, false)
    |> assign(:remote_change, false)
    |> assign(:renaming?, false)
  end

  defp notice(socket, kind, text), do: assign(socket, :notice, {kind, text})

  # ── The editor's messages (Leaf `notify`) ─────────────────────────────────

  defp handle_leaf({:leaf_changed, %{markdown: markdown} = payload}, socket) do
    case save_decision(socket.assigns.id, payload, socket.assigns.note, socket.assigns.content) do
      :save ->
        if socket.assigns.place &&
             Places.authorize(:edit, socket.assigns.user, socket.assigns.place) do
          socket |> assign(:content, markdown) |> save(markdown)
        else
          socket
          |> assign(:save_status, :unsaved)
          |> notice(:error, gettext("You cannot change these notes."))
        end

      # `:stale` is an edit from a note that is no longer open; `:unchanged` is
      # Leaf reporting a buffer that still matches what it loaded.
      _ ->
        socket
    end
  end

  # Leaf asks what a trigger should offer. Echo `trigger`, `query` and `seq`,
  # and answer every trigger, or the popup spins until it times out. Only notes
  # inside the panel's folder are offered: titles and tags from elsewhere in the
  # vault are other people's, and would leak to someone who may only see this
  # folder.
  defp handle_leaf(
         {:leaf_suggest, %{editor_id: id, trigger: trigger, query: query, seq: seq}},
         socket
       ) do
    results =
      case trigger do
        "[[" -> note_suggestions(socket, query)
        "#" -> tag_suggestions(socket, query)
        _ -> []
      end

    send_update(Leaf,
      id: id,
      action: :suggestions,
      trigger: trigger,
      query: query,
      seq: seq,
      results: results
    )

    socket
  end

  # Which `[[…]]` targets exist — inside this folder only (see `Links.resolver_from/1`).
  # No `href`: following a link happens here, never by URL, and an admin URL is
  # not something to hand a person who may not have the admin pages.
  defp handle_leaf({:leaf_resolve_links, %{editor_id: id, targets: targets, seq: seq}}, socket) do
    if socket.assigns.note && id == editor_id(socket.assigns.id, socket.assigns.note) do
      send_update(Leaf,
        id: id,
        action: :link_targets,
        seq: seq,
        targets: link_targets(socket, targets)
      )
    end

    socket
  end

  # A followed link opens the note here, or creates it here — the
  # target is resolved again rather than trusting anything the page sent.
  defp handle_leaf({:leaf_link_clicked, %{target: target}}, socket) do
    from_folder = (socket.assigns.note && socket.assigns.note.folder_path) || ""

    case Links.resolve(fenced_resolver(socket), Markdown.normalize_title(target), from_folder) do
      %{uuid: uuid} ->
        case fenced_note(socket, uuid) do
          %Note{} = note -> socket |> close_note() |> open_note(note)
          nil -> socket
        end

      # Not written yet: write it — in the folder the panel is in, named as the
      # link names it, open and ready to type in. Access is asked again: this
      # arrives from the editor, not from a button the panel decided to show.
      nil ->
        if socket.assigns.place &&
             Places.authorize(:edit, socket.assigns.user, socket.assigns.place) do
          socket |> close_note() |> create_and_open(target)
        else
          socket
        end
    end
  end

  # Mode changes, focus, and anything a later Leaf adds: nothing to do, and an
  # unmatched clause would take the host's page down.
  defp handle_leaf(_message, socket), do: socket

  # A note reloaded under the open editor. The plain editor re-renders from
  # `content`; only Leaf, whose surface LiveView never patches, needs telling.
  defp refresh_editor(socket, fresh) do
    if leaf_notify?() do
      send_update(Leaf,
        id: editor_id(socket.assigns.id, fresh),
        action: :set_content,
        content: fresh.content || ""
      )
    end

    :ok
  end

  defp save(socket, content, opts \\ []) do
    %{vault: vault, note: note, user: user} = socket.assigns
    opts = Keyword.merge([actor_uuid: user.uuid, force: false], opts)

    case Notes.update_content(vault, note, content, opts) do
      {:ok, saved} ->
        socket
        |> assign(:note, saved)
        |> assign(:save_status, :saved)
        |> assign(:conflict, false)
        |> assign(:remote_change, false)
        |> assign(:notice, nil)

      # The file moved underneath. Do not write: raise the flag and let the
      # writer choose between reloading and overwriting.
      {:error, reason} when reason in [:stale, :missing_file] ->
        socket |> assign(:save_status, :unsaved) |> assign(:conflict, true)

      {:error, reason} ->
        socket |> assign(:save_status, :unsaved) |> notice(:error, error_message(reason))
    end
  end

  # ── Suggestions and links, fenced ─────────────────────────────────────────

  defp fenced_notes(%{assigns: %{vault: nil}}), do: []

  # Titles, paths and tags of the whole fenced subtree, for every suggestion
  # popup and every link check the editor makes — never the bodies.
  defp fenced_notes(%{assigns: %{vault: vault, place: place}}) do
    Notes.list_notes(vault.uuid, under: place.folder, order: :updated, content: false)
  end

  defp fenced_resolver(socket), do: socket |> fenced_notes() |> Links.resolver_from()

  defp note_suggestions(socket, query) do
    needle = query |> to_string() |> String.trim() |> String.downcase()
    open_uuid = socket.assigns.note && socket.assigns.note.uuid
    notes = Enum.reject(fenced_notes(socket), &(&1.uuid == open_uuid))
    counts = Enum.frequencies_by(notes, & &1.title_key)

    notes
    |> Enum.filter(&(needle == "" or String.contains?(String.downcase(&1.title), needle)))
    |> Enum.take(8)
    |> Enum.map(fn note ->
      %{
        # A title several notes here answer to is inserted path-qualified, so
        # the link records which one was meant.
        value:
          if(Map.get(counts, note.title_key, 1) > 1,
            do: Path.rootname(note.relative_path),
            else: note.title
          ),
        label: note.title,
        sublabel: if(note.folder_path == "", do: gettext("top level"), else: note.folder_path),
        icon: "hero-document-text"
      }
    end)
  end

  defp tag_suggestions(socket, query) do
    needle = query |> to_string() |> String.downcase()

    socket
    |> fenced_notes()
    |> Enum.flat_map(& &1.tags)
    |> Enum.frequencies()
    |> Enum.filter(fn {tag, _count} -> String.contains?(tag, needle) end)
    |> Enum.sort_by(fn {tag, count} -> {-count, tag} end)
    |> Enum.take(8)
    |> Enum.map(fn {tag, count} ->
      %{
        value: tag,
        label: "##{tag}",
        sublabel: ngettext("%{count} note", "%{count} notes", count),
        icon: "hero-hashtag"
      }
    end)
  end

  defp link_targets(socket, targets) do
    resolver = fenced_resolver(socket)
    from_folder = (socket.assigns.note && socket.assigns.note.folder_path) || ""

    Map.new(targets, fn target ->
      case Links.resolve(resolver, Markdown.normalize_title(target), from_folder) do
        nil ->
          {target,
           %{
             exists: false,
             title:
               if(socket.assigns.can_edit?,
                 do: gettext("No note with this title here yet — click to create it"),
                 else: gettext("No note with this title here")
               )
           }}

        note ->
          {target,
           %{
             exists: true,
             title:
               gettext("Open “%{title}”", title: Path.rootname(Path.basename(note.relative_path)))
           }}
      end
    end)
  end

  # The panel's own wording where a person here needs a different sentence from
  # the admin page's; everything else is `Errors.message/1`, which never shows
  # a raw term (it logs one).
  defp error_message(:unauthorized), do: gettext("You cannot do that here.")
  defp error_message(:already_exists), do: gettext("Something with that name is already here.")
  defp error_message(:target_exists), do: gettext("Something with that name is already here.")
  defp error_message(:blank), do: gettext("Give it a name.")

  defp error_message(reason) when reason in [:stale, :missing_file],
    do: gettext("This note was changed somewhere else, so this edit was not saved.")

  defp error_message({:forbidden_characters, chars}),
    do: gettext("A name cannot contain %{characters}.", characters: Enum.join(chars, " "))

  defp error_message(:leading_dot), do: gettext("A name cannot start with a dot.")
  defp error_message(:trailing_dot), do: gettext("A name cannot end with a dot.")
  defp error_message(:too_long), do: gettext("That name is too long.")
  defp error_message(:reserved), do: gettext("That name is reserved by the operating system.")
  defp error_message({:folder, reason}), do: error_message(reason)
  defp error_message(%Ecto.Changeset{}), do: gettext("These notes could not be set up.")
  defp error_message(other), do: Errors.message(other)

  # ── Render ────────────────────────────────────────────────────────────────

  @impl true
  def render(%{user: nil} = assigns), do: ~H"<div id={@id} hidden></div>"

  def render(%{config_error: error} = assigns) when not is_nil(error) do
    ~H"""
    <div id={@id} class={["alert alert-warning text-sm", @class]}>
      <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
      <span>{gettext("This notes panel's path is not usable: %{reason}",
        reason: inspect(@config_error)
      )}</span>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <section
      id={@id}
      class={[
        "@container/panel rounded-box border border-base-300 bg-base-100 p-3 sm:p-4 space-y-3 min-w-0",
        @class
      ]}
    >
      <%!-- The visibility switch and the vault link. The label is the list's
           own title now (core's media header); nothing to put here, no strip. --%>
      <header
        :if={length(@visibility_options) > 1 or not is_nil(@admin_href)}
        class="flex flex-wrap items-center justify-between gap-2"
      >
        <div class="flex items-center gap-1 ml-auto">
          <div
            :if={length(@visibility_options) > 1}
            class="join"
            role="group"
            aria-label={gettext("Whose notes")}
          >
            <button
              :for={v <- @visibility_options}
              type="button"
              phx-click="visibility"
              phx-value-to={v}
              phx-target={@myself}
              class={[
                "btn btn-xs join-item",
                if(v == @visibility, do: "btn-active", else: "btn-ghost")
              ]}
              aria-pressed={to_string(v == @visibility)}
            >
              {if v == :private, do: gettext("Only me"), else: gettext("Everyone here")}
            </button>
          </div>
          <a
            :if={@admin_href}
            href={@admin_href}
            class="btn btn-ghost btn-xs"
            title={gettext("Open the whole vault")}
            aria-label={gettext("Open the whole vault")}
          >
            <.icon name="hero-arrow-top-right-on-square" class="w-4 h-4" />
          </a>
        </div>
      </header>

      <div
        :if={@notice}
        class={[
          "alert text-sm py-2",
          if(elem(@notice, 0) == :error, do: "alert-error", else: "alert-info")
        ]}
        role="status"
      >
        <span class="min-w-0">{elem(@notice, 1)}</span>
        <button
          type="button"
          phx-click="dismiss"
          phx-target={@myself}
          class="btn btn-ghost btn-xs"
          aria-label={gettext("Dismiss")}
        >
          <.icon name="hero-x-mark" class="w-4 h-4" />
        </button>
      </div>

      <p :if={not @can_view?} class="text-sm text-base-content/60 italic">
        {gettext("You do not have access to these notes.")}
      </p>

      <%!--
        Core's drag-and-drop hook, as the media page uses it: it finds the
        `data-draggable-*` rows (tree and list) and the `data-drop-folder`
        targets, and pushes `move_file_to_folder` / `move_folder_to_folder` to
        the component this element is in. Core registers it, so this module
        still ships no JavaScript.
      --%>
      <div
        :if={@can_view?}
        id={"#{@id}-body"}
        phx-hook={if @can_edit?, do: "MediaDragDrop"}
        class="flex min-w-0 items-stretch"
      >
        <%!-- The tree needs room: shown once the panel itself is wide enough
             (a container query, not the window), the breadcrumbs otherwise. --%>
        <.folder_explorer
          id={"#{@id}-tree"}
          myself={@myself}
          class="hidden @2xl/panel:block"
          folder_tree={@tree}
          current_folder={tree_current(@tree_folders, @current_folder)}
          expanded_folders={@expanded_folders}
          scope_folder_id={@id}
          scope_folder_name={@label || List.last(@place.path)}
          renaming_folder={@renaming_folder}
          renaming_source={@renaming_source}
          renaming_text={@renaming_text}
          sidebar_collapsed={@sidebar_collapsed}
          show_create={@can_edit?}
          show_all_files={false}
          show_trash={false}
          show_rename={@can_edit?}
          enable_drag={@can_edit?}
          items={@tree_items}
        >
          <:item :let={entry}>
            <button
              type="button"
              phx-click="open_note"
              phx-value-uuid={entry.id}
              phx-target={@myself}
              class={[
                "block w-full truncate py-1 text-left text-sm",
                if(@note && @note.uuid == entry.id,
                  do: "font-medium text-primary",
                  else: "text-base-content/70 hover:text-base-content"
                )
              ]}
            >
              {entry.label}
            </button>
          </:item>
        </.folder_explorer>

        <%!-- Its own container: beside the tree, the table's columns answer to
             the room this column has, not to the whole panel. --%>
        <div class="@container min-w-0 flex-1">
          <%= if @note do %>
            {render_note(assigns)}
          <% else %>
            {render_listing(assigns)}
          <% end %>
        </div>
      </div>
    </section>
    """
  end

  defp render_listing(assigns) do
    ~H"""
    <div class="space-y-2">
      <%!-- Core's media header: a tinted block fading into the page, the
           folder's name in bold, the primary action top right. --%>
      <div class="relative rounded-xl">
        <div class="absolute inset-0 rounded-xl bg-gradient-to-br from-base-200 to-base-300"></div>
        <div class="absolute inset-0 rounded-xl bg-gradient-to-t from-base-100 via-base-100/60 to-transparent">
        </div>
        <div class="relative z-10 p-3 sm:p-4 flex flex-col gap-1">
          <nav
            :if={crumbs(@place, @current_folder) != []}
            class="flex flex-wrap items-center gap-1 text-sm @2xl/panel:hidden"
            aria-label={gettext("Folder")}
          >
            <%= for {crumb, index} <- Enum.with_index(crumbs(@place, @current_folder)) do %>
              <span :if={index > 0} class="text-base-content/40">/</span>
              <button
                type="button"
                phx-click="open_folder"
                phx-value-path={crumb.path}
                phx-target={@myself}
                class="link link-hover truncate max-w-[12rem]"
              >
                {crumb.label}
              </button>
            <% end %>
          </nav>
          <div class="flex flex-wrap items-center gap-2">
            <h2
              :if={listing_title(assigns)}
              class="text-lg font-bold text-base-content break-words leading-tight min-w-0"
            >
              {listing_title(assigns)}
            </h2>
            <div :if={@can_edit? and is_nil(@creating)} class="flex items-center gap-2 ml-auto">
              <button
                type="button"
                phx-click="start"
                phx-value-what="folder"
                phx-target={@myself}
                class="btn btn-sm btn-ghost gap-2"
                title={gettext("New folder")}
              >
                <.icon name="hero-folder-plus" class="w-4 h-4" />
                <span class="hidden @sm:inline">{gettext("Folder")}</span>
              </button>
              <button
                type="button"
                phx-click="new_note"
                phx-target={@myself}
                class="btn btn-sm btn-primary gap-2"
              >
                <.icon name="hero-plus" class="w-4 h-4" /> {gettext("Note")}
              </button>
            </div>
          </div>
        </div>
      </div>

      <%!-- A table like core's media list. The panel is often a sidebar, so
           the columns follow the panel's own width (a container query), not
           the window's: narrow, they fold into one line under the name. --%>
      <table :if={@folders != [] or @notes != []} class="table table-sm">
        <thead class="hidden @sm:table-header-group">
          <tr>
            <th>{gettext("Name")}</th>
            <th>{gettext("Created")}</th>
            <th>{gettext("Modified")}</th>
          </tr>
        </thead>
        <tbody>
          <%!-- Ids on every row: without them LiveView reuses a row for
               whatever lands in its place — a folder's row becomes a note's
               after opening the folder — and the drag hook's listeners on
               it come along. --%>
          <tr
            :for={folder <- @folders}
            id={"#{@id}-folder-#{folder.uuid}"}
            phx-click="open_folder"
            phx-value-path={folder.relative_path}
            phx-target={@myself}
            data-drop-folder={@can_edit? && folder.uuid}
            data-draggable-folder={@can_edit? && folder.uuid}
            class="hover cursor-pointer"
          >
            <td class="min-w-0">
              <button
                type="button"
                phx-click="open_folder"
                phx-value-path={folder.relative_path}
                phx-target={@myself}
                class="flex w-full min-w-0 items-center gap-2 text-left"
              >
                <.icon name="hero-folder" class="w-4 h-4 shrink-0 text-base-content/60" />
                <span class="truncate font-medium">{folder.name}</span>
              </button>
              <%!-- The same two lines a note's row has, so the rows are one
                   height: the folder's size, and its latest change on a
                   narrow panel. --%>
              <div class="pl-6 text-xs text-base-content/50 truncate">
                {ngettext("%{count} note", "%{count} notes", @folder_stats[folder.uuid].count)}<span
                  :if={@folder_stats[folder.uuid].latest}
                  class="@sm:hidden"
                > · {gettext("Modified %{date}",
                  date: short_date(@folder_stats[folder.uuid].latest.updated_at)
                )}</span>
              </div>
            </td>
            <td class="hidden @sm:table-cell whitespace-nowrap">
              {render_stamp(%{at: folder.inserted_at, by: nil, people: @people})}
            </td>
            <td class="hidden @sm:table-cell whitespace-nowrap">
              <%= if latest = @folder_stats[folder.uuid].latest do %>
                {render_stamp(%{at: latest.updated_at, by: latest.updated_by, people: @people})}
              <% else %>
                {render_stamp(%{at: folder.updated_at, by: nil, people: @people})}
              <% end %>
            </td>
          </tr>
          <tr
            :for={note <- @notes}
            id={"#{@id}-row-#{note.uuid}"}
            phx-click="open_note"
            phx-value-uuid={note.uuid}
            phx-target={@myself}
            data-draggable-file={@can_edit? && note.uuid}
            class="hover cursor-pointer"
          >
            <td class="min-w-0">
              <button
                type="button"
                phx-click="open_note"
                phx-value-uuid={note.uuid}
                phx-target={@myself}
                class="flex w-full min-w-0 items-center gap-2 text-left"
              >
                <.icon name="hero-document-text" class="w-4 h-4 shrink-0 text-base-content/60" />
                <span class="truncate">{note.title}</span>
              </button>
              <div class="@sm:hidden pl-6 text-xs text-base-content/50 truncate">
                {gettext("Modified %{date}", date: short_date(note.updated_at))}<span :if={
                  note.updated_by
                }> · {person(@people, note.updated_by)}</span>
              </div>
            </td>
            <td class="hidden @sm:table-cell whitespace-nowrap">
              {render_stamp(%{at: note.inserted_at, by: note.created_by, people: @people})}
            </td>
            <td class="hidden @sm:table-cell whitespace-nowrap">
              {render_stamp(%{at: note.updated_at, by: note.updated_by, people: @people})}
            </td>
          </tr>
        </tbody>
      </table>

      <p :if={@folders == [] and @notes == []} class="text-sm text-base-content/50 italic">
        {if @can_edit?, do: gettext("No notes here yet."), else: gettext("No notes here.")}
      </p>

      <form
        :if={@creating}
        id={"#{@id}-create"}
        phx-submit="create_folder"
        phx-target={@myself}
        class="flex flex-wrap gap-2"
      >
        <input
          type="text"
          name="name"
          value={@draft_title}
          placeholder={gettext("Folder name")}
          aria-label={gettext("Folder name")}
          class="input input-sm flex-1 min-w-0"
          autofocus
          required
        />
        <button type="submit" class="btn btn-sm btn-primary">
          {gettext("Create folder")}
        </button>
        <button type="button" phx-click="cancel" phx-target={@myself} class="btn btn-sm btn-ghost">
          {gettext("Cancel")}
        </button>
      </form>
    </div>
    """
  end

  defp render_note(assigns) do
    ~H"""
    <article class="space-y-2">
      <%!-- The same tinted header as the list (core's media header). --%>
      <div class="relative rounded-xl">
        <div class="absolute inset-0 rounded-xl bg-gradient-to-br from-base-200 to-base-300"></div>
        <div class="absolute inset-0 rounded-xl bg-gradient-to-t from-base-100 via-base-100/60 to-transparent">
        </div>
        <div class="relative z-10 p-2 sm:p-3 flex flex-wrap items-center gap-2">
          <button
            type="button"
            phx-click="close_note"
            phx-target={@myself}
            class="btn btn-ghost btn-xs"
            title={gettext("Back to the list")}
            aria-label={gettext("Back to the list")}
          >
            <.icon name="hero-arrow-left" class="w-4 h-4" />
          </button>

          <%!-- The title is the rename field: it looks like one on hover
             (border, pencil), and a click turns it into one in place. Enter
             or leaving the field saves, Escape puts it back. --%>
          <form
            :if={@renaming?}
            id={"#{@id}-rename"}
            phx-submit="rename_note"
            phx-target={@myself}
            class="flex-1 min-w-0"
          >
            <input
              id={"#{@id}-rename-input"}
              type="text"
              name="title"
              value={@note.title}
              aria-label={gettext("Note title")}
              class="input input-sm w-full font-medium"
              phx-mounted={JS.focus()}
              phx-blur="rename_note"
              phx-keydown="cancel"
              phx-key="Escape"
              phx-target={@myself}
              autofocus
              required
            />
          </form>

          <button
            :if={not @renaming? and @can_edit?}
            type="button"
            phx-click="start_rename"
            phx-target={@myself}
            class="group flex flex-1 min-w-0 items-center gap-1.5 rounded-field border border-transparent px-2 h-8 text-left font-medium cursor-text hover:border-base-300 hover:bg-base-200/50 focus-visible:border-base-300"
            title={gettext("Click to rename")}
            aria-label={gettext("Rename “%{title}”", title: @note.title)}
          >
            <span class="truncate">{@note.title}</span>
            <.icon
              name="hero-pencil"
              class="w-3.5 h-3.5 shrink-0 opacity-40 group-hover:opacity-80"
            />
          </button>
          <h3 :if={not @renaming? and not @can_edit?} class="font-medium truncate flex-1 min-w-0 px-2">
            {@note.title}
          </h3>

          <span :if={not @renaming?} class={["badge badge-sm", save_class(@save_status)]}>
            {save_label(@save_status)}
          </span>

          <div :if={@can_edit? and not @renaming?} class="flex gap-1">
            <button
              type="button"
              phx-click="trash_note"
              phx-target={@myself}
              data-confirm={gettext("Move this note to the vault's trash?")}
              class="btn btn-ghost btn-xs text-error"
              title={gettext("Move to trash")}
              aria-label={gettext("Move to trash")}
            >
              <.icon name="hero-trash" class="w-4 h-4" />
            </button>
          </div>
        </div>
      </div>

      <div :if={@conflict} class="alert alert-warning text-sm py-2 flex-wrap">
        <span class="min-w-0">
          {gettext("This note was changed somewhere else, so this edit was not saved.")}
        </span>
        <div class="flex gap-1">
          <button type="button" phx-click="reload_note" phx-target={@myself} class="btn btn-xs">
            {gettext("Take theirs")}
          </button>
          <button
            type="button"
            phx-click="overwrite_note"
            phx-target={@myself}
            class="btn btn-xs btn-warning"
          >
            {gettext("Keep mine")}
          </button>
        </div>
      </div>

      <div :if={@remote_change and not @conflict} class="alert alert-info text-sm py-2 flex-wrap">
        <span class="min-w-0">{gettext("Someone else changed this note.")}</span>
        <button type="button" phx-click="reload_note" phx-target={@myself} class="btn btn-xs">
          {gettext("Show their version")}
        </button>
      </div>

      <%!-- Without a Leaf that can talk to this component (notify, 0.11),
           a plain markdown editor: the same autosave, the same stale guard
           and conflict choice, the same access checks. Formatting toolbar
           and [[ / # suggestions are Leaf's, so they wait for it. --%>
      <.form
        :if={not leaf_notify?()}
        for={%{}}
        id={"#{@id}-plain-form"}
        phx-change="plain_edit"
        phx-submit="plain_edit"
        phx-target={@myself}
        class="space-y-1"
      >
        <input type="hidden" name="note" value={@note.uuid} />
        <textarea
          id={"#{@id}-plain-#{@note.uuid}"}
          name="content"
          rows="12"
          phx-debounce="700"
          readonly={not @can_edit?}
          placeholder={gettext("Write here. Link with [[Note title]], tag with #tag.")}
          class="textarea w-full font-mono text-sm leading-relaxed"
        >{Phoenix.HTML.Form.normalize_value("textarea", @content)}</textarea>
        <p class="text-xs text-base-content/50">
          {gettext("Markdown. Saved as you type.")}
        </p>
      </.form>

      <.live_component
        :if={leaf_notify?()}
        module={Leaf}
        id={editor_id(@id, @note)}
        content={@content}
        mode={:hybrid}
        preset={:simple}
        suggestions={suggestion_configs()}
        wiki_links={%{resolve: true, follow: :click}}
        deny={[:visual_mode, :html_mode]}
        placeholder={gettext("Write here. Link with [[Note title]], tag with #tag.")}
        height="40vh"
        debounce={500}
        readonly={not @can_edit?}
        notify={{__MODULE__, @id}}
        gettext_backend={PhoenixKitKnowledgeBase.Gettext}
        autofocus={@just_created?}
      />
    </article>
    """
  end

  # The explorer's current folder is a folder struct, or nil for the top (the
  # panel's own folder, which is not in the tree).
  defp tree_current(tree_folders, path) do
    Enum.find_value(tree_folders, fn {_uuid, folder} ->
      if folder.relative_path == path, do: folder
    end)
  end

  # When, and by whom underneath — a dash when nobody is on record.
  defp render_stamp(assigns) do
    ~H"""
    <time
      class="block text-xs"
      datetime={DateTime.to_iso8601(@at)}
      title={PhoenixKit.Utils.Date.format_short_datetime(@at)}
    >
      {short_date(@at)}
    </time>
    <span :if={@by} class="block text-xs text-base-content/50 truncate max-w-[12rem]">
      {person(@people, @by)}
    </span>
    <%!-- Nobody on record (a folder, a file written outside the app): a
         dash, so the row keeps the height of the others. --%>
    <span :if={is_nil(@by)} class="block text-xs text-base-content/30" aria-hidden="true">—</span>
    """
  end

  defp person(people, uuid), do: Map.get(people, uuid) || gettext("Unknown user")

  # The list's title: the folder's name below the panel's own folder; at the top
  # the panel's label (unless the host turned the label off).
  defp listing_title(%{place: place, current_folder: current} = assigns) do
    if current == place.folder do
      if assigns.show_label?, do: assigns.label || List.last(place.path)
    else
      Path.basename(current)
    end
  end

  # The trail from the panel's own folder down to the current one — never above
  # it. The first crumb is the panel's root, labelled as the panel is.
  defp crumbs(place, current) do
    root = %{label: List.last(place.path), path: place.folder}

    below =
      if current == place.folder do
        []
      else
        rest =
          if place.folder == "",
            do: current,
            else: String.replace_prefix(current, place.folder <> "/", "")

        rest
        |> String.split("/", trim: true)
        |> Enum.scan({nil, place.folder}, fn segment, {_label, parent} ->
          {segment, if(parent == "", do: segment, else: parent <> "/" <> segment)}
        end)
        |> Enum.map(fn {label, path} -> %{label: label, path: path} end)
      end

    if below == [], do: [], else: [root | below]
  end

  # "5 Nov" / "5. nov" — core's, so the order and punctuation come from each
  # language's own translation rather than a format string written in English.
  defp short_date(datetime) do
    if datetime.year == Date.utc_today().year,
      do: PhoenixKit.Utils.Date.short(datetime),
      else: PhoenixKit.Utils.Date.short_with_year(datetime)
  end

  # The vault page's configs, headings already in the reader's language.
  defp suggestion_configs, do: VaultLive.suggestion_configs()

  defp save_label(:saved), do: gettext("Saved")
  defp save_label(:unsaved), do: gettext("Not saved")

  defp save_class(:saved), do: "badge-ghost"
  defp save_class(:unsaved), do: "badge-warning"
end
