defmodule PhoenixKitKnowledgeBase.Web.MembersLive do
  @moduledoc """
  Per-vault membership (`/admin/knowledge-base/:vault/members`) — who can open a
  vault, and what they can do in it.

  Only a vault owner reaches this page. For a personal vault that is its
  creator; for an organisation vault it is anyone holding
  `knowledge_base.manage_system_vaults`.

  The implicit owner of a personal vault has no row here and cannot be removed,
  which is what stops a vault ending up with nobody able to administer it.
  """
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Users.Auth
  alias PhoenixKitKnowledgeBase.{Paths, Vaults}
  alias PhoenixKitKnowledgeBase.Schemas.VaultMember

  @impl true
  def mount(%{"vault" => slug}, _session, socket) do
    case Vaults.fetch_for(slug, socket.assigns.phoenix_kit_current_scope) do
      {:ok, vault, role} ->
        if Vaults.can?(role, :manage) do
          {:ok,
           socket
           |> assign(:vault, vault)
           |> assign(:page_title, "#{vault.name} · Members")
           |> assign(:page_subtitle, "Who can open this vault")
           |> assign(:query, "")
           |> assign(:candidates, [])
           |> assign(:owner, owner_record(vault))
           |> load_members()}
        else
          {:ok,
           socket
           |> put_flash(:error, "Only a vault owner can manage its members.")
           |> push_navigate(to: Paths.vault(vault.slug))}
        end

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "That vault does not exist, or you do not have access to it.")
         |> push_navigate(to: Paths.vaults())}
    end
  end

  @impl true
  # Gated for the same reason as the mutations below: this returns names and
  # email addresses for every matching account in the install, so a revoked
  # owner with the page still open could go on enumerating the user table.
  # Reading is not exempt from a check that exists because roles change.
  def handle_event("search", %{"value" => query}, socket) do
    candidates =
      with :ok <- require_manage(socket),
           trimmed when trimmed != "" <- String.trim(query) do
        Vaults.search_candidates(socket.assigns.vault, trimmed)
      else
        _ -> []
      end

    {:noreply, socket |> assign(:query, query) |> assign(:candidates, candidates)}
  end

  def handle_event("add_member", %{"user" => user_uuid, "role" => role}, socket) do
    with :ok <- require_manage(socket),
         {:ok, _member} <- Vaults.put_member(socket.assigns.vault, user_uuid, role) do
      {:noreply,
       socket
       |> assign(:query, "")
       |> assign(:candidates, [])
       |> load_members()}
    else
      {:error, :unauthorized} -> {:noreply, unauthorized(socket)}
      _ -> {:noreply, put_flash(socket, :error, "Could not add that person.")}
    end
  end

  def handle_event("update_role", %{"member" => member_uuid, "role" => role}, socket) do
    with :ok <- require_manage(socket),
         %VaultMember{} = member <- Vaults.get_member(socket.assigns.vault, member_uuid),
         {:ok, _updated} <- Vaults.put_member(socket.assigns.vault, member.user_uuid, role) do
      {:noreply, load_members(socket)}
    else
      {:error, :unauthorized} -> {:noreply, unauthorized(socket)}
      _ -> {:noreply, put_flash(socket, :error, "Could not change that role.")}
    end
  end

  def handle_event("remove_member", %{"member" => member_uuid}, socket) do
    with :ok <- require_manage(socket),
         %VaultMember{} = member <- Vaults.get_member(socket.assigns.vault, member_uuid),
         {:ok, _} <- Vaults.remove_member(member) do
      {:noreply, load_members(socket)}
    else
      {:error, :unauthorized} -> {:noreply, unauthorized(socket)}
      _ -> {:noreply, put_flash(socket, :error, "Could not remove that member.")}
    end
  end

  # `mount/3` proves the role once. These events grant and revoke access to the
  # vault, and this LiveView can stay open for hours — long enough for the
  # ownership that opened it to have been taken away. Re-resolving from the
  # current scope on every mutation is the same rule `IndexLive.delete_vault`
  # already follows: trust the scope, never the page that rendered the button.
  defp require_manage(socket) do
    with {:ok, _vault, role} <-
           Vaults.fetch_for(socket.assigns.vault.slug, socket.assigns.phoenix_kit_current_scope),
         true <- Vaults.can?(role, :manage) do
      :ok
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp unauthorized(socket) do
    socket
    |> put_flash(:error, "Only a vault owner can manage its members.")
    |> push_navigate(to: Paths.vault(socket.assigns.vault.slug))
  end

  defp load_members(socket) do
    assign(socket, :members, Vaults.list_members(socket.assigns.vault))
  end

  defp owner_record(%{scope: "user", owner_uuid: owner_uuid}) when not is_nil(owner_uuid) do
    Auth.get_user!(owner_uuid)
  rescue
    _ -> nil
  end

  defp owner_record(_vault), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-3xl px-4 py-6 space-y-6">
      <div class="flex items-center gap-2">
        <.link navigate={Paths.vault(@vault.slug)} class="btn btn-ghost btn-xs">
          <.icon name="hero-arrow-left" class="w-4 h-4" />
        </.link>
        <div>
          <h1 class="text-xl font-semibold">{@vault.name} · Members</h1>
          <p class="text-sm text-base-content/60">
            {if @vault.scope == "system",
              do:
                "An organisation vault. Anyone who can manage organisation vaults is already an owner — members listed here are additional people.",
              else: "A personal vault. Nobody sees it unless they are listed here."}
          </p>
        </div>
      </div>

      <section class="card bg-base-100 border border-base-300">
        <div class="card-body gap-3">
          <h2 class="font-medium">Add someone</h2>

          <form phx-change="search" id="kb-member-search" phx-submit="search">
            <input
              type="text"
              name="value"
              value={@query}
              phx-debounce="300"
              placeholder="Search by name, username or email…"
              autocomplete="off"
              class="input input-sm input-bordered w-full"
            />
          </form>

          <p :if={@query != "" and @candidates == []} class="text-sm text-base-content/50">
            No matches. Search needs at least two characters, and people already on the list are hidden.
          </p>

          <ul :if={@candidates != []} class="divide-y divide-base-200">
            <li :for={user <- @candidates} class="flex items-center justify-between gap-3 py-2">
              <div class="min-w-0">
                <p class="text-sm truncate">{Vaults.user_label(user)}</p>
                <p class="text-xs text-base-content/50 truncate">{user.email}</p>
              </div>
              <div class="flex gap-1 shrink-0">
                <button
                  :for={role <- ["viewer", "editor", "owner"]}
                  type="button"
                  phx-click="add_member"
                  phx-value-user={user.uuid}
                  phx-value-role={role}
                  class="btn btn-xs btn-outline"
                >
                  {role}
                </button>
              </div>
            </li>
          </ul>
        </div>
      </section>

      <section class="card bg-base-100 border border-base-300">
        <div class="card-body gap-3">
          <h2 class="font-medium">Members</h2>

          <div
            :if={@owner}
            class="flex items-center justify-between gap-3 py-2 border-b border-base-200"
          >
            <div class="min-w-0">
              <p class="text-sm truncate">{Vaults.user_label(@owner)}</p>
              <p class="text-xs text-base-content/50 truncate">{@owner.email}</p>
            </div>
            <span
              class="badge badge-sm badge-primary shrink-0"
              title="The vault's creator — cannot be removed"
            >
              owner
            </span>
          </div>

          <p :if={@members == []} class="text-sm text-base-content/50 italic">
            {if @owner, do: "Nobody else has access.", else: "No members yet."}
          </p>

          <ul :if={@members != []} class="divide-y divide-base-200">
            <li :for={entry <- @members} class="flex items-center justify-between gap-3 py-2">
              <div class="min-w-0">
                <p class="text-sm truncate">{Vaults.user_label(entry.user)}</p>
                <p class="text-xs text-base-content/50 truncate">
                  {entry.user && entry.user.email}
                </p>
              </div>

              <div class="flex items-center gap-2 shrink-0">
                <form phx-change="update_role" id={"kb-role-#{entry.member.uuid}"}>
                  <input type="hidden" name="member" value={entry.member.uuid} />
                  <select name="role" class="select select-xs select-bordered">
                    <option
                      :for={role <- VaultMember.roles()}
                      value={role}
                      selected={entry.member.role == role}
                    >
                      {role}
                    </option>
                  </select>
                </form>

                <button
                  type="button"
                  phx-click="remove_member"
                  phx-value-member={entry.member.uuid}
                  data-confirm={"Remove #{Vaults.user_label(entry.user)} from this vault?"}
                  class="btn btn-ghost btn-xs text-error"
                  aria-label="Remove member"
                >
                  <.icon name="hero-x-mark" class="w-4 h-4" />
                </button>
              </div>
            </li>
          </ul>
        </div>
      </section>
    </div>
    """
  end
end
