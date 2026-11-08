defmodule PhoenixKitKnowledgeBase.Web.VaultLive do
  @moduledoc """
  The vault workspace — one LiveView serving three routes, so moving between
  notes patches the note pane instead of remounting the sidebar:

    * `:index` — the vault with no note open
    * `:show`  — a note open (read or edit)
    * `:new`   — the "this note doesn't exist yet" page an unresolved
      `[[wiki-link]]` points at

  ## Editing

  Obsidian's model, and only that: clicking a note puts you in the editor, the
  editor is already a rendered view, and there is no second "reading" surface to
  switch to. That editor is [Leaf](https://hex.pm/packages/leaf) — the same one
  PhoenixKit uses elsewhere — in **hybrid mode**, its Obsidian-style live
  preview, where formatting renders inline while the source markers stay
  editable. Someone with read-only access gets the same surface, not a different
  one.

  `[[wiki-links]]` render as link tokens in the editor itself. Leaf decorates
  them and asks which targets exist — only this module knows that — and the
  answer goes back through the same resolver and same-folder tie-break that
  built the stored link index, so a link never renders as pointing somewhere
  the backlinks panel disagrees with. An unresolved target is styled distinctly
  and points at the create page.

  Leaf never navigates on a click; it reports one and leaves the destination to
  us. The right-hand panel still lists outgoing links, which is the path for a
  reader who wants the whole set rather than the one under the cursor.

  Visual and HTML modes are denied. Both round-trip the document through HTML,
  and a note's YAML front matter is `---`-delimited — which survives that trip
  as a horizontal rule and a paragraph, silently destroying every property on
  the note. Hybrid and markdown modes edit the source directly and are safe.

  Edits autosave: Leaf debounces, the save writes the file and reindexes it,
  and the status pill reports where that got to.

  ## `[[` and `#` autocomplete

  Leaf's inline-suggestion triggers do the real thing — a caret-anchored popup,
  arrow keys to move, Enter or Tab to accept, Escape to dismiss, and it works
  mid-paragraph because the client knows where the caret is.

  `[[` completes note titles and `#` completes tags. Both allow creating what
  does not exist yet, so you can link ahead of yourself exactly as in Obsidian.
  A suggestion whose title several notes share is inserted **path-qualified**,
  so the link says which note it meant rather than leaving it to the tie-break.
  """
  use PhoenixKitWeb, :live_view
  # After `use PhoenixKitWeb`, which installs core's backend: this module's
  # strings live in its own catalogue.
  use Gettext, backend: PhoenixKitKnowledgeBase.Gettext

  # Not in core's default imports — `use PhoenixKitWeb, :live_view` brings in
  # `Components.Core.*` only, so the folder explorer has to be asked for.
  import PhoenixKitWeb.Components.FolderExplorer

  alias PhoenixKit.Users.Auth.Scope

  alias PhoenixKitKnowledgeBase.{
    Errors,
    Events,
    Links,
    Markdown,
    Notes,
    Paths,
    Rescan,
    Storage,
    Vaults
  }

  alias PhoenixKitKnowledgeBase.Schemas.Note

  # Prefix only. The live id is per-note (`editor_id/1`) — see there for why
  # that is load-bearing rather than cosmetic.
  @editor_id_prefix "kb-note-editor"

  # Inline-suggestion triggers handed to Leaf. `min_chars: 0` so a bare `[[`
  # already lists recent notes, and `allow_create` so a link can be written to
  # a note that does not exist yet — which is how a vault grows.
  @suggestion_configs [
    %{
      trigger: "[[",
      boundary: :any,
      # Leaf's default token is `[\\p{L}\\p{N}_-]`, which closes the popup on the
      # first space — `Attention Is All You Need` would never complete. A link
      # target may hold anything the parser accepts, and `@wiki_link_regex` in
      # `Markdown` is `[^\\[\\]\\n]+`: spaces, `/` for `[[folder/Note]]`, `#` for
      # a heading anchor and `|` for an alias all have to keep the popup open.
      # Matching that class exactly is the point — a token looser than the
      # parser suggests links the parser will not read back.
      token: "[^\\[\\]\\n]",
      min_chars: 0,
      max_length: 200,
      allow_create: true,
      keep_trigger: true,
      insert_suffix: "]]"
    },
    %{
      trigger: "#",
      # `#` at the first column opens a heading; only mid-line does it mean a
      # tag. This is the setting that stops the two fighting over a keystroke.
      boundary: :not_line_start,
      # The default token minus nothing plus `/`, so nested tags like
      # `#project/alpha` complete. Mirrors `@inline_tag_regex` in `Markdown`.
      token: "[\\p{L}\\p{N}_/-]",
      min_chars: 0,
      max_length: 60,
      allow_create: true,
      keep_trigger: true
    }
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:vault, nil)
     |> assign(:role, nil)
     |> assign(:note, nil)
     |> assign(:content, "")
     |> assign(:save_status, :saved)
     |> assign(:selected_folder, :any)
     |> assign(:rescan_report, nil)
     |> assign(:conflict, false)
     |> assign(:remote_change, false)
     |> assign(:trash_open, false)
     |> assign(:trash, [])
     |> assign(:selected_tag, nil)
     |> assign(:search_query, "")
     |> assign(:search_results, nil)
     |> assign(:adding_folder, false)
     # Core's FolderExplorer state. `expanded_folders` holds folder uuids, not
     # paths — that is the component's contract, and it is what its own
     # `active_path_uuids/2` walks.
     |> assign(:expanded_folders, MapSet.new())
     |> assign(:sidebar_collapsed, false)
     # Phone only: whether the sidebar is shown over an open note. Below `lg`
     # the sidebar stacks above the note and pushed the editor off the first
     # screen, so with a note open it waits behind the "Files" button.
     |> assign(:files_open, false)
     |> assign(:renaming_folder, nil)
     |> assign(:renaming_source, nil)
     |> assign(:renaming_text, "")
     |> assign(:new_title, "")
     |> assign(:note_error, nil)
     |> assign(:can_write, false)
     |> assign(:can_manage, false)
     |> assign(:folder_tree, [])
     |> assign(:folders, [])
     |> assign(:notes, [])
     |> assign(:tree_items, %{})
     |> assign(:tags, [])
     |> assign(:unresolved, [])
     |> assign(:note_count, 0)
     |> assign(:backlinks, [])
     |> assign(:outgoing, [])}
  end

  @impl true
  def handle_params(%{"vault" => slug} = params, _uri, socket) do
    case Vaults.fetch_for(slug, socket.assigns.phoenix_kit_current_scope) do
      {:error, :not_found} ->
        # One message for "no such vault" and "not yours" — distinguishing them
        # would confirm the existence of other people's vaults.
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("That vault does not exist, or you do not have access to it.")
         )
         |> push_navigate(to: Paths.vaults())}

      {:ok, vault, role} ->
        maybe_subscribe(socket, vault)

        {:noreply,
         socket
         |> assign(:vault, vault)
         |> assign(:role, role)
         |> assign(:can_write, Vaults.can?(role, :write))
         |> assign(:can_manage, Vaults.can?(role, :manage))
         # Core's admin bar draws the trail and, beside it, this page's actions.
         |> assign(:page_section, gettext("Knowledge Base"))
         |> assign(:page_section_path, Paths.vaults())
         |> assign(:page_toolbar, {__MODULE__, :header_toolbar})
         |> load_workspace()
         # Opening a note (or the new-note form) from the phone sidebar is
         # the end of using it; put it away so the note is what shows.
         |> assign(:files_open, false)
         |> apply_action(socket.assigns.live_action, params)
         |> assign_trail()}
    end
  end

  # "Knowledge Base / <vault>" with no note open; "Knowledge Base / <vault> /
  # <note>" with one — the vault a crumb that patches back to it, since it is
  # this same LiveView. Re-run whenever the open note or its title changes.
  defp assign_trail(%{assigns: %{vault: vault}} = socket) do
    {crumbs, title} =
      cond do
        socket.assigns.note ->
          {[%{label: vault.name, patch: Paths.vault(vault.slug)}], socket.assigns.note.title}

        socket.assigns.live_action == :new ->
          {[%{label: vault.name, patch: Paths.vault(vault.slug)}], gettext("New note")}

        true ->
          {[], vault.name}
      end

    socket
    |> assign(:page_crumbs, crumbs)
    |> assign(:page_title, title)
  end

  # `handle_params` runs on every patch, so subscribing there would stack a
  # subscription per note click. Guarded on the vault actually changing, and on
  # the socket being connected — the dead render has no process to deliver to.
  defp maybe_subscribe(socket, vault) do
    if connected?(socket) and socket.assigns[:vault] != vault do
      Events.subscribe(vault.uuid)
    end

    :ok
  end

  # ── Actions ───────────────────────────────────────────────────────────────

  defp apply_action(socket, :index, _params) do
    assign(socket, :note, nil)
  end

  defp apply_action(socket, :show, %{"id" => id}) do
    case Notes.get_note(socket.assigns.vault.uuid, id) do
      nil ->
        socket
        |> put_flash(:error, gettext("That note no longer exists."))
        |> push_patch(to: Paths.vault(socket.assigns.vault.slug))

      note ->
        open_note(socket, note)
    end
  end

  defp apply_action(socket, :new, params) do
    title = params["title"] || ""

    # An unresolved link someone else has since written should just open the
    # note, not offer to create a duplicate that the unique index would reject.
    case Notes.get_note_by_title(socket.assigns.vault.uuid, title) do
      nil ->
        socket
        |> assign(:note, nil)
        |> assign(:new_title, title)
        |> assign(:note_error, nil)

      existing ->
        push_patch(socket, to: Paths.note(socket.assigns.vault.slug, existing.uuid))
    end
  end

  defp open_note(socket, %Note{} = note) do
    socket
    |> assign(:note, note)
    |> assign(:content, note.content || "")
    |> assign(:save_status, :saved)
    |> assign(:conflict, false)
    |> assign(:remote_change, false)
    |> assign_note_links()
  end

  # ── Events: navigation and filtering ──────────────────────────────────────

  @impl true
  def handle_event("select_tag", %{"tag" => tag}, socket) do
    tag = if tag == socket.assigns.selected_tag, do: nil, else: tag
    {:noreply, socket |> assign(:selected_tag, tag) |> load_notes()}
  end

  def handle_event("search", %{"value" => query}, socket) do
    {:noreply, run_search(socket, query)}
  end

  def handle_event("search", %{"query" => query}, socket) do
    {:noreply, run_search(socket, query)}
  end

  def handle_event("clear_search", _params, socket) do
    {:noreply, socket |> assign(:search_query, "") |> assign(:search_results, nil)}
  end

  # ── Events: notes ─────────────────────────────────────────────────────────

  def handle_event("create_note", %{"title" => title}, socket) do
    with :ok <- require_write(socket),
         {:ok, folder_path, title} <- place_new_note(title, folder_for_new_note(socket)),
         attrs = %{"title" => title, "content" => "", "folder_path" => folder_path},
         {:ok, note} <- Notes.create_note(socket.assigns.vault, attrs, actor_uuid(socket)) do
      {:noreply,
       socket
       |> assign(:note_error, nil)
       |> load_workspace()
       |> push_patch(to: Paths.note(socket.assigns.vault.slug, note.uuid))}
    else
      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, read_only_message())}

      {:error, reason} ->
        {:noreply, assign(socket, :note_error, error_message(reason))}
    end
  end

  def handle_event("rename_note", %{"title" => title}, socket) do
    %{note: note} = socket.assigns

    cond do
      # The title input is `readonly` for a viewer, but readonly is a property of
      # a DOM node, not a permission — a hand-sent `phx-blur` reaches this
      # handler regardless. Every other mutating event gates on `require_write`;
      # this one was the hole.
      require_write(socket) != :ok ->
        {:noreply, socket}

      is_nil(note) ->
        {:noreply, socket}

      String.trim(title) in ["", note.title] ->
        {:noreply, socket}

      true ->
        case Notes.rename_note(socket.assigns.vault, note, title, actor_uuid: actor_uuid(socket)) do
          {:ok, updated} ->
            {:noreply,
             socket
             |> assign(:note, updated)
             |> assign(:note_error, nil)
             |> assign(:conflict, false)
             |> load_workspace()
             |> assign_note_links()
             |> assign_trail()}

          {:error, reason} ->
            {:noreply, assign(socket, :note_error, error_message(reason))}
        end
    end
  end

  # `phx-blur` reports the field as "value"; the form submit reports it as
  # "title". Both mean "rename this note".
  def handle_event("rename_note", %{"value" => title}, socket) do
    handle_event("rename_note", %{"title" => title}, socket)
  end

  def handle_event("delete_note", _params, socket) do
    %{note: note, vault: vault} = socket.assigns

    with :ok <- require_write(socket),
         false <- is_nil(note),
         {:ok, _} <- Notes.delete_note(vault, note) do
      {:noreply,
       socket
       |> put_flash(:info, gettext("Note moved to the trash."))
       |> assign(:note, nil)
       |> load_workspace()
       |> push_patch(to: Paths.vault(vault.slug))}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Could not delete that note."))}
    end
  end

  # The select only offers indexed folders, but the event carries a path and a
  # hand-sent one would otherwise be created on the way (`Storage.move_note/3`
  # makes the target's directory) — named however the sender liked, past
  # `Storage.validate_filename/1`. Only a folder the index already has is a
  # destination.
  def handle_event("move_note", %{"folder" => folder}, socket) do
    with :ok <- require_write(socket),
         {:ok, folder_path} <- existing_folder_path(socket, folder),
         %Note{} = note <- socket.assigns.note,
         {:ok, updated} <-
           Notes.move_note(socket.assigns.vault, note, folder_path,
             actor_uuid: actor_uuid(socket)
           ) do
      {:noreply, socket |> assign(:note, updated) |> assign(:conflict, false) |> load_workspace()}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, error_message(reason))}
      _ -> {:noreply, put_flash(socket, :error, gettext("Could not move that note."))}
    end
  end

  # ── Events: folders ───────────────────────────────────────────────────────

  def handle_event("create_folder", %{"name" => name}, socket) do
    parent =
      if is_binary(socket.assigns.selected_folder), do: socket.assigns.selected_folder, else: ""

    with :ok <- require_write(socket),
         {:ok, _folder} <- Notes.create_folder(socket.assigns.vault, parent, name) do
      {:noreply, socket |> assign(:adding_folder, false) |> load_workspace()}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def handle_event("delete_folder", %{"uuid" => uuid}, socket) do
    # Deleting a directory takes its files with it — unlike the database-backed
    # model, there is nowhere for the notes inside to survive to. The confirm
    # dialog says so.
    with :ok <- require_write(socket),
         %{} = folder <- Notes.get_folder(socket.assigns.vault.uuid, uuid),
         {:ok, removed} <- Notes.delete_folder(socket.assigns.vault, folder) do
      {:noreply,
       socket
       |> put_flash(:info, folder_trashed_message(folder, removed))
       |> assign(:selected_folder, :any)
       |> assign(:note, nil)
       |> load_workspace()
       |> push_patch(to: Paths.vault(socket.assigns.vault.slug))}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Could not delete that folder."))}
    end
  end

  # ── Events: trash ─────────────────────────────────────────────────────────

  def handle_event("toggle_trash", _params, socket) do
    open? = not socket.assigns.trash_open

    {:noreply,
     socket
     |> assign(:trash_open, open?)
     |> assign(:trash, if(open?, do: Notes.list_trash(socket.assigns.vault), else: []))}
  end

  def handle_event("restore_note", %{"path" => trash_path}, socket) do
    with :ok <- require_write(socket),
         %{} = entry <- find_trash_entry(socket, trash_path),
         {:ok, note} <- Notes.restore_note(socket.assigns.vault, entry) do
      {:noreply,
       socket
       |> put_flash(:info, gettext("Restored “%{title}”.", title: note.title))
       |> assign(:trash, Notes.list_trash(socket.assigns.vault))
       |> load_workspace()
       |> push_patch(to: Paths.note(socket.assigns.vault.slug, note.uuid))}
    else
      {:error, :target_exists} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("A note already exists at that path. Rename or move it, then restore again.")
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Could not restore that note."))}
    end
  end

  def handle_event("purge_note", %{"path" => trash_path}, socket) do
    with :ok <- require_write(socket),
         %{} = entry <- find_trash_entry(socket, trash_path),
         :ok <- Notes.purge_trash(socket.assigns.vault, entry) do
      {:noreply,
       socket
       |> put_flash(:info, gettext("Deleted permanently."))
       |> assign(:trash, Notes.list_trash(socket.assigns.vault))}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Could not delete that permanently."))}
    end
  end

  def handle_event("empty_trash", _params, socket) do
    with :ok <- require_write(socket),
         :ok <- Notes.empty_trash(socket.assigns.vault) do
      {:noreply, socket |> put_flash(:info, gettext("Trash emptied.")) |> assign(:trash, [])}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Could not empty the trash."))}
    end
  end

  # ── Events: core's folder explorer ────────────────────────────────────────
  #
  # These names are MediaBrowser's, because the component was written for it and
  # does not let a consumer rename them. Implementing its vocabulary is cheaper
  # than changing core, and it keeps the two consumers speaking one language.

  def handle_event("navigate_folder", %{"folder-uuid" => uuid}, socket) do
    case folder_path_for(socket, uuid) do
      nil -> {:noreply, socket}
      path -> {:noreply, select_folder_path(socket, path)}
    end
  end

  def handle_event("navigate_root", _params, socket) do
    {:noreply, select_folder_path(socket, "")}
  end

  def handle_event("navigate_view_all", _params, socket) do
    {:noreply, select_folder_path(socket, :any)}
  end

  def handle_event("toggle_folder_expand", %{"folder-uuid" => uuid}, socket) do
    expanded = socket.assigns.expanded_folders

    expanded =
      if MapSet.member?(expanded, uuid),
        do: MapSet.delete(expanded, uuid),
        else: MapSet.put(expanded, uuid)

    {:noreply, assign(socket, :expanded_folders, expanded)}
  end

  def handle_event("toggle_files", _params, socket) do
    {:noreply, assign(socket, :files_open, not socket.assigns.files_open)}
  end

  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, :sidebar_collapsed, not socket.assigns.sidebar_collapsed)}
  end

  def handle_event("open_new_folder_modal", _params, socket) do
    {:noreply, assign(socket, :adding_folder, not socket.assigns.adding_folder)}
  end

  def handle_event("toggle_trash_filter", _params, socket) do
    handle_event("toggle_trash", %{}, socket)
  end

  # ── Events: folder rename ─────────────────────────────────────────────────

  def handle_event("start_rename_folder", %{"folder-uuid" => uuid} = params, socket) do
    if require_write(socket) == :ok do
      {:noreply,
       socket
       |> assign(:renaming_folder, uuid)
       |> assign(:renaming_source, params["source"])
       |> assign(:renaming_text, folder_name_for(socket, uuid))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("rename_folder_input", %{"name" => name}, socket) do
    {:noreply, assign(socket, :renaming_text, name)}
  end

  def handle_event("cancel_rename_folder", _params, socket) do
    {:noreply, cancel_rename(socket)}
  end

  def handle_event("rename_folder", %{"folder_uuid" => uuid, "name" => name}, socket) do
    # A rename is a move to a sibling path: same parent, new last segment. One
    # operation on the filesystem, so one operation here.
    with :ok <- require_write(socket),
         %{} = folder <- Notes.get_folder(socket.assigns.vault.uuid, uuid),
         {:ok, target} <- sibling_path(folder.relative_path, name),
         {:ok, _moved} <- Notes.relocate_folder(socket.assigns.vault, folder, target) do
      {:noreply, socket |> cancel_rename() |> reselect_folder(folder.relative_path, target)}
    else
      {:error, :unchanged} -> {:noreply, cancel_rename(socket)}
      {:error, reason} -> {:noreply, rename_failed(socket, reason)}
      _ -> {:noreply, rename_failed(socket, :not_found)}
    end
  end

  # ── Events: drag and drop ─────────────────────────────────────────────────
  #
  # Pushed by core's `MediaDragDrop` hook, which this module gets for free by
  # naming it in `phx-hook` — it ships no JavaScript of its own.

  def handle_event("move_file_to_folder", %{"file_uuid" => note_uuid} = params, socket) do
    with :ok <- require_write(socket),
         # The hook names the drop target by uuid; `move_note/4` takes a path.
         # Passing the uuid through creates a directory *named* with the uuid.
         {:ok, folder_path} <- drop_target_path(socket, params["folder_uuid"]),
         %Note{} = note <- Notes.get_note(socket.assigns.vault.uuid, note_uuid),
         {:ok, _moved} <-
           Notes.move_note(socket.assigns.vault, note, folder_path,
             actor_uuid: actor_uuid(socket)
           ) do
      {:noreply, socket |> load_workspace() |> refresh_open_note() |> assign_note_links()}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Could not move that note."))}
    end
  end

  def handle_event("move_folder_to_folder", %{"folder_uuid" => uuid} = params, socket) do
    target_parent = Map.get(params, "target_uuid", "")

    with :ok <- require_write(socket),
         %{} = folder <- Notes.get_folder(socket.assigns.vault.uuid, uuid),
         {:ok, parent_path} <- drop_target_path(socket, target_parent),
         target <- Path.join(parent_path, folder.name),
         {:ok, _moved} <- Notes.relocate_folder(socket.assigns.vault, folder, target) do
      {:noreply, reselect_folder(socket, folder.relative_path, target)}
    else
      {:error, :unchanged} -> {:noreply, socket}
      {:error, reason} -> {:noreply, put_flash(socket, :error, move_error(reason))}
      _ -> {:noreply, put_flash(socket, :error, gettext("Could not move that folder."))}
    end
  end

  # The tree opens a note through a `<.link patch>`; the context menu cannot
  # (its items' hrefs are fixed at render time, only `phx-value-*` varies per
  # row), so "Open" patches from here instead.
  def handle_event("open_note", %{"file_uuid" => note_uuid}, socket) do
    {:noreply, push_patch(socket, to: Paths.note(socket.assigns.vault.slug, note_uuid))}
  end

  def handle_event("trash_file", %{"file_uuid" => note_uuid}, socket) do
    with :ok <- require_write(socket),
         %Note{} = note <- Notes.get_note(socket.assigns.vault.uuid, note_uuid),
         {:ok, _} <- Notes.delete_note(socket.assigns.vault, note) do
      socket =
        if socket.assigns.note && socket.assigns.note.uuid == note_uuid do
          socket
          |> assign(:note, nil)
          |> push_patch(to: Paths.vault(socket.assigns.vault.slug))
        else
          socket
        end

      {:noreply,
       socket |> put_flash(:info, gettext("Note moved to the trash.")) |> load_workspace()}
    else
      _ ->
        {:noreply, put_flash(socket, :error, gettext("Could not move that note to the trash."))}
    end
  end

  def handle_event("trash_folder", %{"folder_uuid" => uuid}, socket) do
    with :ok <- require_write(socket),
         %{} = folder <- Notes.get_folder(socket.assigns.vault.uuid, uuid),
         {:ok, removed} <- Notes.delete_folder(socket.assigns.vault, folder) do
      {:noreply,
       socket
       |> put_flash(:info, folder_trashed_message(folder, removed))
       |> assign(:selected_folder, :any)
       |> assign(:note, nil)
       |> load_workspace()
       |> push_patch(to: Paths.vault(socket.assigns.vault.slug))}
    else
      _ ->
        {:noreply, put_flash(socket, :error, gettext("Could not move that folder to the trash."))}
    end
  end

  # Core's hook also speaks a multi-select vocabulary — a long press selects,
  # and dragging a selected item moves or deletes the whole selection. This
  # module has no selection, so these are acknowledged and dropped. They must
  # still be *matched*: an unhandled `handle_event/3` is a FunctionClauseError,
  # which takes the LiveView down and loses whatever is in the editor.
  def handle_event(event, _params, socket)
      when event in ~w(move_selected_to_folder delete_selected long_press_select) do
    {:noreply, socket}
  end

  # ── Events: rescan ────────────────────────────────────────────────────────

  # Gated on write, not because a rescan changes a file — it does not — but
  # because it walks and hashes the whole vault inside this LiveView process. An
  # ungated button lets a viewer hold the process for the length of a vault
  # scan, repeatedly.
  def handle_event("rescan", _params, socket) do
    if require_write(socket) == :ok do
      run_rescan(socket)
    else
      {:noreply, put_flash(socket, :error, gettext("You do not have permission to rescan."))}
    end
  end

  def handle_event("dismiss_rescan", _params, socket) do
    {:noreply, assign(socket, :rescan_report, nil)}
  end

  def handle_event("overwrite_note", _params, socket) do
    # The only path that passes `force: true`. It exists so overwriting somebody
    # else's work is something you choose, rather than something that happens
    # because you kept typing.
    {:noreply,
     socket
     |> assign(:conflict, false)
     |> save_content(socket.assigns.content, force: true)}
  end

  def handle_event("dismiss_remote_change", _params, socket) do
    {:noreply, assign(socket, :remote_change, false)}
  end

  def handle_event("reload_note", _params, socket) do
    {:noreply,
     socket
     |> assign(:conflict, false)
     |> assign(:remote_change, false)
     |> reload_open_note()}
  end

  # Re-read the listing rather than trusting the path that came back from the
  # click: a stale page must not be able to name an arbitrary path for restore
  # or purge.
  defp find_trash_entry(socket, trash_path) do
    socket.assigns.vault
    |> Notes.list_trash()
    |> Enum.find(&(&1.trash_path == trash_path))
  end

  # ── Peer changes ──────────────────────────────────────────────────────────

  @impl true
  def handle_info({:kb_note_saved, payload}, socket) do
    cond do
      # Our own write coming back around. Without this, the browser that just
      # saved would be told its note changed and offered to reload it from
      # itself.
      Events.own?(payload) ->
        {:noreply, socket}

      # Somebody saved the bytes we already have — a rescan re-stamping an
      # mtime, a peer saving an identical buffer, or a rename or move, which
      # keeps the bytes and changes the path. Nothing to show, but the row is
      # taken: `save_content/3` writes against `@note.relative_path`, and after
      # a rename elsewhere that is a file that no longer exists — the next
      # keystroke would raise a conflict over a change nobody made to the text.
      socket.assigns.note && payload.note_uuid == socket.assigns.note.uuid &&
          payload.hash == socket.assigns.note.content_hash ->
        {:noreply, socket |> follow_open_note() |> assign_trail()}

      socket.assigns.note && payload.note_uuid == socket.assigns.note.uuid ->
        {:noreply, apply_remote_note_change(socket)}

      # A different note in this vault: the sidebar, backlinks and unresolved
      # list can all have moved, but nothing the reader is typing into has.
      true ->
        {:noreply, socket |> load_sidebar_counts() |> load_notes() |> assign_note_links()}
    end
  end

  def handle_info({:kb_note_deleted, payload}, socket) do
    cond do
      Events.own?(payload) ->
        {:noreply, socket}

      socket.assigns.note && payload.note_uuid == socket.assigns.note.uuid ->
        {:noreply,
         socket
         |> assign(:note, nil)
         |> put_flash(:info, "This note was deleted by someone else.")
         |> load_workspace()
         |> push_patch(to: Paths.vault(socket.assigns.vault.slug))}

      true ->
        {:noreply, socket |> load_workspace() |> assign_note_links()}
    end
  end

  def handle_info({:kb_vault_changed, payload}, socket) do
    if Events.own?(payload) do
      {:noreply, socket}
    else
      # A folder move elsewhere re-indexes the notes under it without a
      # per-note message (`Notes.relocate_folder/3`), and a rescan may have
      # recognised an external `mv` of the open note — either way only this
      # message says so, and the open row may now name a path that is gone.
      {:noreply,
       socket
       |> load_workspace()
       |> assign(
         :trash,
         if(socket.assigns.trash_open, do: Notes.list_trash(socket.assigns.vault), else: [])
       )
       |> follow_open_note()
       |> assign_trail()}
    end
  end

  # ── Editor messages ──────────────────────────────────────────────────────

  # A live-editing session can no longer save: the file moved underneath it. This
  # is the only warning that exists — Leaf's room records the conflict, stops
  # writing and tells nobody — so it is shown to everyone in the vault,
  # including whoever caused it, and deliberately does not check `own?`.
  def handle_info({:kb_note_conflict, %{note_uuid: note_uuid}}, socket) do
    if socket.assigns.note && socket.assigns.note.uuid == note_uuid do
      {:noreply, assign(socket, :conflict, true)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:leaf_changed, %{markdown: markdown} = payload}, socket) do
    case save_decision(payload, socket.assigns.note, socket.assigns.content) do
      :save -> {:noreply, socket |> assign(:content, markdown) |> save_content(markdown)}
      # `:stale` is an edit from a note that is no longer open; `:unchanged` is
      # Leaf reporting a buffer that still matches what it loaded. Both are
      # dropped — see `save_decision/3`.
      _ -> {:noreply, socket}
    end
  end

  # Hybrid ↔ markdown. Nothing to do, but an unmatched `handle_info` would take
  # the LiveView down with the editor sitting right there.
  def handle_info({:leaf_mode_changed, _payload}, socket), do: {:noreply, socket}

  # Leaf asks the host what a trigger should offer. Two rules from its docs
  # matter: echo `trigger`, `query` and `seq` back unchanged so the client can
  # discard a reply a later keystroke superseded, and never block — a host that
  # does not answer just gets a popup that closes itself.
  def handle_info(
        {:leaf_suggest, %{editor_id: id, trigger: "[[", query: query, seq: seq}},
        socket
      ) do
    reply_suggestions(id, "[[", query, seq, note_suggestions(socket, query))
    {:noreply, socket}
  end

  def handle_info({:leaf_suggest, %{editor_id: id, trigger: "#", query: query, seq: seq}}, socket) do
    reply_suggestions(id, "#", query, seq, tag_suggestions(socket, query))
    {:noreply, socket}
  end

  # An unconfigured trigger still deserves an answer, or the popup sits
  # spinning until it times out.
  def handle_info(
        {:leaf_suggest, %{editor_id: id, trigger: trigger, query: query, seq: seq}},
        socket
      ) do
    reply_suggestions(id, trigger, query, seq, [])
    {:noreply, socket}
  end

  # The image/video toolbar buttons. Leaf ≥ 0.10 draws them only when the host
  # lists them in `toolbar`, and this page lists none — there is no upload path
  # — so this should not arrive; it is matched so that an older Leaf's button
  # cannot crash the LiveView.
  def handle_info({:leaf_insert_request, _payload}, socket), do: {:noreply, socket}

  # Leaf has found `[[…]]` targets on screen and wants to know which of them
  # exist. Only this module knows that, so the resolution rules that already
  # govern the stored link index answer here too — same resolver, same
  # same-folder tie-break — or a link would render as pointing somewhere the
  # backlinks panel disagrees with.
  #
  # Answered only for the open note's editor: the tie-break is relative to the
  # linking note's folder, so a request from an editor that is no longer open
  # would be resolved against the wrong folder. `seq` is echoed so the client
  # can drop an answer a later edit superseded.
  def handle_info({:leaf_resolve_links, %{editor_id: id, targets: targets, seq: seq}}, socket) do
    if socket.assigns.note && id == editor_id(socket.assigns.note) do
      send_update(Leaf,
        id: id,
        action: :link_targets,
        seq: seq,
        targets: resolve_link_targets(socket, targets)
      )
    end

    {:noreply, socket}
  end

  # A `[[wiki-link]]` was clicked. Leaf deliberately does not navigate — where a
  # target lives is our question, and an unresolved one goes to the create page
  # rather than nowhere.
  #
  # The target is re-resolved rather than trusting the `href` that came back:
  # that value was rendered into a page which may be stale, and the same rule
  # applies here as in `find_trash_entry/2` — a page must not be able to name
  # the destination.
  def handle_info({:leaf_link_clicked, %{target: target}}, socket) do
    vault = socket.assigns.vault
    from_folder = (socket.assigns.note && socket.assigns.note.folder_path) || ""

    path =
      case Links.resolve(Links.resolver(vault.uuid), link_key(target), from_folder) do
        nil -> Paths.new_note(vault.slug, target)
        note -> Paths.note(vault.slug, note.uuid)
      end

    {:noreply, push_patch(socket, to: path)}
  end

  # A floor under every message that reaches this process. Leaf adds messages
  # between versions, `Leaf.Collab` sends several more, and an unmatched
  # `handle_info/2` takes the LiveView down with the editor sitting right
  # there — which is a worse outcome than ignoring something we do not
  # understand. Logged rather than silent, so a new message is discoverable
  # instead of merely absent.
  #
  # Placed after every real clause: it matches anything.
  def handle_info(message, socket) do
    require Logger

    Logger.debug(
      "[knowledge_base] unhandled message in VaultLive: #{inspect(message, limit: 5, printable_limit: 100)}"
    )

    {:noreply, socket}
  end

  # A peer changed the note on screen. There is only one surface now and it may
  # hold unsaved keystrokes, so the change is announced and never applied behind
  # the author's back — `remote_change` raises the banner, the reload is theirs
  # to ask for.
  #
  # `@note` is deliberately **not** replaced. Its `content_hash` is what the
  # buffer was loaded from, and it is what the stale guard compares the file
  # against. Taking the peer's row here (an earlier version did) armed the guard
  # with *their* hash: the next keystroke saw the file "current" and wrote over
  # their save — the one thing the banner exists to stop. Left alone, that
  # keystroke is refused as `:stale` and the choice goes to the person.
  defp apply_remote_note_change(socket), do: assign(socket, :remote_change, true)

  # The open note's row, re-read after something elsewhere may have moved it —
  # but only taken while it still describes the bytes the buffer came from. A
  # different hash is a change to the text, which is announced instead (see
  # `apply_remote_note_change/1`); a vanished row is left to the deletion
  # message, or to the next save's `:missing_file`.
  defp follow_open_note(%{assigns: %{note: nil}} = socket), do: socket

  defp follow_open_note(%{assigns: %{note: note}} = socket) do
    case Notes.get_note(socket.assigns.vault.uuid, note.uuid) do
      %Note{content_hash: hash} = fresh when hash == note.content_hash ->
        assign(socket, :note, fresh)

      %Note{} ->
        apply_remote_note_change(socket)

      nil ->
        socket
    end
  end

  defp reply_suggestions(editor_id, trigger, query, seq, results) do
    send_update(Leaf,
      id: editor_id,
      action: :suggestions,
      trigger: trigger,
      query: query,
      seq: seq,
      results: results
    )
  end

  # One resolver for the whole batch — a document full of `[[…]]` must not cost
  # a query per link.
  defp resolve_link_targets(socket, targets) do
    vault = socket.assigns.vault
    from_folder = (socket.assigns.note && socket.assigns.note.folder_path) || ""

    link_targets(
      Links.resolver(vault.uuid),
      vault.slug,
      from_folder,
      targets,
      socket.assigns.can_write
    )
  end

  @doc false
  # `%{target => %{href:, exists:, title:}}`, which is what Leaf decorates a
  # `[[…]]` with. Takes a prebuilt resolver rather than a vault, so what a link
  # renders as can be tested without a database — the same split as
  # `Links.resolve/3`.
  @spec link_targets(map(), String.t(), String.t(), [String.t()], boolean()) :: map()
  def link_targets(resolver, slug, from_folder, targets, can_write? \\ true) do
    Map.new(targets, fn target ->
      key = link_key(target)

      case Links.resolve(resolver, key, from_folder) do
        nil ->
          {target,
           %{
             href: Paths.new_note(slug, target),
             exists: false,
             # Leaf ships no wording for an unresolved target on purpose — it
             # is ours to write, about our own idea of what a target is.
             title: missing_title(can_write?)
           }}

        note ->
          {target,
           %{
             href: Paths.note(slug, note.uuid),
             exists: true,
             title: link_title(resolver, key, note, can_write?)
           }}
      end
    end)
  end

  # A link whose bare title several notes answer to still resolves, but the
  # author deserves to be told it was guessed at, and which way.
  #
  # The destination rides along because this tooltip is the only thing attached
  # to the link itself, and it is where somebody puzzled by a link will look.
  defp link_title(resolver, key, note, _can_write?) do
    case Links.candidate_count(resolver, key) do
      count when count > 1 ->
        gettext("%{count} notes share this title — this link resolves to %{path}",
          count: count,
          path: note.relative_path
        )

      _ ->
        note.relative_path
    end
  end

  defp missing_title(true), do: gettext("No note with this title yet — click to create it")
  defp missing_title(false), do: gettext("No note with this title yet")

  # Leaf sends the bare target: the heading anchor and the alias arrive as
  # separate fields and are already stripped. Normalising it is what makes
  # "My  Note", "my note" and " My Note " the same note, and it is the same
  # key the stored link index uses.
  defp link_key(target), do: Markdown.normalize_title(target)

  defp select_folder_path(socket, selected) do
    socket |> assign(:selected_folder, selected) |> assign(:selected_tag, nil) |> load_notes()
  end

  defp cancel_rename(socket) do
    socket
    |> assign(:renaming_folder, nil)
    |> assign(:renaming_source, nil)
    |> assign(:renaming_text, "")
  end

  defp rename_failed(socket, reason) do
    socket |> cancel_rename() |> put_flash(:error, move_error(reason))
  end

  defp folder_name_for(socket, uuid) do
    case Notes.get_folder(socket.assigns.vault.uuid, uuid) do
      nil -> ""
      folder -> folder.name
    end
  end

  # A rename keeps the parent and replaces the last segment. The name goes
  # through the same validation a note title does — a folder is a directory, and
  # the characters that break a path or a `[[link]]` break it here too.
  defp sibling_path(relative_path, name) do
    with {:ok, clean} <- Storage.validate_filename(name) do
      case Path.dirname(relative_path) do
        "." -> {:ok, clean}
        parent -> {:ok, Path.join(parent, clean)}
      end
    end
  end

  # Core's drag-drop hook names every drop target by folder uuid, and resolves
  # the vault root to "" before it gets here. Everything in this module names a
  # folder by its path. This is the one place the two meet, and both drop
  # handlers go through it — passing a uuid on to `Notes.move_note/4` or
  # `relocate_folder/3` does not fail, it creates a directory *named* with the
  # uuid, which is how that shipped once.
  defp drop_target_path(_socket, target) when target in [nil, "", "root"], do: {:ok, ""}

  defp drop_target_path(socket, uuid) do
    case folder_path_for(socket, uuid) do
      nil -> {:error, :not_found}
      path -> {:ok, path}
    end
  end

  # Keep the selection on the folder that just moved rather than dropping the
  # user back to the whole vault.
  defp reselect_folder(socket, from, to) do
    socket =
      if socket.assigns.selected_folder == from,
        do: assign(socket, :selected_folder, to),
        else: socket

    socket |> load_workspace() |> refresh_open_note() |> assign_note_links()
  end

  # Re-read the open note's row after something moved it. Only the row: the
  # buffer on screen is unchanged and must not be touched, which is what
  # separates this from `reload_open_note/1`.
  #
  # Without it `@note.relative_path` still names the old file, `save_content/3`
  # writes against a path that is gone, and every autosave is refused with "this
  # note's file is gone from disk" until the reader navigates away. The
  # `kb_note_saved` broadcast cannot rescue it either — it comes from this same
  # pid, so `Events.own?/1` drops it.
  defp refresh_open_note(%{assigns: %{note: nil}} = socket), do: socket

  defp refresh_open_note(socket) do
    case Notes.get_note(socket.assigns.vault.uuid, socket.assigns.note.uuid) do
      nil -> socket
      note -> assign(socket, :note, note)
    end
  end

  defp move_error(reason), do: error_message(reason)

  # A path-qualified title (`research/Ideas`, which is how an unresolved
  # `[[research/Ideas]]` arrives on the create page) is a note in that folder,
  # named by its last segment. A path-qualified link names its path from the
  # vault root, so the folder replaces the selected one rather than nesting in
  # it. Every segment passes the same check a typed name does; the folder is
  # created on the way if it does not exist yet.
  @doc false
  @spec place_new_note(String.t(), String.t()) ::
          {:ok, String.t(), String.t()} | {:error, term()}
  def place_new_note(title, default_folder) when is_binary(title) do
    case title |> String.split("/") |> Enum.map(&String.trim/1) do
      [single] ->
        {:ok, default_folder, single}

      segments ->
        case validate_segments(segments) do
          {:ok, [name | folders]} -> {:ok, folders |> Enum.reverse() |> Path.join(), name}
          error -> error
        end
    end
  end

  def place_new_note(_title, _default_folder), do: {:error, :blank}

  # Every segment, reversed (the name first), or the first refusal.
  defp validate_segments(segments) do
    Enum.reduce_while(segments, {:ok, []}, fn segment, {:ok, acc} ->
      case Storage.validate_filename(segment) do
        {:ok, clean} -> {:cont, {:ok, [clean | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  # `"root"` or a folder the index already holds — nothing else is a place a
  # note may be moved to (see the `move_note` event).
  defp existing_folder_path(_socket, folder) when folder in ["root", ""], do: {:ok, ""}

  defp existing_folder_path(socket, folder) do
    if Enum.any?(socket.assigns.folders, &(&1.relative_path == folder)),
      do: {:ok, folder},
      else: {:error, :not_found}
  end

  defp folder_trashed_message(folder, removed) do
    ngettext(
      "Moved “%{name}” and %{count} note in it to the trash.",
      "Moved “%{name}” and %{count} notes in it to the trash.",
      removed,
      name: folder.name
    )
  end

  defp read_only_message, do: gettext("You have read-only access to this vault.")

  # The explorer wants the Folder struct for the selected path, or nil for the
  # root and the all-notes view — it reads `.uuid` off it and compares.
  defp current_folder(_folders, :any), do: nil
  defp current_folder(_folders, ""), do: nil

  defp current_folder(folders, path) when is_binary(path) do
    Enum.find(folders, &(&1.relative_path == path))
  end

  defp current_folder(_folders, _selected), do: nil

  # The explorer names folders by uuid; everything else here names them by path.
  defp folder_path_for(socket, uuid) do
    case Notes.get_folder(socket.assigns.vault.uuid, uuid) do
      nil -> nil
      folder -> folder.relative_path
    end
  end

  defp note_suggestions(socket, query) do
    vault_uuid = socket.assigns.vault.uuid
    exclude = socket.assigns.note && socket.assigns.note.uuid

    notes = Notes.search_titles(vault_uuid, query, limit: 8, exclude_uuid: exclude)
    counts = Notes.title_key_counts(vault_uuid, Enum.map(notes, & &1.title_key))

    Enum.map(notes, fn note ->
      ambiguous? = Map.get(counts, note.title_key, 1) > 1

      %{
        # A title several notes answer to is inserted path-qualified, so the
        # link records which one was meant instead of leaving it to the
        # same-folder/shortest-path tie-break.
        value: if(ambiguous?, do: drop_extension(note.relative_path), else: note.title),
        label: note.title,
        sublabel: if(note.folder_path == "", do: gettext("vault root"), else: note.folder_path),
        icon: "hero-document-text"
      }
    end)
  end

  defp tag_suggestions(socket, query) do
    normalized = query |> to_string() |> String.downcase()

    socket.assigns.vault.uuid
    |> Notes.list_tags()
    |> Enum.filter(fn {tag, _count} -> String.contains?(tag, normalized) end)
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

  defp drop_extension(path), do: Storage.drop_extension(path)

  # ── Saving ────────────────────────────────────────────────────────────────

  defp save_content(socket, content, opts \\ [])

  defp save_content(%{assigns: %{note: nil}} = socket, _content, _opts), do: socket

  defp save_content(socket, content, extra_opts) do
    if socket.assigns.can_write do
      # `force` is never inferred from the conflict flag. Autosave means "saving
      # again" is just continuing to type, so forcing on a raised flag would let
      # somebody silently overwrite a colleague's work without ever choosing to.
      # Only the Overwrite button passes it, once.
      opts = Keyword.merge([actor_uuid: actor_uuid(socket), force: false], extra_opts)

      case Notes.update_content(socket.assigns.vault, socket.assigns.note, content, opts) do
        {:ok, note} ->
          socket
          |> assign(:note, note)
          |> assign(:save_status, :saved)
          |> assign(:note_error, nil)
          |> assign(:conflict, false)
          # The link index just changed, so the panels that read it are stale.
          |> assign_note_links()
          |> load_sidebar_counts()

        # The file moved underneath us. Do not write: raise the flag and let
        # the author choose between reloading and overwriting, rather than
        # picking a winner on their behalf.
        {:error, reason} when reason in [:stale, :missing_file] ->
          socket
          |> assign(:save_status, :unsaved)
          |> assign(:conflict, true)
          |> assign(:note_error, error_message(reason))

        {:error, reason} ->
          socket
          |> assign(:save_status, :unsaved)
          |> assign(:note_error, error_message(reason))
      end
    else
      socket
    end
  end

  defp run_rescan(socket) do
    case Rescan.run(socket.assigns.vault) do
      {:ok, report} ->
        socket =
          socket
          |> assign(:rescan_report, report)
          |> load_workspace()
          |> reload_open_note()

        {:noreply,
         put_flash(
           socket,
           :info,
           gettext("Rescan: %{summary}", summary: Rescan.summarize(report))
         )}

      {:error, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Rescan failed: %{reason}", reason: error_message(reason))
         )}
    end
  end

  # Re-read the open note after its file may have changed.
  defp reload_open_note(%{assigns: %{note: nil}} = socket), do: socket

  defp reload_open_note(socket) do
    case Notes.get_note(socket.assigns.vault.uuid, socket.assigns.note.uuid) do
      nil ->
        socket
        |> assign(:note, nil)
        |> put_flash(:info, gettext("That note is no longer on disk."))
        |> push_patch(to: Paths.vault(socket.assigns.vault.slug))

      note ->
        socket |> open_note(note) |> push_editor_content(note)
    end
  end

  # Assigning `@content` is not enough to change what is on screen. Leaf's
  # editing surfaces are `phx-update="ignore"`, so LiveView never patches them
  # after mount and its own `update/2` only re-assigns — it pushes nothing to
  # the client unless the host asks with `:set_content`.
  #
  # Opening a *different* note does not come through here: `editor_id/1` is
  # per-note, so that mounts a fresh component which renders the new content on
  # its own. This is the same-note case — **Discard mine, reload** and a rescan
  # that changed the file underneath — where the component is already mounted
  # and holding the old buffer.
  #
  # `mark_saved` defaults to true, which is what we want: the buffer now matches
  # the bytes on disk, so the editor should read clean rather than claiming
  # unsaved work nobody typed.
  @doc false
  # Public only so a test can assert the command is issued at all: this is the
  # one thing standing between "the server reloaded the note" and "the person
  # sees the reloaded note", and no rendering test in this repo can reach it.
  @spec push_editor_content(term(), Note.t()) :: term()
  def push_editor_content(socket, %Note{} = note) do
    send_update(Leaf, id: editor_id(note), action: :set_content, content: note.content || "")
    socket
  end

  # ── Loading ───────────────────────────────────────────────────────────────

  defp load_workspace(socket) do
    socket |> load_folders() |> load_notes() |> load_sidebar_counts()
  end

  defp load_folders(socket) do
    vault = socket.assigns.vault

    socket
    |> assign(:folder_tree, Notes.folder_tree(vault.uuid))
    |> assign(:folders, Notes.list_folders(vault.uuid))
  end

  defp load_notes(socket) do
    %{vault: vault, selected_folder: folder, selected_tag: tag} = socket.assigns

    notes = Notes.list_notes(vault.uuid, folder_path: folder, tag: tag, order: :title)

    socket
    |> assign(:notes, notes)
    |> assign(:tree_items, tree_items(vault, socket.assigns.folders))
  end

  # Every note in the vault, grouped by the uuid of the folder holding it, which
  # is how core's explorer keys its leaves. Notes at the vault root go under
  # `"root"`.
  #
  # The whole vault, not the current filter: the tree shows what is there, the
  # way Obsidian's file list does. Three columns rather than whole rows —
  # loading `content` for every note would pull the entire vault's markdown
  # through on every note click, folder click and peer save, to keep two
  # fields.
  defp tree_items(vault, folders) do
    uuid_by_path = Map.new(folders, &{&1.relative_path, &1.uuid})

    vault.uuid
    |> Notes.list_titles()
    |> Enum.group_by(
      fn note -> Map.get(uuid_by_path, note.folder_path || "", "root") end,
      # Plain maps rather than the schema: the component reads `:id` off each
      # item for `data-draggable-file`, and a Note has a `uuid`.
      fn note -> %{id: note.uuid, label: note.title} end
    )
  end

  defp load_sidebar_counts(socket) do
    vault = socket.assigns.vault

    socket
    |> assign(:tags, Notes.list_tags(vault.uuid))
    |> assign(:unresolved, Links.unresolved(vault.uuid))
    |> assign(:note_count, Notes.count_notes(vault.uuid))
  end

  defp assign_note_links(%{assigns: %{note: nil}} = socket) do
    socket |> assign(:backlinks, []) |> assign(:outgoing, [])
  end

  defp assign_note_links(socket) do
    note = socket.assigns.note

    socket
    |> assign(:backlinks, Links.backlinks(note))
    |> assign(:outgoing, Links.outgoing(note))
  end

  defp run_search(socket, query) do
    results =
      case String.trim(query) do
        "" -> nil
        trimmed -> Notes.search(socket.assigns.vault.uuid, trimmed, limit: 30)
      end

    socket |> assign(:search_query, query) |> assign(:search_results, results)
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp require_write(%{assigns: %{can_write: true}}), do: :ok
  defp require_write(_socket), do: {:error, :unauthorized}

  defp folder_for_new_note(%{assigns: %{selected_folder: path}}) when is_binary(path), do: path
  defp folder_for_new_note(_socket), do: ""

  defp actor_uuid(socket) do
    case socket.assigns[:phoenix_kit_current_scope] do
      %Scope{user: %{uuid: uuid}} -> uuid
      _ -> nil
    end
  end

  # Total on purpose — `Errors.message/1` answers anything. Every caller is an
  # error path, and a save that fails for an unforeseen reason must show a
  # message rather than crash the LiveView on top of whatever already went
  # wrong.
  defp error_message(:unauthorized), do: read_only_message()
  defp error_message(reason), do: Errors.message(reason)

  # The template needs the id too, and `@editor_id` inside a function component
  # would read an assign that doesn't exist rather than this module attribute.
  @doc """
  The Leaf component id for a note.

  Keyed to the note, and both halves of that matter.

  Leaf's editing surfaces are `phx-update="ignore"`, so LiveView never patches
  them after mount and a changed `content` assign does nothing to the DOM.
  Under a constant id, patching from note A to note B reused the same
  component and the same hook, and the editor went on showing A's text while
  the server believed it was showing B's — every note opened with whatever was
  loaded first.

  Keying the id to the note makes LiveView tear the old component down and
  mount a fresh one, and it makes a *stale* message identifiable: Leaf
  debounces, so a `:leaf_changed` for the note you just left can arrive after
  you have switched, and saving it would write A's text into B's file.
  """
  @spec editor_id(map() | nil) :: String.t()
  def editor_id(%{uuid: uuid}), do: "#{@editor_id_prefix}-#{uuid}"
  def editor_id(_), do: @editor_id_prefix

  @doc """
  Whether a `{:leaf_changed, …}` payload should be written to disk.

  Pure, and public, because it is the whole of the fix for two bugs that were
  invisible from the server's point of view — a stale editor writing into the
  wrong note, and an untouched note being rewritten just for being opened.
  """
  @spec save_decision(map(), map() | nil, String.t()) :: :save | :stale | :unchanged
  def save_decision(payload, note, current_content) do
    cond do
      is_nil(note) or Map.get(payload, :editor_id) != editor_id(note) -> :stale
      not Map.get(payload, :dirty, true) -> :unchanged
      Map.get(payload, :markdown) == current_content -> :unchanged
      true -> :save
    end
  end

  @doc false
  # Public so a test can pin the tokens. Leaf supplies a default that silently
  # breaks both triggers, so this is exactly the setting a regression would
  # remove without failing anything else.
  #
  # The popup headings are translated here, at call time, for both editors —
  # the notes panel takes these configs as they are.
  @spec suggestion_configs() :: [map()]
  def suggestion_configs do
    Enum.map(@suggestion_configs, fn
      %{trigger: "[["} = config -> Map.put(config, :label, gettext("Notes"))
      %{trigger: "#"} = config -> Map.put(config, :label, gettext("Tags"))
    end)
  end

  defp save_label(:saved), do: gettext("Saved")
  defp save_label(:unsaved), do: gettext("Not saved")

  defp save_class(:saved), do: "badge-ghost"
  defp save_class(:unsaved), do: "badge-warning"

  # ── Render ────────────────────────────────────────────────────────────────

  @doc false
  # Core's admin bar renders this beside the trail (`page_toolbar`), with this
  # LiveView's assigns, so its clicks arrive here — the page draws no header of
  # its own under the bar.
  #
  # Below `sm` the buttons are icons only (each keeps its label as a tooltip and
  # for screen readers); four labelled buttons do not fit a phone.
  def header_toolbar(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-1 sm:gap-2">
      <span class="badge badge-sm badge-ghost">
        {if @vault.scope == "system", do: gettext("organisation"), else: gettext("personal")}
      </span>
      <span class="badge badge-sm badge-ghost">{Vaults.role_label(@role)}</span>
      <.link
        :if={@can_manage}
        navigate={Paths.members(@vault.slug)}
        class="btn btn-ghost btn-sm"
        title={gettext("Members")}
        aria-label={gettext("Members")}
      >
        <.icon name="hero-user-group" class="w-4 h-4" />
        <span class="hidden sm:inline">{gettext("Members")}</span>
      </.link>
      <%!-- `data-drop-trash`: core's drag hook looks for the drop target
           across the whole document, so it works from the header too. --%>
      <button
        type="button"
        phx-click="toggle_trash"
        data-drop-trash="true"
        class={["btn btn-sm", if(@trash_open, do: "btn-active", else: "btn-ghost")]}
        title={gettext("Trash")}
        aria-label={gettext("Trash")}
        aria-pressed={to_string(@trash_open)}
      >
        <.icon name="hero-trash" class="w-4 h-4" />
        <span class="hidden sm:inline">{gettext("Trash")}</span>
      </button>
      <button
        :if={@can_write}
        type="button"
        phx-click="rescan"
        phx-disable-with={gettext("Rescanning…")}
        class="btn btn-ghost btn-sm"
        title={gettext("Re-read the vault directory and pick up edits made outside this app")}
        aria-label={gettext("Rescan")}
      >
        <.icon name="hero-arrow-path" class="w-4 h-4" />
        <span class="hidden sm:inline">{gettext("Rescan")}</span>
      </button>
      <.link
        :if={@can_write}
        patch={Paths.new_note(@vault.slug)}
        class="btn btn-primary btn-sm"
        title={gettext("New note")}
        aria-label={gettext("New note")}
      >
        <.icon name="hero-document-plus" class="w-4 h-4" />
        <span class="hidden sm:inline">{gettext("New note")}</span>
      </.link>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div :if={@vault} class="px-4 py-4">
      <div
        :if={@rescan_report && @rescan_report.errors != []}
        class="alert alert-warning mb-4 items-start"
        role="alert"
      >
        <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
        <div class="min-w-0">
          <p class="font-medium">{gettext("Rescan finished with problems")}</p>
          <ul class="mt-1 text-sm space-y-0.5">
            <li :for={error <- @rescan_report.errors} class="truncate">
              <code>{error.path}</code> — {error.reason}
            </li>
          </ul>
        </div>
        <button type="button" phx-click="dismiss_rescan" class="btn btn-ghost btn-xs">
          {gettext("Dismiss")}
        </button>
      </div>

      <div class="grid gap-4 lg:grid-cols-[18rem_minmax(0,1fr)] xl:grid-cols-[18rem_minmax(0,1fr)_18rem]">
        <%!-- Phone only, and above the sidebar so it is at the top of the
             screen whether the file list is open or not. --%>
        <div :if={not is_nil(@note) or @live_action == :new} class="lg:hidden">
          <button
            type="button"
            phx-click="toggle_files"
            class={["btn btn-sm", if(@files_open, do: "btn-active", else: "btn-ghost")]}
            aria-expanded={to_string(@files_open)}
            aria-controls="kb-sidebar"
          >
            <.icon name={if @files_open, do: "hero-x-mark", else: "hero-bars-3"} class="w-4 h-4" />
            {if @files_open, do: gettext("Hide files"), else: gettext("Files")}
          </button>
        </div>

        <.sidebar
          folder_tree={@folder_tree}
          notes={@notes}
          note={@note}
          vault={@vault}
          tags={@tags}
          unresolved={@unresolved}
          selected_folder={@selected_folder}
          selected_tag={@selected_tag}
          directory={@vault.directory}
          search_query={@search_query}
          search_results={@search_results}
          adding_folder={@adding_folder}
          can_write={@can_write}
          trash_open={@trash_open}
          trash={@trash}
          folders={@folders}
          tree_items={@tree_items}
          expanded_folders={@expanded_folders}
          sidebar_collapsed={@sidebar_collapsed}
          renaming_folder={@renaming_folder}
          renaming_source={@renaming_source}
          renaming_text={@renaming_text}
          phone_hidden={(not is_nil(@note) or @live_action == :new) and not @files_open}
        />

        <main class="min-w-0">
          <.new_note_pane
            :if={@live_action == :new}
            vault={@vault}
            title={@new_title}
            can_write={@can_write}
            error={@note_error}
          />

          <.empty_pane
            :if={@live_action != :new and is_nil(@note)}
            note_count={@note_count}
            vault={@vault}
            can_write={@can_write}
          />

          <.note_pane
            :if={@note}
            note={@note}
            vault={@vault}
            content={@content}
            save_status={@save_status}
            can_write={@can_write}
            folders={@folders}
            error={@note_error}
            conflict={@conflict}
            remote_change={@remote_change}
          />
        </main>

        <%!-- Third column on `xl`; below it, under the note (in the note's
             column on `lg`) — it used to vanish, taking backlinks with it. --%>
        <.context_panel
          :if={@note}
          class="lg:col-start-2 xl:col-start-3 xl:row-start-1 border-t border-base-200 pt-4 xl:border-0 xl:pt-0"
          vault={@vault}
          note={@note}
          backlinks={@backlinks}
          outgoing={@outgoing}
        />
      </div>
    </div>
    """
  end

  # ── Sidebar ───────────────────────────────────────────────────────────────

  attr :folder_tree, :list, required: true
  attr :notes, :list, required: true
  attr :note, :any, required: true
  attr :vault, :any, required: true
  attr :tags, :list, required: true
  attr :unresolved, :list, required: true
  attr :selected_folder, :any, required: true
  attr :selected_tag, :any, required: true
  attr :search_query, :string, required: true
  attr :search_results, :any, required: true
  attr :adding_folder, :boolean, required: true
  attr :can_write, :boolean, required: true
  attr :directory, :string, required: true
  attr :trash_open, :boolean, required: true
  attr :trash, :list, required: true
  attr :folders, :list, required: true
  attr :tree_items, :any, required: true
  attr :expanded_folders, :any, required: true
  attr :sidebar_collapsed, :boolean, required: true
  attr :renaming_folder, :any, required: true
  attr :renaming_source, :any, required: true
  attr :renaming_text, :string, required: true
  attr :phone_hidden, :boolean, default: false

  defp sidebar(assigns) do
    ~H"""
    <%!--
      Core's drag-and-drop hook, used as it ships. It finds
      `[data-draggable-file]` and `[data-draggable-folder]` inside this element,
      wires the drop targets, and pushes `move_file_to_folder`,
      `move_folder_to_folder` and `trash_file` back here. Because it is core's
      hook, already registered on `window.PhoenixKitHooks`, this module still
      ships no JavaScript.
    --%>
    <aside
      id="kb-sidebar"
      phx-hook="MediaDragDrop"
      class={[
        "space-y-4 lg:max-h-[calc(100vh-10rem)] lg:overflow-y-auto lg:pr-1",
        @phone_hidden && "hidden lg:block"
      ]}
    >
      <p
        class="text-xs text-base-content/40 truncate"
        title={gettext("These notes are files on disk: %{directory}", directory: @directory)}
      >
        <.icon name="hero-folder-open" class="w-3 h-3 inline-block" />
        {@directory}
      </p>

      <%!-- Core's search row. Its input fires `search` with `query`, and the
           ✕ beside it is this page's own: the toolbar has no clear. --%>
      <div class="flex items-center gap-1">
        <.search_toolbar
          id="kb-search-form"
          value={@search_query}
          name="query"
          on_change="search"
          placeholder={gettext("Search this vault…")}
          class="flex-1 min-w-0"
        />
        <button
          :if={@search_query != ""}
          type="button"
          phx-click="clear_search"
          class="btn btn-ghost btn-xs btn-circle"
          title={gettext("Clear search")}
          aria-label={gettext("Clear search")}
        >
          <.icon name="hero-x-mark" class="w-3 h-3" />
        </button>
      </div>

      <section :if={@trash_open} class="space-y-2">
        <div class="flex items-center justify-between">
          <h2 class="text-xs font-semibold uppercase tracking-wide text-base-content/50">
            {gettext("Trash (%{count})", count: length(@trash))}
          </h2>
          <button
            :if={@trash != [] and @can_write}
            type="button"
            phx-click="empty_trash"
            data-confirm={
              gettext("Permanently delete everything in the trash? This cannot be undone.")
            }
            class="btn btn-ghost btn-xs text-error"
          >
            {gettext("Empty trash")}
          </button>
        </div>

        <p class="text-xs text-base-content/50">
          {gettext("Deleted notes are moved to %{folder} inside the vault, not removed from disk.",
            folder: PhoenixKitKnowledgeBase.Storage.trash_dir()
          )}
        </p>

        <.empty_state
          :if={@trash == []}
          title={gettext("Trash is empty.")}
          icon="hero-trash"
          class="py-4"
        />

        <ul class="space-y-1">
          <li :for={entry <- @trash} class="rounded border border-base-300 p-2 space-y-1">
            <p class="text-sm truncate" title={entry.original_path}>{entry.title}</p>
            <p class="text-xs text-base-content/50 truncate">{entry.original_path}</p>
            <p class="text-xs text-base-content/40">
              {gettext("deleted %{date}",
                date: PhoenixKit.Utils.Date.format_datetime_with_user_format(entry.deleted_at)
              )}
            </p>
            <div :if={@can_write} class="flex gap-1">
              <button
                type="button"
                phx-click="restore_note"
                phx-value-path={entry.trash_path}
                class="btn btn-xs btn-outline flex-1"
              >
                {gettext("Restore")}
              </button>
              <button
                type="button"
                phx-click="purge_note"
                phx-value-path={entry.trash_path}
                data-confirm={
                  gettext("Permanently delete “%{title}”? This cannot be undone.",
                    title: entry.title
                  )
                }
                class="btn btn-xs btn-ghost text-error"
              >
                {gettext("Delete permanently")}
              </button>
            </div>
          </li>
        </ul>
      </section>

      <%!-- `is_nil/1` rather than plain truthiness: `@search_results` is nil when
      no search is running, and `nil and …` is a BadBooleanError even though
      `:if={@search_results}` on its own would have been fine. --%>
      <section :if={not is_nil(@search_results) and not @trash_open} class="space-y-1">
        <h2 class="text-xs font-semibold uppercase tracking-wide text-base-content/50">
          {ngettext("%{count} result", "%{count} results", length(@search_results))}
        </h2>
        <.empty_state
          :if={@search_results == []}
          title={gettext("Nothing matched.")}
          description={gettext("Full-text search matches whole words.")}
          icon="hero-magnifying-glass"
          class="py-4"
        />
        <ul class="space-y-1">
          <li :for={result <- @search_results}>
            <.link
              patch={Paths.note(@vault.slug, result.uuid)}
              class="block rounded px-2 py-1 hover:bg-base-200"
            >
              <span class="block text-sm truncate">{result.title}</span>
              <span class="block text-xs text-base-content/50 truncate">
                {PhoenixKitKnowledgeBase.Markdown.excerpt(result.content, 80)}
              </span>
            </.link>
          </li>
        </ul>
      </section>

      <%!--
        Core's folder explorer, used as it ships. It brings the tree, expand /
        collapse, guide lines, inline rename, the All-notes and Vault-root
        entries, and the `data-drop-folder` / `data-draggable-folder` attributes
        that core's `MediaDragDrop` hook reads — so drag-and-drop costs this
        module no JavaScript of its own.

        `myself={nil}` renders no `phx-target`, which sends every event to this
        LiveView. The component is written for a LiveComponent, and this is the
        one concession needed to use it from a plain one.

        `show_trash={false}` because the Trash button lives in the page header
        here; it carries `data-drop-trash` itself, and the hook looks for that
        across the whole document rather than inside the sidebar.
      --%>
      <div :if={is_nil(@search_results) and not @trash_open} class="space-y-2">
        <.folder_explorer
          id="kb-folder-explorer"
          myself={nil}
          class={
            [
              "block",
              # Core's tree pane is a fixed 240px (an inline style) with a divider
              # on its right, for a page where it sits beside a file grid. Here it
              # IS the column, so on a phone it takes the width and drops the
              # divider. Important, because only that beats an inline style.
              "max-lg:[&>div>div]:w-full! max-lg:[&>div>div]:max-w-none!",
              "max-lg:[&>div>div]:border-r-0! max-lg:[&>div>div]:mr-0! max-lg:[&>div>div]:pr-0!"
            ]
          }
          folder_tree={@folder_tree}
          current_folder={current_folder(@folders, @selected_folder)}
          expanded_folders={@expanded_folders}
          scope_folder_name={@vault.name}
          renaming_folder={@renaming_folder}
          renaming_source={@renaming_source}
          renaming_text={@renaming_text}
          filter_trash={@trash_open}
          file_view={if @selected_folder == :any, do: "all", else: nil}
          sidebar_collapsed={@sidebar_collapsed}
          show_create={@can_write}
          show_trash={false}
          items={@tree_items}
        >
          <:item :let={entry}>
            <.link
              patch={Paths.note(@vault.slug, entry.id)}
              class={[
                "block text-sm truncate py-1",
                if(@note && @note.uuid == entry.id,
                  do: "font-medium text-primary",
                  else: "text-base-content/70"
                )
              ]}
            >
              {entry.label}
            </.link>
          </:item>
        </.folder_explorer>

        <%!--
          Right-click (or touch-and-hold) menus for the tree. Core's explorer
          already marks every row with `data-context-kind` / `-value` / `-label`,
          so these two declarations are the whole cost — one menu element each,
          not one per row, and no round-trip to open.

          `within` confines them to the sidebar: a note's title appears in the
          search results and the editor too, and a right-click there should get
          the browser's own menu.

          The folder menu stamps BOTH spellings of the uuid param because the
          handlers below disagree — `start_rename_folder` takes `folder-uuid`
          (it is the sidebar's own click vocabulary) and `trash_folder` takes
          `folder_uuid` (it is the drag hook's). Stamping both is cheaper than a
          shim clause that exists only to rename a key.
        --%>
        <.context_menu
          :if={@can_write}
          id="kb-folder-context-menu"
          selector="[data-context-kind=folder]"
          within="#kb-sidebar"
          value_name={["folder-uuid", "folder_uuid"]}
          label={gettext("Folder actions")}
        >
          <.context_menu_button
            phx-click="start_rename_folder"
            phx-value-source="sidebar"
            icon="hero-pencil"
            label={gettext("Rename")}
          />
          <.context_menu_divider />
          <.context_menu_button
            phx-click="trash_folder"
            data-confirm={
              gettext("Move this folder to the trash, including every note and subfolder inside it?")
            }
            icon="hero-trash"
            label={gettext("Move to trash")}
            variant="error"
          />
        </.context_menu>

        <.context_menu
          id="kb-note-context-menu"
          selector="[data-context-kind=item]"
          within="#kb-sidebar"
          value_name="file_uuid"
          label={gettext("Note actions")}
        >
          <.context_menu_button
            phx-click="open_note"
            icon="hero-document-text"
            label={gettext("Open")}
          />
          <.context_menu_button
            :if={@can_write}
            phx-click="trash_file"
            data-confirm={gettext("Move this note to the trash?")}
            icon="hero-trash"
            label={gettext("Move to trash")}
            variant="error"
          />
        </.context_menu>

        <%!--
          Core's explorer renames a folder but cannot delete one, and exposes no
          slot to add a control per row — so deletion lives here, acting on
          whichever folder is selected. Dragging a folder onto Trash works too
          (`trash_folder`); this is the affordance for someone who would rather
          click than drag.
        --%>
        <div
          :if={@can_write and not is_nil(current_folder(@folders, @selected_folder))}
          class="flex justify-end"
        >
          <button
            type="button"
            phx-click="delete_folder"
            phx-value-uuid={current_folder(@folders, @selected_folder).uuid}
            data-confirm={
              gettext(
                "Move “%{name}” to the trash, including every note and subfolder inside it?",
                name: current_folder(@folders, @selected_folder).name
              )
            }
            class="btn btn-ghost btn-xs text-error"
          >
            <.icon name="hero-trash" class="w-3 h-3" /> {gettext("Delete folder")}
          </button>
        </div>

        <form
          :if={@adding_folder}
          phx-submit="create_folder"
          id="kb-folder-form"
          class="flex items-end gap-1"
        >
          <.input
            id="kb-folder-name"
            type="text"
            name="name"
            value=""
            label={gettext("New folder")}
            placeholder={gettext("Folder name")}
            autocomplete="off"
            class="input-xs"
            wrapper_class="flex-1 min-w-0"
          />
          <button type="submit" class="btn btn-xs btn-primary">{gettext("Add")}</button>
        </form>
      </div>

      <%!--
        Only for a tag filter now. Without one the tree above already lists every
        note inside its folder, which is what the folders-and-notes-together
        layout was for — a second flat copy of the same thing underneath it is
        noise.
      --%>
      <section
        :if={is_nil(@search_results) and not @trash_open and not is_nil(@selected_tag)}
        class="space-y-1"
      >
        <h2 class="text-xs font-semibold uppercase tracking-wide text-base-content/50">
          {gettext("Notes · #%{tag}", tag: @selected_tag)}
        </h2>
        <.empty_state
          :if={@notes == []}
          title={gettext("Nothing here yet.")}
          class="py-4"
        />
        <ul class="space-y-0.5">
          <li :for={item <- @notes}>
            <.link
              patch={Paths.note(@vault.slug, item.uuid)}
              data-draggable-file={@can_write && item.uuid}
              class={[
                "block rounded px-2 py-1 text-sm truncate hover:bg-base-200",
                @note && @note.uuid == item.uuid && "bg-base-200 font-medium"
              ]}
            >
              {item.title}
            </.link>
          </li>
        </ul>
      </section>

      <section :if={@tags != [] and not @trash_open} class="space-y-1">
        <h2 class="text-xs font-semibold uppercase tracking-wide text-base-content/50">
          {gettext("Tags")}
        </h2>
        <div class="flex flex-wrap gap-1">
          <button
            :for={{tag, count} <- @tags}
            type="button"
            phx-click="select_tag"
            phx-value-tag={tag}
            aria-pressed={to_string(@selected_tag == tag)}
            class={[
              "badge badge-sm gap-1",
              if(@selected_tag == tag, do: "badge-primary", else: "badge-ghost")
            ]}
          >
            #{tag}<span class="opacity-60">{count}</span>
          </button>
        </div>
      </section>

      <section :if={@unresolved != [] and not @trash_open} class="space-y-1">
        <h2 class="text-xs font-semibold uppercase tracking-wide text-base-content/50">
          {gettext("Unresolved links")}
        </h2>
        <p class="text-xs text-base-content/50">
          {gettext("Linked to, but not written yet.")}
        </p>
        <ul class="space-y-0.5">
          <li :for={item <- @unresolved}>
            <.link
              patch={Paths.new_note(@vault.slug, item.title)}
              class="flex items-center justify-between gap-2 rounded px-2 py-1 text-sm hover:bg-base-200"
            >
              <span class="truncate text-warning">{item.title}</span>
              <span class="text-xs text-base-content/50">{item.count}</span>
            </.link>
          </li>
        </ul>
      </section>
    </aside>
    """
  end

  # ── Panes ─────────────────────────────────────────────────────────────────

  attr :note_count, :integer, required: true
  attr :vault, :any, required: true
  attr :can_write, :boolean, required: true

  defp empty_pane(assigns) do
    ~H"""
    <div class="rounded-lg border border-dashed border-base-300">
      <.empty_state
        variant="featured"
        icon="hero-document-text"
        title={
          if @note_count == 0,
            do: gettext("This vault is empty."),
            else: gettext("Pick a note from the sidebar.")
        }
        description={if @note_count == 0 and @can_write, do: gettext("Create your first note.")}
        class="py-12"
      >
        <:cta :if={@note_count == 0 and @can_write}>
          <.link patch={Paths.new_note(@vault.slug)} class="btn btn-primary btn-sm">
            <.icon name="hero-document-plus" class="w-4 h-4" /> {gettext("New note")}
          </.link>
        </:cta>
      </.empty_state>
    </div>
    """
  end

  attr :vault, :any, required: true
  attr :title, :string, required: true
  attr :can_write, :boolean, required: true
  attr :error, :any, required: true

  defp new_note_pane(assigns) do
    ~H"""
    <div class="rounded-lg border border-base-300 bg-base-100 p-6 max-w-xl">
      <h2 class="text-lg font-medium">
        {if @title == "",
          do: gettext("New note"),
          else: gettext("“%{title}” doesn't exist yet", title: @title)}
      </h2>
      <p class="mt-1 text-sm text-base-content/60">
        {if @title == "",
          do:
            gettext(
              "Give it a title. That title is the file name, so it has to be unique inside its folder — two folders may each hold an “Ideas”, and a bare [[Ideas]] then resolves to the nearest one."
            ),
          else:
            gettext(
              "Something links here. Create the note and every link waiting for this title resolves to it."
            )}
      </p>

      <p :if={@error} class="mt-3 text-sm text-error" role="alert">{@error}</p>

      <form
        :if={@can_write}
        phx-submit="create_note"
        id="kb-new-note-form"
        class="mt-4 flex items-end gap-2"
      >
        <.input
          id="kb-new-note-title"
          type="text"
          name="title"
          value={@title}
          label={gettext("Title")}
          placeholder={gettext("Note title")}
          autocomplete="off"
          required
          class="input-sm"
          wrapper_class="flex-1 min-w-0"
        />
        <button type="submit" class="btn btn-primary btn-sm" phx-disable-with={gettext("Creating…")}>
          {gettext("Create note")}
        </button>
      </form>

      <p :if={not @can_write} class="mt-4 text-sm text-base-content/60">
        {gettext("You have read-only access to this vault.")}
      </p>
    </div>
    """
  end

  attr :note, :any, required: true
  attr :vault, :any, required: true
  attr :content, :string, required: true
  attr :save_status, :atom, required: true
  attr :can_write, :boolean, required: true
  attr :folders, :list, required: true
  attr :error, :any, required: true
  attr :conflict, :boolean, required: true
  attr :remote_change, :boolean, required: true

  defp note_pane(assigns) do
    ~H"""
    <article class="space-y-3">
      <header class="flex flex-wrap items-center justify-between gap-2">
        <form phx-submit="rename_note" id="kb-rename-form" class="flex-1 min-w-0">
          <input
            type="text"
            name="title"
            value={@note.title}
            readonly={not @can_write}
            phx-blur="rename_note"
            class="input input-ghost w-full text-xl font-semibold px-1"
            aria-label={gettext("Note title")}
          />
        </form>

        <div class="flex items-center gap-2">
          <span
            :if={@can_write}
            class={["badge badge-sm", save_class(@save_status)]}
            role="status"
          >
            {save_label(@save_status)}
          </span>

          <button
            :if={@can_write}
            type="button"
            phx-click="delete_note"
            data-confirm={
              gettext(
                "Move “%{title}” to the trash? Links to it become unresolved until it is restored.",
                title: @note.title
              )
            }
            class="btn btn-ghost btn-sm text-error"
            title={gettext("Move to trash")}
            aria-label={gettext("Move to trash")}
          >
            <.icon name="hero-trash" class="w-4 h-4" />
          </button>
        </div>
      </header>

      <div :if={@conflict} class="alert alert-warning items-start" role="alert">
        <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
        <div class="min-w-0">
          <p class="font-medium">{gettext("This note changed since you opened it")}</p>
          <p class="text-sm">
            {gettext(
              "Something else edited %{path} — another browser, another person, or an editor on the server. Your changes are not being saved until you choose.",
              path: @note.relative_path
            )}
          </p>
        </div>
        <div class="flex gap-1">
          <button type="button" phx-click="reload_note" class="btn btn-sm">
            {gettext("Discard mine, reload")}
          </button>
          <button
            type="button"
            phx-click="overwrite_note"
            data-confirm={gettext("Overwrite the other version with what's in your editor?")}
            class="btn btn-sm btn-warning"
          >
            {gettext("Keep mine, overwrite")}
          </button>
        </div>
      </div>

      <div :if={@remote_change and not @conflict} class="alert alert-info items-start" role="status">
        <.icon name="hero-arrow-path" class="w-5 h-5" />
        <div class="min-w-0">
          <p class="font-medium">{gettext("Someone else just saved this note")}</p>
          <p class="text-sm">
            {gettext(
              "Nothing here has been replaced. Reload to see their version — anything you have not saved is lost. Keep editing, and your next save asks before overwriting theirs."
            )}
          </p>
        </div>
        <div class="flex gap-1">
          <button type="button" phx-click="reload_note" class="btn btn-sm">
            {gettext("Reload")}
          </button>
          <button type="button" phx-click="dismiss_remote_change" class="btn btn-ghost btn-sm">
            {gettext("Keep editing")}
          </button>
        </div>
      </div>

      <div class="flex flex-wrap items-center gap-2 text-xs text-base-content/60">
        <form :if={@can_write} phx-change="move_note" id="kb-move-form">
          <.select
            id="kb-move-folder"
            name="folder"
            value={if @note.folder_path == "", do: "root", else: @note.folder_path}
            options={[
              {gettext("Vault root"), "root"}
              | Enum.map(@folders, &{&1.relative_path, &1.relative_path})
            ]}
            class="select-xs"
            aria-label={gettext("Folder")}
            title={gettext("Move to folder")}
          />
        </form>

        <code class="opacity-60" title={gettext("Path inside the vault directory")}>
          {@note.relative_path}
        </code>

        <span :for={tag <- @note.tags} class="badge badge-ghost badge-sm">#{tag}</span>
      </div>

      <p :if={@error} class="text-sm text-error" role="alert">{@error}</p>

      <div :if={@note.frontmatter != %{}} class="rounded border border-base-300 bg-base-200/40 p-3">
        <h3 class="text-xs font-semibold uppercase tracking-wide text-base-content/50 mb-1">
          {gettext("Properties")}
        </h3>
        <dl class="grid grid-cols-[8rem_minmax(0,1fr)] gap-x-3 gap-y-1 text-sm">
          <div :for={{key, value} <- Enum.sort(@note.frontmatter)} class="contents">
            <dt class="text-base-content/60 truncate">{key}</dt>
            <dd class="truncate">{format_property(value)}</dd>
          </div>
        </dl>
      </div>

      <div class="space-y-2">
        <p class="text-xs text-base-content/50">
          {gettext(
            "Type [[ to link a note or # for a tag — ↑↓ to move, Enter to accept. Click a link to open it. Saves as you write."
          )}
        </p>

        <.live_component
          module={Leaf}
          id={editor_id(@note)}
          content={@content}
          mode={:hybrid}
          preset={:advanced}
          suggestions={suggestion_configs()}
          wiki_links={%{resolve: true, follow: :click}}
          deny={[:visual_mode, :html_mode]}
          placeholder={gettext("Write in markdown. Link with [[Note title]].")}
          height="60vh"
          debounce={500}
          readonly={not @can_write}
          gettext_backend={PhoenixKitKnowledgeBase.Gettext}
        />
      </div>
    </article>
    """
  end

  attr :vault, :any, required: true
  attr :note, :any, required: true
  attr :backlinks, :list, required: true
  attr :outgoing, :list, required: true
  attr :class, :string, default: ""

  defp context_panel(assigns) do
    ~H"""
    <aside class={["space-y-4", @class]}>
      <section class="space-y-1">
        <h2 class="text-xs font-semibold uppercase tracking-wide text-base-content/50">
          {gettext("Linked mentions (%{count})", count: length(@backlinks))}
        </h2>
        <.empty_state
          :if={@backlinks == []}
          title={gettext("Nothing links here yet.")}
          class="py-4"
        />
        <ul class="space-y-0.5">
          <li :for={source <- @backlinks}>
            <.link
              patch={Paths.note(@vault.slug, source.uuid)}
              class="block rounded px-2 py-1 text-sm truncate hover:bg-base-200"
            >
              {source.title}
            </.link>
          </li>
        </ul>
      </section>

      <section :if={@outgoing != []} class="space-y-1">
        <h2 class="text-xs font-semibold uppercase tracking-wide text-base-content/50">
          {gettext("Links from this note")}
        </h2>
        <ul class="space-y-0.5">
          <li :for={link <- @outgoing}>
            <.link
              :if={link.target_note_uuid}
              patch={Paths.note(@vault.slug, link.target_note_uuid)}
              class="block rounded px-2 py-1 text-sm truncate hover:bg-base-200"
            >
              {link.target_title}
            </.link>
            <.link
              :if={is_nil(link.target_note_uuid)}
              patch={Paths.new_note(@vault.slug, link.target_title)}
              class="block rounded px-2 py-1 text-sm truncate hover:bg-base-200 text-warning"
              title={gettext("Not written yet")}
            >
              {link.target_title}
            </.link>
          </li>
        </ul>
      </section>
    </aside>
    """
  end

  @doc false
  # Front matter is any YAML: a list of maps (`authors: [{name: …}]`) is as
  # valid as a list of strings, and `to_string/1` on a map raises — which took
  # the page down on every render of that note. Total, and recursive.
  @spec format_property(term()) :: String.t()
  def format_property(nil), do: "—"
  def format_property(value) when is_binary(value), do: value

  def format_property(value) when is_list(value),
    do: Enum.map_join(value, ", ", &format_property/1)

  def format_property(value) when is_map(value) do
    value
    |> Enum.sort()
    |> Enum.map_join("; ", fn {key, inner} -> "#{key}: #{format_property(inner)}" end)
  end

  def format_property(value) when is_number(value) or is_boolean(value) or is_atom(value),
    do: to_string(value)

  def format_property(value), do: inspect(value)
end
