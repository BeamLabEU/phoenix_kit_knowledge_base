defmodule PhoenixKitKnowledgeBase.AccessTest do
  @moduledoc """
  The role-to-capability mapping. Pure, and worth pinning: every write path in
  the module funnels through `can?/2`, so an off-by-one in the ordering would
  quietly hand editors the ability to delete a vault.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitKnowledgeBase.Vaults

  test "viewer may read and nothing else" do
    assert Vaults.can?("viewer", :read)
    refute Vaults.can?("viewer", :write)
    refute Vaults.can?("viewer", :manage)
  end

  test "editor may read and write, but not administer" do
    assert Vaults.can?("editor", :read)
    assert Vaults.can?("editor", :write)
    refute Vaults.can?("editor", :manage)
  end

  test "owner may do everything" do
    assert Vaults.can?("owner", :read)
    assert Vaults.can?("owner", :write)
    assert Vaults.can?("owner", :manage)
  end

  test "no role means no access at all" do
    # `role_for/2` returns nil for a vault the user cannot see; every `can?`
    # must be false so a nil never reads as permission.
    refute Vaults.can?(nil, :read)
    refute Vaults.can?(nil, :write)
    refute Vaults.can?(nil, :manage)
  end

  test "an unrecognised role grants nothing" do
    refute Vaults.can?("admin", :read)
    refute Vaults.can?("", :read)
  end

  test "no scope means no system-vault management" do
    refute Vaults.can_manage_system_vaults?(nil)
  end
end
