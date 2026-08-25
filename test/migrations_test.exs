defmodule PhoenixKitKnowledgeBase.MigrationsTest do
  @moduledoc """
  Guards the migration contract `mix phoenix_kit.update` drives. No database:
  these cover the version bookkeeping, which is the part that decides whether a
  host's migration is generated at all.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitKnowledgeBase.Migrations

  test "current_version is a positive integer" do
    assert is_integer(Migrations.current_version())
    assert Migrations.current_version() >= 1
  end

  test "the module version and the migration version are both declared" do
    # They move independently — a release can ship without a schema change —
    # so this only asserts both exist rather than that they match.
    assert is_binary(PhoenixKitKnowledgeBase.version())
    assert Migrations.current_version() >= 1
  end

  describe "parse_version_comment/1" do
    test "reads the stamp this module writes" do
      assert {:ok, 1} = Migrations.parse_version_comment("1")
      assert {:ok, 2} = Migrations.parse_version_comment(" 2 \n")
    end

    test "somebody else's table comment is not a version stamp" do
      # Treated as unstamped so the version is inferred from the actual
      # columns, rather than crashing on String.to_integer/1.
      assert :unstamped = Migrations.parse_version_comment("Knowledge base vaults")
      assert :unstamped = Migrations.parse_version_comment("1 vault per project")
    end

    test "a missing comment is unstamped" do
      assert :unstamped = Migrations.parse_version_comment(nil)
    end

    test "a negative number is not a version" do
      assert :unstamped = Migrations.parse_version_comment("-1")
    end
  end

  test "migrated_version_runtime returns 0 without a repo instead of raising" do
    # Called by `mix phoenix_kit.update` before anything is installed.
    assert Migrations.migrated_version_runtime() == 0
  end
end
