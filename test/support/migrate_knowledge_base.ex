defmodule PhoenixKitKnowledgeBase.Test.MigrateKnowledgeBase do
  @moduledoc """
  Runs this module's own versioned chain in the test database, the way a host's
  generated migration does (`mix phoenix_kit.update`).
  """
  use Ecto.Migration

  def up, do: PhoenixKitKnowledgeBase.Migrations.up()
  def down, do: PhoenixKitKnowledgeBase.Migrations.down()
end
