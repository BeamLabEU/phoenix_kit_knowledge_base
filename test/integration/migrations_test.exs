defmodule PhoenixKitKnowledgeBase.Integration.MigrationsTest do
  @moduledoc "V2: `vaults.path_key` and its two partial unique indexes. V3: text columns."
  use PhoenixKitKnowledgeBase.DataCase

  alias PhoenixKitKnowledgeBase.Migrations

  test "the chain is installed at the current version" do
    assert Migrations.current_version() == 3
    assert Migrations.migrated_version_runtime() == 3
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

  test "a table that lost its stamp is recognised by its shape" do
    # Inside the sandbox transaction, so the stamp and the type come back.
    Repo.query!("COMMENT ON TABLE phoenix_kit_kb_vaults IS NULL")
    assert Migrations.migrated_version_runtime() == 3

    Repo.query!("ALTER TABLE phoenix_kit_kb_note_links ALTER COLUMN target_key TYPE varchar(255)")

    assert Migrations.migrated_version_runtime() == 2
  end

  test "V3: paths, link targets and vault directories are text" do
    %{rows: rows} =
      Repo.query!("""
      SELECT table_name, column_name, data_type FROM information_schema.columns
      WHERE table_name LIKE 'phoenix_kit_kb_%'
        AND column_name IN ('relative_path', 'folder_path', 'title_key', 'target_key',
                            'target_title', 'directory')
      """)

    assert length(rows) == 7
    assert Enum.all?(rows, fn [_table, _column, type] -> type == "text" end)
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
