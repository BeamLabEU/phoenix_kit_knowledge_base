defmodule PhoenixKitKnowledgeBase.LeafContractTest do
  @moduledoc """
  What this module needs from the Leaf the lock resolves.

  The integration suite forces `:leaf_notify` to `true` so it always drives the
  panel's Leaf branch; nothing there notices if detection itself stops working,
  for instance after Leaf renames its function component. The panel would
  quietly fall back to the plain textarea. These tests read the real Leaf.
  """
  # Not async: it clears an application env key the integration suite sets.
  use ExUnit.Case, async: false

  alias PhoenixKitKnowledgeBase.Web.NotesPanel

  setup do
    previous = Application.fetch_env(:phoenix_kit_knowledge_base, :leaf_notify)
    Application.delete_env(:phoenix_kit_knowledge_base, :leaf_notify)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:phoenix_kit_knowledge_base, :leaf_notify, value)
        :error -> Application.delete_env(:phoenix_kit_knowledge_base, :leaf_notify)
      end
    end)
  end

  test "the locked Leaf (0.11 or later) is detected as able to notify a component" do
    assert Version.match?(leaf_version(), ">= 0.11.0")
    assert NotesPanel.leaf_notify?()
  end

  # In interactive mode (dev) a module loads on first call, and
  # `function_exported?/3` is not a call: detection answered `false` until
  # some other page had rendered a Leaf editor.
  test "detection does not depend on Leaf having been loaded already" do
    if :code.is_loaded(Leaf) do
      :code.soft_purge(Leaf)
      :code.delete(Leaf)
    end

    refute :code.is_loaded(Leaf)
    assert NotesPanel.leaf_notify?()
  after
    Code.ensure_loaded(Leaf)
    :code.soft_purge(Leaf)
  end

  test "the config key overrides detection either way" do
    Application.put_env(:phoenix_kit_knowledge_base, :leaf_notify, false)
    refute NotesPanel.leaf_notify?()

    Application.put_env(:phoenix_kit_knowledge_base, :leaf_notify, true)
    assert NotesPanel.leaf_notify?()
  end

  # `follow: :click` (0.6.1) and `Leaf.Collab` (0.6.0) are used unconditionally,
  # so the declared requirement must not admit anything older.
  test "the declared Leaf requirement admits the lock and nothing before 0.6.1" do
    case List.keyfind(Mix.Project.config()[:deps], :leaf, 0) do
      # `LEAF_PATH` set: a local checkout, no requirement to check.
      {:leaf, opts} when is_list(opts) ->
        :ok

      dep ->
        requirement = elem(dep, 1)
        assert Version.match?(leaf_version(), requirement)
        assert Version.match?("0.6.1", requirement)
        refute Version.match?("0.6.0", requirement)
        refute Version.match?("0.5.1", requirement)
    end
  end

  defp leaf_version, do: to_string(Application.spec(:leaf, :vsn))
end
