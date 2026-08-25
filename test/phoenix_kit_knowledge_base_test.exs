defmodule PhoenixKitKnowledgeBaseTest do
  @moduledoc """
  Behaviour-compliance checks. No database — these guard the contract
  `PhoenixKit.ModuleDiscovery` and the admin sidebar rely on, which is exactly
  the part that fails silently (a 404, or a tab that never appears) rather than
  raising somewhere you'd look.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Dashboard.Tab

  describe "required callbacks" do
    test "module_key is the stable identifier every other declaration hangs off" do
      assert PhoenixKitKnowledgeBase.module_key() == "knowledge_base"
    end

    test "module_name is a display string" do
      assert PhoenixKitKnowledgeBase.module_name() == "Knowledge Base"
    end

    test "enabled?/0 answers without a database" do
      # Called before migrations run, so it must rescue rather than raise —
      # a crash here takes down host startup.
      assert is_boolean(PhoenixKitKnowledgeBase.enabled?())
    end
  end

  describe "permissions" do
    test "permission_metadata key matches module_key" do
      metadata = PhoenixKitKnowledgeBase.permission_metadata()
      assert metadata.key == PhoenixKitKnowledgeBase.module_key()
    end

    test "declares the system-vault sub-permission" do
      %{sub_permissions: subs} = PhoenixKitKnowledgeBase.permission_metadata()
      assert Enum.any?(subs, &(&1.key == "manage_system_vaults"))
    end

    test "the composed sub-permission key is what Vaults checks" do
      # These two are declared in different modules; if they drift, the
      # permission grants nothing and nobody can create an organisation vault.
      assert PhoenixKitKnowledgeBase.Vaults.manage_system_permission() ==
               "knowledge_base.manage_system_vaults"
    end

    test "sub-permission keys match the format core requires" do
      %{sub_permissions: subs} = PhoenixKitKnowledgeBase.permission_metadata()

      for sub <- subs do
        assert Regex.match?(~r/^[a-z][a-z0-9_]*$/, sub.key)
      end
    end
  end

  describe "admin tabs" do
    test "exposes one prefix-matched tab gated on the module permission" do
      assert [%Tab{} = tab] = PhoenixKitKnowledgeBase.admin_tabs()
      assert tab.id == :admin_knowledge_base
      assert tab.permission == PhoenixKitKnowledgeBase.module_key()
      assert tab.match == :prefix
      assert tab.level == :admin
    end

    test "tab path is a relative hyphenated slug" do
      # Core prepends `/admin/`; an absolute or underscored path lands the tab
      # somewhere other than where the routes are declared.
      [tab] = PhoenixKitKnowledgeBase.admin_tabs()
      assert tab.path == "knowledge-base"
      refute String.starts_with?(tab.path, "/")
    end

    test "the tab carries no live_view, because routing comes from route_module" do
      # Setting both would register the path twice; core keeps the first and
      # the other silently never runs.
      [tab] = PhoenixKitKnowledgeBase.admin_tabs()
      assert is_nil(tab.live_view)
    end
  end

  describe "wiring" do
    test "route_module and migration_module point at real modules" do
      assert PhoenixKitKnowledgeBase.route_module() == PhoenixKitKnowledgeBase.Routes
      assert PhoenixKitKnowledgeBase.migration_module() == PhoenixKitKnowledgeBase.Migrations
      assert Code.ensure_loaded?(PhoenixKitKnowledgeBase.Routes)
      assert Code.ensure_loaded?(PhoenixKitKnowledgeBase.Migrations)
    end

    test "css_sources names this OTP app so Tailwind scans its templates" do
      assert PhoenixKitKnowledgeBase.css_sources() == [:phoenix_kit_knowledge_base]
    end

    test "get_config reports enablement" do
      assert %{enabled: enabled} = PhoenixKitKnowledgeBase.get_config()
      assert is_boolean(enabled)
    end

    test ":phoenix_kit is in extra_applications, or discovery never finds this module" do
      assert :phoenix_kit in Keyword.fetch!(
               PhoenixKitKnowledgeBase.MixProject.application(),
               :extra_applications
             )
    end
  end

  describe "routes" do
    test "both localized and non-localized sets are defined" do
      assert {_, _, _} = PhoenixKitKnowledgeBase.Routes.admin_routes()
      assert {_, _, _} = PhoenixKitKnowledgeBase.Routes.admin_locale_routes()
    end

    test "notes/new is declared before notes/:id" do
      # Reversed, the `:id` pattern claims the literal "new" and creating a
      # note 404s looking for a note with that uuid.
      source = PhoenixKitKnowledgeBase.Routes.admin_routes() |> Macro.to_string()
      new_at = :binary.match(source, "notes/new") |> elem(0)
      id_at = :binary.match(source, "notes/:id") |> elem(0)
      assert new_at < id_at
    end

    test "every route has a distinct :as name" do
      names =
        [
          PhoenixKitKnowledgeBase.Routes.admin_routes(),
          PhoenixKitKnowledgeBase.Routes.admin_locale_routes()
        ]
        |> Enum.map_join("\n", &Macro.to_string/1)
        |> then(&Regex.scan(~r/as: :(\w+)/, &1, capture: :all_but_first))
        |> List.flatten()

      assert length(names) == 10
      assert names == Enum.uniq(names)
    end
  end
end
