defmodule PhoenixKitKnowledgeBase.EventsTest do
  @moduledoc """
  The origin check, which is what stops a browser reacting to its own writes.
  Pure, so it runs without PubSub or a database.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitKnowledgeBase.Events

  @vault "01a03acb-70ed-73c5-a1cc-9334f68d145a"

  describe "vault_topic/1" do
    test "is namespaced and scoped to one vault" do
      topic = Events.vault_topic(@vault)

      assert topic =~ "phoenix_kit_kb"
      assert topic =~ @vault
      refute Events.vault_topic("other") == topic
    end
  end

  describe "own?/1" do
    test "recognises a message this process caused" do
      # Without this, the browser that just saved would be told its own note
      # changed and offered to reload it from itself.
      assert Events.own?(%{origin: self()})
    end

    test "a message from another process is not ours" do
      peer = spawn(fn -> :ok end)
      refute Events.own?(%{origin: peer})
    end

    test "a payload with no origin is treated as somebody else's" do
      # Fail towards reacting rather than towards silently ignoring: a missed
      # refresh is visible, a suppressed one is not.
      refute Events.own?(%{})
    end
  end
end
