defmodule PhoenixKitKnowledgeBase.Integration.MigrationsV2Test do
  @moduledoc "V2: `vaults.path_key` and its two partial unique indexes."
  use PhoenixKitKnowledgeBase.DataCase

  alias PhoenixKitKnowledgeBase.Migrations

  test "the chain is installed at the current version" do
    assert Migrations.current_version() == 2
    assert Migrations.migrated_version_runtime() == 2
  end

  test "V2 adds path_key and the indexes" do
    %{rows: columns} =
      Repo.query!(
        "SELECT column_name FROM information_schema.columns WHERE table_name = 'phoenix_kit_kb_vaults'"
      )

    assert ["path_key"] in columns

    %{rows: indexes} =
      Repo.query!("SELECT indexname FROM pg_indexes WHERE tablename = 'phoenix_kit_kb_vaults'")

    assert ["phoenix_kit_kb_vaults_shared_path_key_index"] in indexes
    assert ["phoenix_kit_kb_vaults_private_path_key_index"] in indexes
  end

  test "a V2 table that lost its stamp is recognised by its shape" do
    # Inside the sandbox transaction, so the stamp comes back afterwards.
    Repo.query!("COMMENT ON TABLE phoenix_kit_kb_vaults IS NULL")
    assert Migrations.migrated_version_runtime() == 2
  end

  test "vaults from before V2 have no key, and any number of them may share a name" do
    for n <- 1..2 do
      Repo.query!("""
      INSERT INTO phoenix_kit_kb_vaults (name, slug, directory, scope, inserted_at, updated_at)
      VALUES ('Same', 'same-#{n}', 'system/same-#{n}', 'system', now(), now())
      """)
    end

    assert %{rows: [[nil], [nil]]} =
             Repo.query!("SELECT path_key FROM phoenix_kit_kb_vaults WHERE name = 'Same'")
  end
end
