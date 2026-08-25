defmodule PhoenixKitKnowledgeBase.Paths do
  @moduledoc """
  Centralized path helpers. Every link and redirect in this module goes through
  `PhoenixKit.Utils.Routes.path/1`, which applies the host's URL prefix and the
  current locale — PhoenixKit paths are never hardcoded, and relative hrefs
  break as soon as the current URL has one more segment than you assumed.
  """

  alias PhoenixKit.Utils.Routes

  @root "/admin/knowledge-base"

  @doc "The vault list."
  @spec vaults() :: String.t()
  def vaults, do: Routes.path(@root)

  @doc "A vault's workspace."
  @spec vault(String.t()) :: String.t()
  def vault(slug), do: Routes.path("#{@root}/#{slug}")

  @doc "A single note inside a vault."
  @spec note(String.t(), String.t()) :: String.t()
  def note(slug, note_uuid), do: Routes.path("#{@root}/#{slug}/notes/#{note_uuid}")

  @doc """
  The "create this note" page for a title that doesn't exist yet — where an
  unresolved `[[wiki-link]]` points.

  A page with a Create button rather than a URL that creates on GET: a link
  that writes to the database when a browser prefetches it, or when someone
  refreshes, is a trap.
  """
  @spec new_note(String.t(), String.t() | nil) :: String.t()
  def new_note(slug, title \\ nil)
  def new_note(slug, nil), do: Routes.path("#{@root}/#{slug}/notes/new")

  def new_note(slug, title) do
    Routes.path("#{@root}/#{slug}/notes/new") <> "?title=" <> URI.encode_www_form(title)
  end

  @doc "A vault's membership page."
  @spec members(String.t()) :: String.t()
  def members(slug), do: Routes.path("#{@root}/#{slug}/members")
end
