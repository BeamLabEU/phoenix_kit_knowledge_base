defmodule PhoenixKitKnowledgeBase.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/BeamLabEU/phoenix_kit_knowledge_base"

  def project do
    [
      app: :phoenix_kit_knowledge_base,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),

      # Hex
      description:
        "Obsidian-style linked markdown knowledge base for PhoenixKit — multi-vault notes with folders, tags, [[wiki-links]], backlinks and full-text search.",
      package: package(),

      # Dialyzer
      dialyzer: [plt_add_apps: [:phoenix_kit, :mix]],

      # Docs
      name: "PhoenixKitKnowledgeBase",
      source_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    # `:phoenix_kit` in extra_applications is REQUIRED for ModuleDiscovery to
    # find this module's `.beam` at host startup. Without it the module never
    # registers and every route 404s.
    [
      extra_applications: [:logger, :phoenix_kit]
    ]
  end

  # test/support/ is compiled only in :test so the test repo and case helpers
  # don't leak into the published package.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      quality: ["format", "credo --strict", "dialyzer"],
      "quality.ci": ["format --check-formatted", "credo --strict", "dialyzer"],
      precommit: [
        "compile --force --warnings-as-errors",
        "deps.unlock --check-unused",
        "cmd mix hex.audit",
        "quality.ci"
      ]
    ]
  end

  # phoenix_kit resolves from Hex by default; export PHOENIX_KIT_PATH=../phoenix_kit
  # for cross-repo work against a local checkout. Unset => the published pin, so
  # `mix hex.publish` is unaffected.
  defp pk_dep(app, requirement, opts \\ []) do
    env_var = String.upcase(Atom.to_string(app)) <> "_PATH"

    case System.get_env(env_var) do
      nil when opts == [] -> {app, requirement}
      nil -> {app, requirement, opts}
      path -> {app, [path: path, override: true] ++ opts}
    end
  end

  defp deps do
    [
      # Core supplies the Module behaviour, Settings, Scope/permissions,
      # SchemaPrefix, the MarkdownEditor LiveComponent and the migration
      # helpers this module's coordinator calls
      # (`Migrations.Postgres.Helpers.uuid_v7_call/1`).
      # `~> 2.14` because 2.14.0 is the first published core carrying both
      # `FolderExplorer`'s `items` attr / `:item` slot (2.13.15+) and the
      # `<.context_menu>` components the vault tree's right-click menus use.
      # An older locked core fails at compile time, which is the good failure
      # mode — at runtime it would be an undefined-slot raise on render.
      pk_dep(:phoenix_kit, "~> 2.14"),

      # Markdown -> HTML for note rendering. Core already depends on MDEx and
      # pins the version; this constraint only has to agree with it.
      {:mdex, "~> 0.13"},
      # Builds MDEx's Rust NIF from source on OTP versions with no compatible
      # precompiled artifact. Optional: pulled only to compile the NIF.
      {:rustler, ">= 0.0.0", optional: true},

      # YAML front matter (Obsidian "properties"). Core happens to pull this in
      # transitively, but a transitive dep is not a contract — declared here so
      # this module keeps compiling if core ever drops it.
      {:yaml_elixir, "~> 2.9"},
      # Alex Dontsov's Leaf — the markdown editor PhoenixKit itself uses. Core
      # already vendors its JS into `phoenix_kit.js` and registers the hook on
      # `window.PhoenixKitHooks`, so this needs no host setup; the dependency is
      # declared because this module calls `Leaf` directly rather than relying
      # on it arriving transitively through core.
      pk_dep(:leaf, "~> 0.5"),
      {:phoenix_live_view, "~> 1.1"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "PhoenixKitKnowledgeBase",
      extras: ["README.md", "CHANGELOG.md"],
      source_ref: "v#{@version}"
    ]
  end
end
