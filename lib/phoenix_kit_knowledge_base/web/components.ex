defmodule PhoenixKitKnowledgeBase.Web.Components do
  @moduledoc """
  Function components to drop into a host app's pages.

      <PhoenixKitKnowledgeBase.Web.Components.notes_panel
        id="client-notes"
        current_user={@current_scope.user}
        path={["CRM", "Clients", @client.id]}
        label="Notes"
      />

  See `PhoenixKitKnowledgeBase.Web.NotesPanel` for every attribute.
  """
  use Phoenix.Component

  attr(:id, :string, required: true)
  attr(:current_user, :any, required: true)
  attr(:path, :list, required: true)
  attr(:label, :string, default: nil)
  attr(:show_label, :boolean, default: true)
  attr(:visibility_options, :list, default: [:private, :shared])
  attr(:default_visibility, :atom, default: :shared, values: [:private, :shared])
  attr(:poll, :integer, default: 5_000)
  attr(:class, :string, default: nil)

  @doc "Notes for one place, kept in a vault folder named by `path`. See the module doc."
  def notes_panel(assigns) do
    ~H"""
    <.live_component module={PhoenixKitKnowledgeBase.Web.NotesPanel} {assigns} />
    """
  end
end
