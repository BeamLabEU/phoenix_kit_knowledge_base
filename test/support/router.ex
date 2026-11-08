defmodule PhoenixKitKnowledgeBase.Test.Router do
  @moduledoc """
  The admin pages, routed the way `PhoenixKitKnowledgeBase.Routes` declares
  them, at the paths `Paths` generates in the test environment — so a
  `push_patch` from a page lands on a route here.

  Core's admin `live_session` (authentication, the admin layout, the header
  bar) is not reproduced. What a page needs from it is the scope, which
  `ScopeHook` puts where core's `on_mount` would. The header toolbar is core's
  to render, so it is tested as a component instead.
  """
  use Phoenix.Router

  import Phoenix.LiveView.Router

  alias PhoenixKitKnowledgeBase.Web.{IndexLive, MembersLive, VaultLive}

  pipeline :browser do
    plug(:fetch_session)
  end

  scope "/phoenix_kit/admin/knowledge-base" do
    pipe_through(:browser)

    live_session :kb_test, on_mount: PhoenixKitKnowledgeBase.Test.ScopeHook do
      live("/", IndexLive, :index)
      live("/:vault", VaultLive, :index)
      live("/:vault/members", MembersLive, :index)
      live("/:vault/notes/new", VaultLive, :new)
      live("/:vault/notes/:id", VaultLive, :show)
    end
  end
end

defmodule PhoenixKitKnowledgeBase.Test.ScopeHook do
  @moduledoc "Assigns `phoenix_kit_current_scope` from the session's `user_uuid`, and the locale from `locale`, as core's admin hook does."
  import Phoenix.Component, only: [assign: 3]

  alias PhoenixKit.Users.Auth.{Scope, User}
  alias PhoenixKitKnowledgeBase.Test.Repo

  def on_mount(:default, _params, session, socket) do
    user = session["user_uuid"] && Repo.get(User, session["user_uuid"])
    # Core's admin hook sets the locale per request; so does this.
    if locale = session["locale"], do: Gettext.put_locale(locale)

    {:cont,
     socket
     |> assign(:phoenix_kit_current_user, user)
     |> assign(:phoenix_kit_current_scope, Scope.for_user(user))}
  end
end
