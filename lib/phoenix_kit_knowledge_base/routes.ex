defmodule PhoenixKitKnowledgeBase.Routes do
  @moduledoc """
  Route macros for the knowledge base's four admin pages. Returned from
  `PhoenixKitKnowledgeBase.route_module/0`; PhoenixKit injects these inside the
  admin `live_session`, so authentication and the admin layout are applied
  automatically.

  Both localized (`/:locale/admin/...`) and non-localized sets are defined, as
  required — and each route needs a unique `:as`, hence the `_localized`
  suffixes.

  Ordering matters in one place: `notes/new` is declared before `notes/:id`, or
  the `:id` pattern claims the literal "new" and creating a note 404s looking
  for a note with that uuid.
  """

  @doc "Localized admin routes (inside the /:locale scope)."
  def admin_locale_routes do
    quote do
      live "/admin/knowledge-base", PhoenixKitKnowledgeBase.Web.IndexLive, :index,
        as: :phoenix_kit_knowledge_base_localized

      live "/admin/knowledge-base/:vault", PhoenixKitKnowledgeBase.Web.VaultLive, :index,
        as: :phoenix_kit_kb_vault_localized

      live "/admin/knowledge-base/:vault/members",
           PhoenixKitKnowledgeBase.Web.MembersLive,
           :index, as: :phoenix_kit_kb_members_localized

      # Before `/notes/:id`, which would otherwise claim the literal "new".
      live "/admin/knowledge-base/:vault/notes/new", PhoenixKitKnowledgeBase.Web.VaultLive, :new,
        as: :phoenix_kit_kb_note_new_localized

      live "/admin/knowledge-base/:vault/notes/:id", PhoenixKitKnowledgeBase.Web.VaultLive, :show,
        as: :phoenix_kit_kb_note_localized
    end
  end

  @doc "Non-localized admin routes."
  def admin_routes do
    quote do
      live "/admin/knowledge-base", PhoenixKitKnowledgeBase.Web.IndexLive, :index,
        as: :phoenix_kit_knowledge_base

      live "/admin/knowledge-base/:vault", PhoenixKitKnowledgeBase.Web.VaultLive, :index,
        as: :phoenix_kit_kb_vault

      live "/admin/knowledge-base/:vault/members",
           PhoenixKitKnowledgeBase.Web.MembersLive,
           :index, as: :phoenix_kit_kb_members

      # Before `/notes/:id`, which would otherwise claim the literal "new".
      live "/admin/knowledge-base/:vault/notes/new", PhoenixKitKnowledgeBase.Web.VaultLive, :new,
        as: :phoenix_kit_kb_note_new

      live "/admin/knowledge-base/:vault/notes/:id", PhoenixKitKnowledgeBase.Web.VaultLive, :show,
        as: :phoenix_kit_kb_note
    end
  end
end
