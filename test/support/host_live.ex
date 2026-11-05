defmodule PhoenixKitKnowledgeBase.Test.HostLive do
  @moduledoc """
  A page that embeds the notes panel the way a host app would, taking what it
  needs from the test's session: the signed-in user's uuid and the panel's
  options. It has no `handle_info/2` at all, on purpose — a host page that
  never expected the panel's messages must not receive any.
  """
  use Phoenix.LiveView

  alias PhoenixKitKnowledgeBase.Test.Repo

  @impl true
  def mount(_params, session, socket) do
    user =
      case session["user_uuid"] do
        nil -> nil
        uuid -> Repo.get(PhoenixKit.Users.Auth.User, uuid)
      end

    {:ok, assign(socket, user: user, opts: session["opts"] || [])}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main>
      <PhoenixKitKnowledgeBase.Web.Components.notes_panel
        id="panel"
        current_user={@user}
        {Map.new(@opts)}
      />
    </main>
    """
  end
end
