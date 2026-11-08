defmodule PhoenixKitKnowledgeBase.ErrorsTest do
  @moduledoc """
  The one place a reason becomes a sentence. What matters most is the fallback:
  a reason nobody mapped must not reach a person as an inspected term.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias PhoenixKitKnowledgeBase.Errors
  alias PhoenixKitKnowledgeBase.Web.VaultLive

  test "a known reason reads as a sentence" do
    assert Errors.message(:stale) =~ "changed on disk"
    assert Errors.message({:forbidden_characters, ["#"]}) =~ "cannot contain #"
    assert Errors.message({:folder, :blank}) == Errors.message(:blank)
  end

  test "an unknown reason is logged, not shown" do
    log =
      capture_log(fn ->
        message = Errors.message({:weird, %{secret: "x"}})
        refute message =~ "weird"
        refute message =~ "secret"
      end)

    assert log =~ ":weird"
  end

  test "a changeset in a log line is its messages, never its content" do
    changeset =
      {%{}, %{content: :string}}
      |> Ecto.Changeset.cast(%{content: "the whole private note"}, [:content])
      |> Ecto.Changeset.add_error(:content, "is not UTF-8 text")

    line = Errors.for_log(changeset)
    assert line =~ "is not UTF-8 text"
    refute line =~ "private note"
  end

  describe "front matter, shown" do
    test "a list of maps, nested, and scalars" do
      assert VaultLive.format_property([%{"name" => "Ada", "year" => 1843}, "Bob"]) ==
               "name: Ada; year: 1843, Bob"

      assert VaultLive.format_property(%{"a" => [1, 2]}) == "a: 1, 2"
      assert VaultLive.format_property(nil) == "—"
      assert VaultLive.format_property(true) == "true"
      assert VaultLive.format_property("plain") == "plain"
    end
  end
end
