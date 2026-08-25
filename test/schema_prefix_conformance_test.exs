defmodule PhoenixKitKnowledgeBase.SchemaPrefixConformanceTest do
  @moduledoc """
  Scans `lib/` so a table-backed schema cannot silently skip
  `use PhoenixKit.SchemaPrefix`.

  Omitting it is invisible on a default install and breaks only on hosts that
  ran `mix phoenix_kit.install --prefix "…"`, where queries resolve through the
  connection's `search_path` instead of the install's schema. That is a bug
  nobody finds by testing locally, so it is asserted here instead.
  """
  use ExUnit.Case, async: true

  @schema_dir "lib/phoenix_kit_knowledge_base/schemas"

  test "every Ecto schema in this module declares the prefix" do
    offenders =
      @schema_dir
      |> Path.join("*.ex")
      |> Path.wildcard()
      |> Enum.reject(fn path ->
        source = File.read!(path)
        # Only schemas backed by a table need it.
        not String.contains?(source, "use Ecto.Schema") or
          String.contains?(source, "use PhoenixKit.SchemaPrefix")
      end)

    assert offenders == [],
           "missing `use PhoenixKit.SchemaPrefix`: #{Enum.join(offenders, ", ")}"
  end

  test "the scan actually found the schemas it is meant to guard" do
    # Without this, renaming the directory would turn the test above into a
    # green no-op.
    files = @schema_dir |> Path.join("*.ex") |> Path.wildcard()
    assert length(files) == 5
  end

  test "timestamps type matches what the migration creates" do
    # `timestamps(type: :utc_datetime)` against the timestamptz(6) columns the
    # migration creates silently truncates microseconds on write.
    for path <- @schema_dir |> Path.join("*.ex") |> Path.wildcard() do
      source = File.read!(path)

      if String.contains?(source, "timestamps(") do
        assert source =~ "timestamps(type: :utc_datetime_usec)",
               "#{path} must use :utc_datetime_usec to match the migration"
      end
    end
  end

  test "all tables are namespaced under phoenix_kit_kb_" do
    for path <- @schema_dir |> Path.join("*.ex") |> Path.wildcard() do
      source = File.read!(path)

      case Regex.run(~r/schema "([^"]+)"/, source, capture: :all_but_first) do
        [table] ->
          assert String.starts_with?(table, "phoenix_kit_kb_"),
                 "#{path} declares table #{table}, which could collide with another module"

        _ ->
          :ok
      end
    end
  end
end
