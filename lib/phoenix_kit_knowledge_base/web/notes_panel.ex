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

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitKnowledgeBase.{Links, Markdown, Notes, Paths, Places, Vaults}
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

  @impl true
  def update(%{leaf: message}, socket), do: {:ok, handle_leaf(message, socket)}

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
    |> assign(:notes, [])
    |> assign(:admin_href, nil)
    |> assign(:timer_armed?, false)
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
    |> load_listing()
    |> assign_admin_href()
  end

  defp load_listing(%{assigns: %{vault: nil}} = socket),
    do: socket |> assign(:folders, []) |> assign(:notes, [])

  defp load_listing(socket) do
    %{vault: vault, current_folder: current} = socket.assigns

    folders =
      vault.uuid
      |> Notes.list_folders()
      |> Enum.filter(&(parent_of(&1.relative_path) == current))

    socket
    |> assign(:folders, folders)
    |> assign(:notes, Notes.list_notes(vault.uuid, folder_path: current))
  end

  defp parent_of(relative_path) do
    case Path.dirname(relative_path) do
      "." -> ""
      parent -> parent
    end
  end

  # Only for someone who could open the vault on the admin pages anyway: the
  # `knowledge_base` permission and a role on this vault. Everyone else is never
  # shown a link to a page that would turn them away.
  #
  # Dialyzer reads the `MapSet` inside the `Scope` that `Scope.for_user/1` builds
  # as breaking its opacity when the struct is handed back to core. Core's own
  # types, not a fault here — a panel is given a user, not a scope, so it has to
  # build one.
  @dialyzer {:nowarn_function, assign_admin_href: 1}
  defp assign_admin_href(%{assigns: %{vault: nil}} = socket), do: assign(socket, :admin_href, nil)

  defp assign_admin_href(%{assigns: %{vault: vault, user: user}} = socket) do
    scope = Scope.for_user(user)

    href =
      if Scope.has_module_access?(scope, "knowledge_base") and Vaults.role_for(vault, scope),
        do: Paths.vault(vault.slug)

    assign(socket, :admin_href, href)
  end

  # The open note's file may have been changed by someone else. Announced,
  # never applied: the editor may hold keystrokes not yet saved, and replacing
  # them behind the writer's back loses them. Reloading is theirs to ask for.
  defp check_open_note(%{assigns: %{note: nil}} = socket), do: socket

  defp check_open_note(%{assigns: %{note: note, vault: vault}} = socket) when not is_nil(vault) do
    case Notes.get_note(vault.uuid, note.uuid) do
      nil ->
        socket |> close_note() |> notice(:info, gettext("That note was moved or deleted."))

      %Note{content_hash: hash} when hash != note.content_hash ->
        assign(socket, :remote_change, true)

      _ ->
        socket
    end
  end

  defp check_open_note(socket), do: socket

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
      if Places.within?(socket.assigns.place, path) do
        socket |> assign(:current_folder, path) |> assign(:creating, nil) |> load_listing()
      else
        socket
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

  def handle_event("rename_note", %{"title" => title}, socket) do
    with_open_note(socket, :edit, fn socket, vault, note ->
      case Notes.rename_note(vault, note, title, actor_uuid: socket.assigns.user.uuid) do
        {:ok, renamed} -> socket |> assign(:note, renamed) |> assign(:renaming?, false)
        {:error, reason} -> notice(socket, :error, error_message(reason))
      end
    end)
  end

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

  # The file changed underneath. Either take theirs…
  def handle_event("reload_note", _params, socket) do
    with_open_note(socket, :view, fn socket, vault, note ->
      case Notes.get_note(vault.uuid, note.uuid) do
        nil ->
          socket |> close_note() |> notice(:info, gettext("That note was moved or deleted."))

        fresh ->
          send_update(Leaf,
            id: editor_id(socket.assigns.id, fresh),
            action: :set_content,
            content: fresh.content || ""
          )

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

  def handle_event("dismiss", _params, socket), do: {:noreply, assign(socket, :notice, nil)}

  # Anything else — an old page's event, a forged one — is ignored. The panel
  # runs in the host's process: a clause error here would take the host's whole
  # page down.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

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
      |> Notes.list_notes(folder_path: folder)
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
  # number is found whatever the language is.
  defp numbered_title_regex do
    [before, after_] =
      case String.split(gettext("Note %{number}", number: "\0"), "\0", parts: 2) do
        [before, after_] -> [before, after_]
        _ -> ["Note ", ""]
      end

    Regex.compile!("^" <> Regex.escape(before) <> "(\\d+)" <> Regex.escape(after_) <> "$", "u")
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

  defp fenced_notes(%{assigns: %{vault: vault, place: place}}) do
    Notes.list_notes(vault.uuid, under: place.folder, order: :updated)
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

  defp error_message(:unauthorized), do: gettext("You cannot do that here.")
  defp error_message(:already_exists), do: gettext("Something with that name is already here.")
  defp error_message(:blank), do: gettext("Give it a name.")

  defp error_message({:forbidden_characters, chars}),
    do: gettext("A name cannot contain %{characters}.", characters: Enum.join(chars, " "))

  defp error_message(:leading_dot), do: gettext("A name cannot start with a dot.")
  defp error_message(:trailing_dot), do: gettext("A name cannot end with a dot.")
  defp error_message(:too_long), do: gettext("That name is too long.")
  defp error_message(:reserved), do: gettext("That name is reserved by the operating system.")
  defp error_message({:folder, reason}), do: error_message(reason)
  defp error_message(%Ecto.Changeset{}), do: gettext("These notes could not be set up.")
  defp error_message(other), do: gettext("That did not work (%{reason}).", reason: inspect(other))

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
      class={["rounded-box border border-base-300 bg-base-100 p-3 sm:p-4 space-y-3 min-w-0", @class]}
    >
      <header class="flex flex-wrap items-center justify-between gap-2">
        <h2 :if={@show_label?} class="font-semibold truncate min-w-0">
          {@label || List.last(@place.path)}
        </h2>
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

      <%= if @can_view? do %>
        <%= if @note do %>
          {render_note(assigns)}
        <% else %>
          {render_listing(assigns)}
        <% end %>
      <% end %>
    </section>
    """
  end

  defp render_listing(assigns) do
    ~H"""
    <div class="space-y-2">
      <nav
        :if={crumbs(@place, @current_folder) != []}
        class="flex flex-wrap items-center gap-1 text-sm"
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

      <ul class="divide-y divide-base-200">
        <li :for={folder <- @folders}>
          <button
            type="button"
            phx-click="open_folder"
            phx-value-path={folder.relative_path}
            phx-target={@myself}
            class="flex w-full items-center gap-2 py-2 text-left hover:bg-base-200 rounded px-1"
          >
            <.icon name="hero-folder" class="w-4 h-4 shrink-0 text-base-content/60" />
            <span class="truncate">{folder.name}</span>
          </button>
        </li>
        <li :for={note <- @notes}>
          <button
            type="button"
            phx-click="open_note"
            phx-value-uuid={note.uuid}
            phx-target={@myself}
            class="flex w-full items-center gap-2 py-2 text-left hover:bg-base-200 rounded px-1"
          >
            <.icon name="hero-document-text" class="w-4 h-4 shrink-0 text-base-content/60" />
            <span class="truncate flex-1">{note.title}</span>
            <time
              class="text-xs text-base-content/50 shrink-0"
              datetime={DateTime.to_iso8601(note.updated_at)}
            >
              {short_date(note.updated_at)}
            </time>
          </button>
        </li>
      </ul>

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
          class="input input-sm input-bordered flex-1 min-w-0"
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

      <div :if={@can_edit? and is_nil(@creating)} class="flex gap-2">
        <button
          type="button"
          phx-click="new_note"
          phx-target={@myself}
          class="btn btn-sm btn-primary"
        >
          <.icon name="hero-document-plus" class="w-4 h-4" /> {gettext("Note")}
        </button>
        <button
          type="button"
          phx-click="start"
          phx-value-what="folder"
          phx-target={@myself}
          class="btn btn-sm btn-ghost"
        >
          <.icon name="hero-folder-plus" class="w-4 h-4" /> {gettext("Folder")}
        </button>
      </div>
    </div>
    """
  end

  defp render_note(assigns) do
    ~H"""
    <article class="space-y-2">
      <div class="flex flex-wrap items-center gap-2">
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

        <form
          :if={@renaming?}
          id={"#{@id}-rename"}
          phx-submit="rename_note"
          phx-target={@myself}
          class="flex flex-1 min-w-0 gap-2"
        >
          <input
            type="text"
            name="title"
            value={@note.title}
            class="input input-sm input-bordered flex-1 min-w-0"
            autofocus
            required
          />
          <button type="submit" class="btn btn-sm btn-primary">{gettext("Rename")}</button>
          <button type="button" phx-click="cancel" phx-target={@myself} class="btn btn-sm btn-ghost">
            {gettext("Cancel")}
          </button>
        </form>

        <button
          :if={not @renaming? and @can_edit?}
          type="button"
          phx-click="start_rename"
          phx-target={@myself}
          class="font-medium truncate flex-1 min-w-0 text-left hover:underline decoration-dotted"
          title={gettext("Rename")}
        >
          {@note.title}
        </button>
        <h3 :if={not @renaming? and not @can_edit?} class="font-medium truncate flex-1 min-w-0">
          {@note.title}
        </h3>

        <span :if={not @renaming?} class={["badge badge-sm", save_class(@save_status)]}>
          {save_label(@save_status)}
        </span>

        <div :if={@can_edit? and not @renaming?} class="flex gap-1">
          <button
            type="button"
            phx-click="start_rename"
            phx-target={@myself}
            class="btn btn-ghost btn-xs"
            title={gettext("Rename")}
            aria-label={gettext("Rename")}
          >
            <.icon name="hero-pencil" class="w-4 h-4" />
          </button>
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

      <div :if={not leaf_notify?()} class="space-y-2">
        <p class="text-xs text-base-content/60">
          {gettext("Editing here needs Leaf 0.11 or later; this is the note as saved.")}
        </p>
        <pre class="whitespace-pre-wrap break-words text-sm rounded-box bg-base-200 p-3">{@content}</pre>
      </div>

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

  # "05 Nov", with the month in the reader's language.
  defp short_date(datetime) do
    Calendar.strftime(datetime, "%d %b", abbreviated_month_names: &month_abbreviation/1)
  end

  defp month_abbreviation(1), do: pgettext("month", "Jan")
  defp month_abbreviation(2), do: pgettext("month", "Feb")
  defp month_abbreviation(3), do: pgettext("month", "Mar")
  defp month_abbreviation(4), do: pgettext("month", "Apr")
  defp month_abbreviation(5), do: pgettext("month", "May")
  defp month_abbreviation(6), do: pgettext("month", "Jun")
  defp month_abbreviation(7), do: pgettext("month", "Jul")
  defp month_abbreviation(8), do: pgettext("month", "Aug")
  defp month_abbreviation(9), do: pgettext("month", "Sep")
  defp month_abbreviation(10), do: pgettext("month", "Oct")
  defp month_abbreviation(11), do: pgettext("month", "Nov")
  defp month_abbreviation(12), do: pgettext("month", "Dec")

  # The vault page's configs, with their popup headings in the reader's language.
  defp suggestion_configs do
    Enum.map(VaultLive.suggestion_configs(), fn
      %{label: "Notes"} = config -> %{config | label: gettext("Notes")}
      %{label: "Tags"} = config -> %{config | label: gettext("Tags")}
      config -> config
    end)
  end

  defp save_label(:saved), do: gettext("Saved")
  defp save_label(:unsaved), do: gettext("Not saved")

  defp save_class(:saved), do: "badge-ghost"
  defp save_class(:unsaved), do: "badge-warning"
end
