defmodule PhoenixKitKnowledgeBase.Web.IndexLive do
  @moduledoc """
  The vault list (`/admin/knowledge-base`) — every vault this user may open,
  split into the three groups that mean different things: organisation-wide
  vaults, your own, and personal vaults other people have shared with you.

  PhoenixKit applies the admin layout automatically.
  """
  use PhoenixKitWeb, :live_view

  alias PhoenixKitKnowledgeBase.{Notes, Paths, Vaults}
  alias PhoenixKitKnowledgeBase.Schemas.Vault

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Knowledge Base")
     |> assign(:page_subtitle, "Linked markdown notes, organised into vaults")
     |> assign(:creating, nil)
     |> assign(:form, to_form(Vaults.change(%Vault{})))
     |> load_vaults()}
  end

  @impl true
  def handle_event("new_vault", %{"kind" => kind}, socket) do
    kind = if kind == "system", do: :system, else: :user

    if kind == :system and not socket.assigns.can_manage_system do
      {:noreply, put_flash(socket, :error, "You cannot create organisation vaults.")}
    else
      {:noreply,
       socket
       |> assign(:creating, kind)
       |> assign(:form, to_form(Vaults.change(%Vault{})))}
    end
  end

  def handle_event("cancel_new_vault", _params, socket) do
    {:noreply, assign(socket, :creating, nil)}
  end

  def handle_event("validate_vault", %{"vault" => params}, socket) do
    # `action: :validate` so errors render while typing instead of only after
    # a failed submit.
    changeset =
      %Vault{} |> Vaults.change(vault_defaults(params, socket)) |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save_vault", %{"vault" => params}, socket) do
    kind = socket.assigns.creating || :user

    case Vaults.create(params, socket.assigns.phoenix_kit_current_scope, kind) do
      {:ok, vault} ->
        {:noreply, push_navigate(socket, to: Paths.vault(vault.slug))}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You cannot create that kind of vault.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(Map.put(changeset, :action, :insert)))}

      other ->
        {:noreply, put_flash(socket, :error, "Could not create the vault: #{inspect(other)}")}
    end
  end

  def handle_event("delete_vault", %{"slug" => slug}, socket) do
    # Re-resolve the role here rather than trusting the button that was
    # rendered: a stale page (or a hand-made event) must not be able to delete
    # a vault this user only ever had read access to.
    with {:ok, vault, role} <- Vaults.fetch_for(slug, socket.assigns.phoenix_kit_current_scope),
         true <- Vaults.can?(role, :manage),
         {:ok, _} <- Vaults.delete(vault) do
      {:noreply,
       socket
       |> put_flash(
         :info,
         "Removed “#{vault.name}”. Its files are still on disk at #{vault.directory}."
       )
       |> load_vaults()}
    else
      _ -> {:noreply, put_flash(socket, :error, "You cannot delete that vault.")}
    end
  end

  defp vault_defaults(params, socket) do
    # The scope/owner pair is validated by the changeset, so the preview
    # changeset has to carry the same values `Vaults.create/3` will set —
    # otherwise the form shows an owner error for a vault that would save fine.
    case socket.assigns.creating do
      :system -> Map.merge(params, %{"scope" => "system", "owner_uuid" => nil})
      _ -> Map.merge(params, %{"scope" => "user", "owner_uuid" => current_user_uuid(socket)})
    end
  end

  defp load_vaults(socket) do
    scope = socket.assigns.phoenix_kit_current_scope
    user_uuid = current_user_uuid(socket)

    entries =
      scope
      |> Vaults.list_visible_with_roles()
      |> Enum.map(fn {vault, role} ->
        %{vault: vault, role: role, note_count: Notes.count_notes(vault.uuid)}
      end)

    socket
    |> assign(:can_manage_system, Vaults.can_manage_system_vaults?(scope))
    |> assign(:system_vaults, Enum.filter(entries, &(&1.vault.scope == "system")))
    |> assign(:my_vaults, Enum.filter(entries, &own_vault?(&1.vault, user_uuid)))
    |> assign(:shared_vaults, Enum.filter(entries, &shared_vault?(&1.vault, user_uuid)))
  end

  defp own_vault?(%Vault{scope: "user", owner_uuid: owner}, user_uuid), do: owner == user_uuid
  defp own_vault?(_vault, _user_uuid), do: false

  defp shared_vault?(%Vault{scope: "user", owner_uuid: owner}, user_uuid), do: owner != user_uuid
  defp shared_vault?(_vault, _user_uuid), do: false

  defp current_user_uuid(socket) do
    case socket.assigns[:phoenix_kit_current_user] do
      %{uuid: uuid} ->
        uuid

      _ ->
        get_in(socket.assigns, [
          Access.key(:phoenix_kit_current_scope),
          Access.key(:user),
          Access.key(:uuid)
        ])
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-6xl px-4 py-6 space-y-8">
      <div class="flex flex-wrap items-start justify-between gap-4">
        <div>
          <h1 class="text-2xl font-semibold">Knowledge Base</h1>
          <p class="text-sm text-base-content/60">
            Each vault is its own space — <code>[[wiki-links]]</code>
            resolve inside a vault, never across.
          </p>
        </div>

        <div class="flex gap-2">
          <button
            type="button"
            phx-click="new_vault"
            phx-value-kind="user"
            class="btn btn-primary btn-sm"
          >
            <.icon name="hero-plus" class="w-4 h-4" /> New vault
          </button>
          <button
            :if={@can_manage_system}
            type="button"
            phx-click="new_vault"
            phx-value-kind="system"
            class="btn btn-outline btn-sm"
          >
            <.icon name="hero-building-office-2" class="w-4 h-4" /> New organisation vault
          </button>
        </div>
      </div>

      <div :if={@creating} class="card bg-base-100 border border-base-300 shadow-sm">
        <div class="card-body gap-4">
          <h2 class="font-medium">
            {if @creating == :system, do: "New organisation vault", else: "New personal vault"}
          </h2>
          <p class="text-sm text-base-content/60">
            {if @creating == :system,
              do:
                "Visible to everyone who can administer organisation vaults, plus anyone you add as a member.",
              else:
                "Private to you until you add members — administrators do not get access automatically."}
          </p>

          <.form for={@form} id="new-vault-form" phx-change="validate_vault" phx-submit="save_vault">
            <div class="grid gap-4 sm:grid-cols-2">
              <.input field={@form[:name]} type="text" label="Name" placeholder="Research" required />
              <.input
                field={@form[:slug]}
                type="text"
                label="URL slug"
                placeholder="derived from the name"
              />
              <div class="sm:col-span-2">
                <.textarea
                  field={@form[:description]}
                  label="Description"
                  rows="2"
                  placeholder="What lives in this vault?"
                />
              </div>
            </div>

            <div class="flex justify-end gap-2 mt-4">
              <button type="button" phx-click="cancel_new_vault" class="btn btn-ghost btn-sm">
                Cancel
              </button>
              <button type="submit" class="btn btn-primary btn-sm">Create vault</button>
            </div>
          </.form>
        </div>
      </div>

      <.vault_section
        title="Organisation vaults"
        subtitle="Shared across the whole organisation"
        entries={@system_vaults}
        empty="No organisation vaults yet."
      />

      <.vault_section
        title="My vaults"
        subtitle="Private to you unless you add members"
        entries={@my_vaults}
        empty="You have no personal vaults yet."
      />

      <.vault_section
        :if={@shared_vaults != []}
        title="Shared with me"
        subtitle="Personal vaults other people have given you access to"
        entries={@shared_vaults}
        empty=""
      />
    </div>
    """
  end

  attr :title, :string, required: true
  attr :subtitle, :string, required: true
  attr :entries, :list, required: true
  attr :empty, :string, required: true

  defp vault_section(assigns) do
    ~H"""
    <section class="space-y-3">
      <div>
        <h2 class="text-lg font-medium">{@title}</h2>
        <p class="text-xs text-base-content/50">{@subtitle}</p>
      </div>

      <p :if={@entries == []} class="text-sm text-base-content/50 italic">{@empty}</p>

      <ul :if={@entries != []} class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
        <li :for={entry <- @entries} class="card bg-base-100 border border-base-300 shadow-sm">
          <div class="card-body p-4 gap-3">
            <div class="flex items-start justify-between gap-2">
              <.link navigate={Paths.vault(entry.vault.slug)} class="flex items-center gap-2 min-w-0">
                <.icon name={entry.vault.icon || "hero-book-open"} class="w-5 h-5 shrink-0" />
                <span class="font-medium truncate hover:underline">{entry.vault.name}</span>
              </.link>
              <span class="badge badge-ghost badge-sm shrink-0">{entry.role}</span>
            </div>

            <p
              :if={entry.vault.description not in [nil, ""]}
              class="text-xs text-base-content/60 line-clamp-2"
            >
              {entry.vault.description}
            </p>

            <div class="flex items-center justify-between gap-2 text-xs text-base-content/50">
              <span>{entry.note_count} {if entry.note_count == 1, do: "note", else: "notes"}</span>

              <div class="flex items-center gap-1">
                <.link
                  :if={PhoenixKitKnowledgeBase.Vaults.can?(entry.role, :manage)}
                  navigate={Paths.members(entry.vault.slug)}
                  class="btn btn-ghost btn-xs"
                >
                  Members
                </.link>
                <button
                  :if={PhoenixKitKnowledgeBase.Vaults.can?(entry.role, :manage)}
                  type="button"
                  phx-click="delete_vault"
                  phx-value-slug={entry.vault.slug}
                  data-confirm={"Remove “#{entry.vault.name}” from the app? The files stay on disk — re-creating the vault with the same name and rescanning brings them back."}
                  class="btn btn-ghost btn-xs text-error"
                  aria-label="Delete vault"
                >
                  <.icon name="hero-trash" class="w-4 h-4" />
                </button>
              </div>
            </div>
          </div>
        </li>
      </ul>
    </section>
    """
  end
end
