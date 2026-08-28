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

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitKnowledgeBase.{Events, Links, Markdown, Notes, Paths, Rescan, Vaults}
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
      insert_suffix: "]]",
      label: "Notes"
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
      keep_trigger: true,
      label: "Tags"
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
     |> assign(:new_title, "")
     |> assign(:note_error, nil)
     |> assign(:can_write, false)
     |> assign(:can_manage, false)
     |> assign(:folder_tree, [])
     |> assign(:folders, [])
     |> assign(:notes, [])
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
         |> put_flash(:error, "That vault does not exist, or you do not have access to it.")
         |> push_navigate(to: Paths.vaults())}

      {:ok, vault, role} ->
        maybe_subscribe(socket, vault)

        {:noreply,
         socket
         |> assign(:vault, vault)
         |> assign(:role, role)
         |> assign(:can_write, Vaults.can?(role, :write))
         |> assign(:can_manage, Vaults.can?(role, :manage))
         |> assign(:page_title, vault.name)
         |> assign(:page_subtitle, vault.description)
         |> load_workspace()
         |> apply_action(socket.assigns.live_action, params)}
    end
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
        |> put_flash(:error, "That note no longer exists.")
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
  def handle_event("select_folder", %{"path" => path}, socket) do
    selected =
      case path do
        "" -> :any
        "root" -> ""
        path -> path
      end

    {:noreply,
     socket |> assign(:selected_folder, selected) |> assign(:selected_tag, nil) |> load_notes()}
  end

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
    attrs = %{
      "title" => title,
      "content" => "",
      "folder_path" => folder_for_new_note(socket)
    }

    with :ok <- require_write(socket),
         {:ok, note} <- Notes.create_note(socket.assigns.vault, attrs, actor_uuid(socket)) do
      {:noreply,
       socket
       |> assign(:note_error, nil)
       |> load_workspace()
       |> push_patch(to: Paths.note(socket.assigns.vault.slug, note.uuid))}
    else
      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You have read-only access to this vault.")}

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
             |> assign_note_links()}

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
       |> put_flash(:info, "Note moved to the trash. Links to it are now unresolved.")
       |> assign(:note, nil)
       |> load_workspace()
       |> push_patch(to: Paths.vault(vault.slug))}
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not delete that note.")}
    end
  end

  def handle_event("move_note", %{"folder" => folder}, socket) do
    folder_path = if folder == "root", do: "", else: folder

    with :ok <- require_write(socket),
         %Note{} = note <- socket.assigns.note,
         {:ok, updated} <-
           Notes.move_note(socket.assigns.vault, note, folder_path,
             actor_uuid: actor_uuid(socket)
           ) do
      {:noreply, socket |> assign(:note, updated) |> assign(:conflict, false) |> load_workspace()}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, error_message(reason))}
      _ -> {:noreply, put_flash(socket, :error, "Could not move that note.")}
    end
  end

  # ── Events: folders ───────────────────────────────────────────────────────

  def handle_event("toggle_add_folder", _params, socket) do
    {:noreply, assign(socket, :adding_folder, not socket.assigns.adding_folder)}
  end

  def handle_event("create_folder", %{"name" => name}, socket) do
    parent =
      if is_binary(socket.assigns.selected_folder), do: socket.assigns.selected_folder, else: ""

    with :ok <- require_write(socket),
         {:ok, _folder} <- Notes.create_folder(socket.assigns.vault, parent, name) do
      {:noreply, socket |> assign(:adding_folder, false) |> load_workspace()}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Folder: #{error_message(reason)}")}
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
       |> put_flash(
         :info,
         "Moved #{folder.name} and #{removed} #{if removed == 1, do: "note", else: "notes"} to the trash."
       )
       |> assign(:selected_folder, :any)
       |> assign(:note, nil)
       |> load_workspace()
       |> push_patch(to: Paths.vault(socket.assigns.vault.slug))}
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not delete that folder.")}
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
       |> put_flash(:info, "Restored “#{note.title}”.")
       |> assign(:trash, Notes.list_trash(socket.assigns.vault))
       |> load_workspace()
       |> push_patch(to: Paths.note(socket.assigns.vault.slug, note.uuid))}
    else
      {:error, :target_exists} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "A note already exists at that path. Rename or move it, then restore again."
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}

      _ ->
        {:noreply, put_flash(socket, :error, "Could not restore that note.")}
    end
  end

  def handle_event("purge_note", %{"path" => trash_path}, socket) do
    with :ok <- require_write(socket),
         %{} = entry <- find_trash_entry(socket, trash_path),
         :ok <- Notes.purge_trash(socket.assigns.vault, entry) do
      {:noreply,
       socket
       |> put_flash(:info, "Deleted permanently.")
       |> assign(:trash, Notes.list_trash(socket.assigns.vault))}
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not delete that.")}
    end
  end

  def handle_event("empty_trash", _params, socket) do
    with :ok <- require_write(socket),
         :ok <- Notes.empty_trash(socket.assigns.vault) do
      {:noreply, socket |> put_flash(:info, "Trash emptied.") |> assign(:trash, [])}
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not empty the trash.")}
    end
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
      {:noreply, put_flash(socket, :error, "You do not have permission to rescan.")}
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
      # mtime, or a peer saving an identical buffer. Nothing to show.
      socket.assigns.note && payload.note_uuid == socket.assigns.note.uuid &&
          payload.hash == socket.assigns.note.content_hash ->
        {:noreply, socket}

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
      {:noreply,
       socket
       |> load_workspace()
       |> assign(
         :trash,
         if(socket.assigns.trash_open, do: Notes.list_trash(socket.assigns.vault), else: [])
       )
       |> reload_open_note_if_idle()}
    end
  end

  # ── Editor messages ──────────────────────────────────────────────────────

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

  # The image/video toolbar buttons. This version has no upload path, so the
  # request is acknowledged and ignored rather than left to crash the LiveView.
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

  # A peer changed the note on screen. There is only one surface now and it may
  # hold unsaved keystrokes, so the change is announced and never applied behind
  # the author's back — `remote_change` raises the banner, the reload is theirs
  # to ask for.
  defp apply_remote_note_change(socket) do
    case Notes.get_note(socket.assigns.vault.uuid, socket.assigns.note.uuid) do
      nil -> socket
      note -> socket |> assign(:note, note) |> assign(:remote_change, true)
    end
  end

  # A rescan elsewhere refreshes the sidebar, but never replaces the open
  # buffer — that would discard whatever is being typed.
  defp reload_open_note_if_idle(socket), do: socket

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
        "#{count} notes share this title — this link resolves to #{note.relative_path}"

      _ ->
        note.relative_path
    end
  end

  defp missing_title(true), do: "No note with this title yet — click to create it"
  defp missing_title(false), do: "No note with this title yet"

  # Leaf sends the bare target: the heading anchor and the alias arrive as
  # separate fields and are already stripped. Normalising it is what makes
  # "My  Note", "my note" and " My Note " the same note, and it is the same
  # key the stored link index uses.
  defp link_key(target), do: Markdown.normalize_title(target)

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
        sublabel: if(note.folder_path == "", do: "vault root", else: note.folder_path),
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
        sublabel: "#{count} #{if count == 1, do: "note", else: "notes"}",
        icon: "hero-hashtag"
      }
    end)
  end

  defp drop_extension(path), do: String.replace_suffix(path, ".md", "")

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

        {:noreply, put_flash(socket, :info, "Rescan: #{Rescan.summarize(report)}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Rescan failed: #{error_message(reason)}")}
    end
  end

  # Re-read the open note after its file may have changed.
  defp reload_open_note(%{assigns: %{note: nil}} = socket), do: socket

  defp reload_open_note(socket) do
    case Notes.get_note(socket.assigns.vault.uuid, socket.assigns.note.uuid) do
      nil ->
        socket
        |> assign(:note, nil)
        |> put_flash(:info, "That note is no longer on disk.")
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

    assign(socket, :notes, notes)
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

  # Total on purpose. Every caller is an error path, and a save that fails for
  # an unforeseen reason must show a message rather than crash the LiveView on
  # top of whatever already went wrong.
  defp error_message(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end

  defp error_message(:unauthorized), do: "You have read-only access to this vault."

  defp error_message(:stale),
    do:
      "This note changed on disk since you opened it. Reload to see the new version, or save again to overwrite it."

  defp error_message(:missing_file),
    do: "This note's file is gone from disk. Rescan the vault, or save again to recreate it."

  defp error_message({:forbidden_characters, chars}) do
    "A name cannot contain #{Enum.join(chars, " ")} — " <>
      "these break either the filesystem or [[link]] syntax. " <>
      "Not allowed: #{PhoenixKitKnowledgeBase.Storage.forbidden_characters()}"
  end

  defp error_message(:blank), do: "A name cannot be empty."

  defp error_message(:leading_dot),
    do: "A name cannot start with a dot — that would hide the file."

  defp error_message(:trailing_dot), do: "A name cannot end with a dot."
  defp error_message(:too_long), do: "That name is too long for a filename."

  defp error_message(:reserved),
    do: "That name is reserved by Windows and would break syncing the vault there."

  defp error_message(:already_exists), do: "A note with that name already exists in this folder."
  defp error_message(:target_exists), do: "There is already a note at that path."
  defp error_message(:unsafe_path), do: "That path is not inside the vault."
  defp error_message(:enoent), do: "That file no longer exists on disk."
  defp error_message(:eacces), do: "Permission denied writing to the vault directory."
  defp error_message(other), do: "Could not save: #{inspect(other)}"

  # The template needs the id too, and `@editor_id` inside a function component
  # would read an assign that doesn't exist rather than this module attribute.
  @doc """
  The Leaf component id for a note.

  Keyed to the note, and both halves of that matter, and both halves of that matter.
  #
  # Leaf's editing surfaces are `phx-update="ignore"`, so LiveView never patches
  # them after mount and a changed `content` assign does nothing to the DOM.
  # Under a constant id, patching from note A to note B reused the same
  # component and the same hook, and the editor went on showing A's text while
  # the server believed it was showing B's — every note opened with whatever was
  # loaded first.
  #
  # Keying the id to the note makes LiveView tear the old component down and
  # mount a fresh one, and it makes a *stale* message identifiable: Leaf
  # debounces, so a `:leaf_changed` for the note you just left can arrive after
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
  @spec suggestion_configs() :: [map()]
  def suggestion_configs, do: @suggestion_configs

  defp save_label(:saved), do: "Saved"
  defp save_label(:saving), do: "Saving…"
  defp save_label(:unsaved), do: "Unsaved"

  defp save_class(:saved), do: "badge-ghost"
  defp save_class(:saving), do: "badge-info"
  defp save_class(:unsaved), do: "badge-warning"

  # ── Render ────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div :if={@vault} class="px-4 py-4">
      <div class="flex flex-wrap items-center justify-between gap-3 mb-4">
        <div class="flex items-center gap-2 min-w-0">
          <.link navigate={Paths.vaults()} class="btn btn-ghost btn-xs">
            <.icon name="hero-arrow-left" class="w-4 h-4" />
          </.link>
          <.icon name={@vault.icon || "hero-book-open"} class="w-5 h-5 shrink-0" />
          <h1 class="text-xl font-semibold truncate">{@vault.name}</h1>
          <span class="badge badge-sm badge-ghost">
            {if @vault.scope == "system", do: "organisation", else: "personal"}
          </span>
          <span class="badge badge-sm badge-ghost">{@role}</span>
        </div>

        <div class="flex items-center gap-2">
          <.link :if={@can_manage} navigate={Paths.members(@vault.slug)} class="btn btn-ghost btn-sm">
            <.icon name="hero-user-group" class="w-4 h-4" /> Members
          </.link>
          <button
            type="button"
            phx-click="toggle_trash"
            class={["btn btn-sm", if(@trash_open, do: "btn-active", else: "btn-ghost")]}
          >
            <.icon name="hero-trash" class="w-4 h-4" /> Trash
          </button>
          <button
            type="button"
            phx-click="rescan"
            class="btn btn-ghost btn-sm"
            title="Re-read the vault directory and pick up edits made outside this app"
          >
            <.icon name="hero-arrow-path" class="w-4 h-4" /> Rescan
          </button>
          <.link :if={@can_write} patch={Paths.new_note(@vault.slug)} class="btn btn-primary btn-sm">
            <.icon name="hero-document-plus" class="w-4 h-4" /> New note
          </.link>
        </div>
      </div>

      <div
        :if={@rescan_report && @rescan_report.errors != []}
        class="alert alert-warning mb-4 items-start"
      >
        <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
        <div class="min-w-0">
          <p class="font-medium">Rescan finished with problems</p>
          <ul class="mt-1 text-sm space-y-0.5">
            <li :for={error <- @rescan_report.errors} class="truncate">
              <code>{error.path}</code> — {error.reason}
            </li>
          </ul>
        </div>
        <button type="button" phx-click="dismiss_rescan" class="btn btn-ghost btn-xs">Dismiss</button>
      </div>

      <div class="grid gap-4 lg:grid-cols-[18rem_minmax(0,1fr)] xl:grid-cols-[18rem_minmax(0,1fr)_18rem]">
        <.sidebar
          folder_tree={@folder_tree}
          notes={@notes}
          note={@note}
          vault={@vault}
          tags={@tags}
          unresolved={@unresolved}
          note_count={@note_count}
          selected_folder={@selected_folder}
          selected_tag={@selected_tag}
          directory={@vault.directory}
          search_query={@search_query}
          search_results={@search_results}
          adding_folder={@adding_folder}
          can_write={@can_write}
          trash_open={@trash_open}
          trash={@trash}
        />

        <main class="min-w-0">
          <.new_note_pane
            :if={@live_action == :new}
            vault={@vault}
            title={@new_title}
            can_write={@can_write}
            error={@note_error}
          />

          <.empty_pane :if={@live_action != :new and is_nil(@note)} note_count={@note_count} />

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

        <.context_panel
          :if={@note}
          class="hidden xl:block"
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
  attr :note_count, :integer, required: true
  attr :selected_folder, :any, required: true
  attr :selected_tag, :any, required: true
  attr :search_query, :string, required: true
  attr :search_results, :any, required: true
  attr :adding_folder, :boolean, required: true
  attr :can_write, :boolean, required: true
  attr :directory, :string, required: true
  attr :trash_open, :boolean, required: true
  attr :trash, :list, required: true

  defp sidebar(assigns) do
    ~H"""
    <aside class="space-y-4 lg:max-h-[calc(100vh-10rem)] lg:overflow-y-auto lg:pr-1">
      <p class="text-xs text-base-content/40 break-all" title="These notes are files on disk">
        <.icon name="hero-folder-open" class="w-3 h-3 inline-block" />
        {@directory}
      </p>

      <form phx-change="search" phx-submit="search" id="kb-search-form" class="relative">
        <input
          type="search"
          name="query"
          value={@search_query}
          phx-debounce="300"
          placeholder="Search this vault…"
          class="input input-sm input-bordered w-full pr-8"
        />
        <button
          :if={@search_query != ""}
          type="button"
          phx-click="clear_search"
          class="absolute right-1 top-1/2 -translate-y-1/2 btn btn-ghost btn-xs btn-circle"
          aria-label="Clear search"
        >
          <.icon name="hero-x-mark" class="w-3 h-3" />
        </button>
      </form>

      <section :if={@trash_open} class="space-y-2">
        <div class="flex items-center justify-between">
          <h2 class="text-xs font-semibold uppercase tracking-wide text-base-content/50">
            Trash ({length(@trash)})
          </h2>
          <button
            :if={@trash != [] and @can_write}
            type="button"
            phx-click="empty_trash"
            data-confirm="Permanently delete everything in the trash? This cannot be undone."
            class="btn btn-ghost btn-xs text-error"
          >
            Empty
          </button>
        </div>

        <p class="text-xs text-base-content/50">
          Deleted notes are moved to <code>{PhoenixKitKnowledgeBase.Storage.trash_dir()}</code>
          inside the vault, not removed from disk.
        </p>

        <p :if={@trash == []} class="text-sm text-base-content/50 italic">Trash is empty.</p>

        <ul class="space-y-1">
          <li :for={entry <- @trash} class="rounded border border-base-300 p-2 space-y-1">
            <p class="text-sm truncate" title={entry.original_path}>{entry.title}</p>
            <p class="text-xs text-base-content/50 truncate">{entry.original_path}</p>
            <p class="text-xs text-base-content/40">
              deleted {Calendar.strftime(entry.deleted_at, "%Y-%m-%d %H:%M")}
            </p>
            <div :if={@can_write} class="flex gap-1">
              <button
                type="button"
                phx-click="restore_note"
                phx-value-path={entry.trash_path}
                class="btn btn-xs btn-outline flex-1"
              >
                Restore
              </button>
              <button
                type="button"
                phx-click="purge_note"
                phx-value-path={entry.trash_path}
                data-confirm={"Permanently delete “#{entry.title}”? This cannot be undone."}
                class="btn btn-xs btn-ghost text-error"
              >
                Delete
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
          {length(@search_results)} results
        </h2>
        <p :if={@search_results == []} class="text-sm text-base-content/50 italic">
          Nothing matched. Full-text search matches whole words.
        </p>
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

      <section :if={is_nil(@search_results) and not @trash_open} class="space-y-2">
        <div class="flex items-center justify-between">
          <h2 class="text-xs font-semibold uppercase tracking-wide text-base-content/50">Folders</h2>
          <button
            :if={@can_write}
            type="button"
            phx-click="toggle_add_folder"
            class="btn btn-ghost btn-xs"
            aria-label="New folder"
          >
            <.icon name="hero-folder-plus" class="w-4 h-4" />
          </button>
        </div>

        <form :if={@adding_folder} phx-submit="create_folder" id="kb-folder-form" class="flex gap-1">
          <input
            type="text"
            name="name"
            placeholder="Folder name"
            autocomplete="off"
            class="input input-xs input-bordered flex-1"
          />
          <button type="submit" class="btn btn-xs btn-primary">Add</button>
        </form>

        <ul class="space-y-0.5 text-sm">
          <li>
            <button
              type="button"
              phx-click="select_folder"
              phx-value-path=""
              class={[
                "w-full text-left rounded px-2 py-1 hover:bg-base-200 flex justify-between",
                @selected_folder == :any && "bg-base-200 font-medium"
              ]}
            >
              <span>All notes</span>
              <span class="text-xs text-base-content/50">{@note_count}</span>
            </button>
          </li>
          <li>
            <button
              type="button"
              phx-click="select_folder"
              phx-value-path="root"
              class={[
                "w-full text-left rounded px-2 py-1 hover:bg-base-200",
                @selected_folder == "" && "bg-base-200 font-medium"
              ]}
            >
              Vault root
            </button>
          </li>
        </ul>

        <.folder_nodes
          nodes={@folder_tree}
          depth={0}
          selected={@selected_folder}
          can_write={@can_write}
        />
      </section>

      <section :if={is_nil(@search_results) and not @trash_open} class="space-y-1">
        <h2 class="text-xs font-semibold uppercase tracking-wide text-base-content/50">
          Notes{if @selected_tag, do: " · ##{@selected_tag}", else: ""}
        </h2>
        <p :if={@notes == []} class="text-sm text-base-content/50 italic">Nothing here yet.</p>
        <ul class="space-y-0.5">
          <li :for={item <- @notes}>
            <.link
              patch={Paths.note(@vault.slug, item.uuid)}
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
        <h2 class="text-xs font-semibold uppercase tracking-wide text-base-content/50">Tags</h2>
        <div class="flex flex-wrap gap-1">
          <button
            :for={{tag, count} <- @tags}
            type="button"
            phx-click="select_tag"
            phx-value-tag={tag}
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
          Unresolved links
        </h2>
        <p class="text-xs text-base-content/50">
          Linked to, but not written yet.
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

  attr :nodes, :list, required: true
  attr :depth, :integer, required: true
  attr :selected, :any, required: true
  attr :can_write, :boolean, required: true

  defp folder_nodes(assigns) do
    ~H"""
    <ul :if={@nodes != []} class="space-y-0.5 text-sm">
      <li :for={node <- @nodes}>
        <div class="group flex items-center gap-1">
          <button
            type="button"
            phx-click="select_folder"
            phx-value-path={node.folder.relative_path}
            style={"padding-left: #{0.5 + @depth * 0.75}rem"}
            class={[
              "flex-1 text-left rounded px-2 py-1 hover:bg-base-200 truncate",
              @selected == node.folder.relative_path && "bg-base-200 font-medium"
            ]}
          >
            <.icon name="hero-folder" class="w-3 h-3 inline-block mr-1 opacity-60" />{node.folder.name}
          </button>
          <button
            :if={@can_write}
            type="button"
            phx-click="delete_folder"
            phx-value-uuid={node.folder.uuid}
            data-confirm={"Move “#{node.folder.name}” to the trash, including every note and subfolder inside it?"}
            class="btn btn-ghost btn-xs opacity-0 group-hover:opacity-100"
            aria-label="Delete folder"
          >
            <.icon name="hero-trash" class="w-3 h-3 text-error" />
          </button>
        </div>
        <.folder_nodes
          nodes={node.children}
          depth={@depth + 1}
          selected={@selected}
          can_write={@can_write}
        />
      </li>
    </ul>
    """
  end

  # ── Panes ─────────────────────────────────────────────────────────────────

  attr :note_count, :integer, required: true

  defp empty_pane(assigns) do
    ~H"""
    <div class="rounded-lg border border-dashed border-base-300 p-12 text-center">
      <.icon name="hero-document-text" class="w-8 h-8 mx-auto text-base-content/30" />
      <p class="mt-3 text-base-content/60">
        {if @note_count == 0,
          do: "This vault is empty. Create your first note.",
          else: "Pick a note from the sidebar."}
      </p>
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
        {if @title == "", do: "New note", else: "“#{@title}” doesn't exist yet"}
      </h2>
      <p class="mt-1 text-sm text-base-content/60">
        {if @title == "",
          do:
            "Give it a title. That title is the filename, so it has to be unique inside its folder — two folders may each hold an “Ideas”, and a bare [[Ideas]] then resolves to the nearest one.",
          else:
            "Something links here. Create the note and every link waiting for this title resolves to it."}
      </p>

      <p :if={@error} class="mt-3 text-sm text-error">{@error}</p>

      <form :if={@can_write} phx-submit="create_note" id="kb-new-note-form" class="mt-4 flex gap-2">
        <input
          type="text"
          name="title"
          value={@title}
          placeholder="Note title"
          autocomplete="off"
          required
          class="input input-sm input-bordered flex-1"
        />
        <button type="submit" class="btn btn-primary btn-sm">Create note</button>
      </form>

      <p :if={not @can_write} class="mt-4 text-sm text-base-content/60">
        You have read-only access to this vault.
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
            aria-label="Note title"
          />
        </form>

        <div class="flex items-center gap-2">
          <span :if={@can_write} class={["badge badge-sm", save_class(@save_status)]}>
            {save_label(@save_status)}
          </span>

          <button
            :if={@can_write}
            type="button"
            phx-click="delete_note"
            data-confirm={"Move “#{@note.title}” to the trash? Links to it become unresolved until it is restored."}
            class="btn btn-ghost btn-sm text-error"
            aria-label="Delete note"
          >
            <.icon name="hero-trash" class="w-4 h-4" />
          </button>
        </div>
      </header>

      <div :if={@conflict} class="alert alert-warning items-start">
        <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
        <div class="min-w-0">
          <p class="font-medium">This note changed since you opened it</p>
          <p class="text-sm">
            Something else edited <code>{@note.relative_path}</code>
            — another browser, another person, or an editor on the server.
            <strong>Your changes are not being saved</strong>
            until you choose.
          </p>
        </div>
        <div class="flex gap-1">
          <button type="button" phx-click="reload_note" class="btn btn-sm">
            Discard mine, reload
          </button>
          <button
            type="button"
            phx-click="overwrite_note"
            data-confirm="Overwrite the other version with what's in your editor?"
            class="btn btn-sm btn-warning"
          >
            Keep mine, overwrite
          </button>
        </div>
      </div>

      <div :if={@remote_change and not @conflict} class="alert alert-info items-start">
        <.icon name="hero-arrow-path" class="w-5 h-5" />
        <div class="min-w-0">
          <p class="font-medium">Someone else just saved this note</p>
          <p class="text-sm">
            You are editing, so nothing has been replaced. Reload to see their
            version — anything you have typed and not saved will be lost.
          </p>
        </div>
        <div class="flex gap-1">
          <button type="button" phx-click="reload_note" class="btn btn-sm">Reload</button>
          <button type="button" phx-click="dismiss_remote_change" class="btn btn-ghost btn-sm">
            Keep editing
          </button>
        </div>
      </div>

      <div class="flex flex-wrap items-center gap-2 text-xs text-base-content/60">
        <form :if={@can_write} phx-change="move_note" id="kb-move-form">
          <select name="folder" class="select select-xs select-bordered">
            <option value="root" selected={@note.folder_path == ""}>Vault root</option>
            <option
              :for={folder <- @folders}
              value={folder.relative_path}
              selected={@note.folder_path == folder.relative_path}
            >
              {folder.relative_path}
            </option>
          </select>
        </form>

        <code class="opacity-60" title="Path inside the vault directory">{@note.relative_path}</code>

        <span :for={tag <- @note.tags} class="badge badge-ghost badge-sm">#{tag}</span>
      </div>

      <p :if={@error} class="text-sm text-error">{@error}</p>

      <div :if={@note.frontmatter != %{}} class="rounded border border-base-300 bg-base-200/40 p-3">
        <h3 class="text-xs font-semibold uppercase tracking-wide text-base-content/50 mb-1">
          Properties
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
          Type <code>[[</code>
          to link a note or <code>#</code>
          for a tag — ↑↓ to move, Enter to accept. Click a link to open it.
          Saves as you write.
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
          placeholder="Write in markdown. Link with [[Note title]]."
          height="60vh"
          debounce={500}
          readonly={not @can_write}
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
          Linked mentions ({length(@backlinks)})
        </h2>
        <p :if={@backlinks == []} class="text-sm text-base-content/50 italic">
          Nothing links here yet.
        </p>
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
          Links from this note
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
            >
              {link.target_title}
            </.link>
          </li>
        </ul>
      </section>
    </aside>
    """
  end

  defp format_property(value) when is_list(value), do: Enum.map_join(value, ", ", &to_string/1)
  defp format_property(value) when is_map(value), do: inspect(value)
  defp format_property(nil), do: "—"
  defp format_property(value), do: to_string(value)
end
