defmodule PhoenixKitKnowledgeBase do
  @moduledoc """
  An Obsidian-style linked knowledge base for PhoenixKit, backed by real
  markdown files.

  Admins open **Knowledge Base** in the sidebar, create a vault, and write
  markdown notes in it. Notes live in a folder tree, carry tags, and link to one
  another with `[[wiki-links]]`; each note shows what links back to it, and the
  vault keeps a running list of everything linked to but not yet written.

  ## Files are the source of truth

  A vault is a directory. A folder is a directory. A note is a `<Title>.md`
  file — the filename *is* the title, exactly as in Obsidian. So `rg`, `git`,
  `pandoc`, `vim` and Obsidian itself all work on the tree directly, and nothing
  you write is trapped in a database.

      <root>/system/<vault-slug>/…                 organisation vaults
      <root>/users/<email-slug>/<vault-slug>/…     personal vaults

  Postgres is an **index** of those files: cached content for full-text search,
  parsed front matter, tags, and the whole link graph. Delete the tables and a
  rescan rebuilds every bit of it from the markdown.

  ## Keeping the index honest, without a watcher

  There is no filesystem watcher. Edits made through the web UI index
  themselves; edits made anywhere else are picked up by **Rescan** — the button
  on a vault, or `mix phoenix_kit_knowledge_base.rescan` from a shell or a cron
  job. A rescan compares `(mtime, size)` first and only hashes what looks
  changed, and it recognises a moved file by content hash so an external `mv`
  keeps the note's uuid, its permalink and every backlink into it.

  Two things follow from having no watcher, and both are handled rather than
  hoped about:

    * **The web UI never clobbers an external edit.** Every save first compares
      the file's hash with the indexed one and refuses if they differ, offering
      to reload or to overwrite deliberately.
    * **Titles are not unique.** The filesystem allows `research/Ideas.md` and
      `archive/Ideas.md`, so the index describes that rather than rejecting it.
      `[[Ideas]]` resolves to a note in the same folder first, then the shortest
      path; `[[research/Ideas]]` says exactly which one you meant.

  ## Two browsers, two people

  Every vault page subscribes to a PubSub topic for that vault, so a note added,
  renamed, saved or deleted anywhere — including by `mix
  phoenix_kit_knowledge_base.rescan` in a terminal — reaches every open session.
  A note being *read* is refreshed in place; a note being *edited* raises a
  banner instead, because the buffer may hold unsaved keystrokes.

  Concurrent edits to the same note are **detected, not merged**: the second
  writer is stopped by the stale-write guard and given an explicit choice
  between reloading and overwriting. Two people on *different* notes in a shared
  vault is the case this supports well; two people in the same note at the same
  time wants a CRDT, which this is not.

  ## Vaults

  A vault is the namespace links resolve in — `[[Foo]]` never crosses a vault
  boundary.

    * **System vaults** are org-wide, created by anyone holding
      `knowledge_base.manage_system_vaults`, who are implicitly owners of all of
      them.
    * **Personal vaults** belong to one person. Nobody else sees a personal
      vault in the app — not even an org Owner — unless its owner adds them as a
      member.

  Both share one membership model (`owner` / `editor` / `viewer`), and
  `PhoenixKitKnowledgeBase.Vaults` is the single place that decides any of it.

  Note the limit of that, plainly: membership is enforced **in the application**.
  The notes are files, so anyone with shell access to the server can read every
  vault. That is inherent to storing notes as files, not a gap to be closed
  here.

  ## Zero host setup

  The editor is [Leaf](https://hex.pm/packages/leaf) — the same one PhoenixKit
  uses elsewhere — in its Obsidian-style hybrid live-preview mode, with `[[`
  and `#` inline-suggestion triggers. Rendering goes through core's MDEx +
  sanitizer, so this module ships no JavaScript and asks the host for nothing
  beyond the dependency and a root path.

  Note how Leaf's own bundle arrives: core's vendored `phoenix_kit.js`
  registers a placeholder hook that lazy-loads `leaf.js` from jsDelivr on first
  mount. That is core's mechanism, but it means the browser must be able to
  reach the CDN and a strict `script-src` CSP must allow it. Loading a vendored
  `leaf.js` before `app.js` short-circuits the loader. `css_sources/0` is declared so a host running core's Tailwind source
  compiler picks up the classes used here.

  ## Installation

      # host mix.exs
      {:phoenix_kit_knowledge_base, "~> 0.1"}

      # host config
      config :phoenix_kit_knowledge_base,
        root: Path.expand("../priv/knowledge_base", __DIR__)

  Then `mix deps.get` and `mix phoenix_kit.update` (creates the five
  `phoenix_kit_kb_*` index tables). Enable it on the admin Modules page.

  To adopt notes you already have, move or symlink the directory into place
  under the root, create a vault with the matching slug, and press Rescan.
  """

  use PhoenixKit.Module

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.Settings

  # ── Required callbacks ─────────────────────────────────────────────────

  @impl PhoenixKit.Module
  def module_key, do: "knowledge_base"

  @impl PhoenixKit.Module
  def module_name, do: "Knowledge Base"

  @impl PhoenixKit.Module
  @doc """
  Whether the module is on.

  Rescues and returns `false` because this is called before migrations have
  necessarily run — a settings table that doesn't exist yet must read as
  "disabled", not crash host startup.
  """
  def enabled? do
    Settings.get_boolean_setting("knowledge_base_enabled", false)
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  @impl PhoenixKit.Module
  def enable_system,
    do: Settings.update_boolean_setting_with_module("knowledge_base_enabled", true, module_key())

  @impl PhoenixKit.Module
  def disable_system,
    do: Settings.update_boolean_setting_with_module("knowledge_base_enabled", false, module_key())

  # ── Optional callbacks ─────────────────────────────────────────────────

  @impl PhoenixKit.Module
  def version, do: "0.1.0"

  @impl PhoenixKit.Module
  @doc """
  The base `knowledge_base` permission opens the section; the sub-permission
  decides who may create and administer **system** vaults.

  Note what the sub-permission deliberately does not grant: access to other
  people's personal vaults. See `PhoenixKitKnowledgeBase.Vaults`.
  """
  def permission_metadata do
    %{
      key: module_key(),
      label: "Knowledge Base",
      icon: "hero-book-open",
      description: "Linked markdown notes organised into vaults",
      sub_permissions: [
        %{
          key: "manage_system_vaults",
          label: "Manage system vaults",
          description:
            "Create, administer and delete organisation-wide vaults. Does not grant access to other users' personal vaults."
        }
      ]
    }
  end

  @impl PhoenixKit.Module
  def admin_tabs do
    # Multi-page module: routes come from `route_module/0`, so the tab carries
    # no `:live_view` — it is the sidebar entry and active-state anchor only.
    [
      %Tab{
        id: :admin_knowledge_base,
        label: "Knowledge Base",
        icon: "hero-book-open",
        path: "knowledge-base",
        priority: 650,
        level: :admin,
        permission: module_key(),
        match: :prefix,
        group: :admin_modules
      }
    ]
  end

  @impl PhoenixKit.Module
  @doc "Multi-page routing (vaults, workspace, members) — see `PhoenixKitKnowledgeBase.Routes`."
  def route_module, do: PhoenixKitKnowledgeBase.Routes

  @impl PhoenixKit.Module
  @doc "The `phoenix_kit_kb_*` table coordinator (run by `mix phoenix_kit.update`)."
  def migration_module, do: PhoenixKitKnowledgeBase.Migrations

  @impl PhoenixKit.Module
  @doc "Tailwind scans this app's templates for the classes the knowledge base UI uses."
  def css_sources, do: [:phoenix_kit_knowledge_base]

  @impl PhoenixKit.Module
  @doc """
  The registry and dynamic supervisor behind live editing.

  Core starts these under its own supervisor, so the host needs no setup. They
  start whether or not this module is enabled — `children/0` is collected
  statically, before anything can ask the database — but an empty registry and
  an idle `DynamicSupervisor` cost nothing until somebody opens a note.

  See `PhoenixKitKnowledgeBase.Collab`.
  """
  def children, do: PhoenixKitKnowledgeBase.Collab.children()

  @impl PhoenixKit.Module
  @doc """
  Config for the admin Modules page.

  Only `enabled?/0` — this runs on every render of that page, and counting
  vaults or notes would add a query per page load for a number nobody reads
  there.
  """
  def get_config, do: %{enabled: enabled?()}
end
