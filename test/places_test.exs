defmodule PhoenixKitKnowledgeBase.PlacesTest do
  @moduledoc """
  The database-free half of `Places`: what a panel path means, the fence around
  a panel's folder, and the host's `:authorize` hook.
  """
  # Not async: the hook tests change application configuration.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias PhoenixKitKnowledgeBase.Places

  defp place!(path, visibility \\ :shared) do
    {:ok, place} = Places.parse(path, visibility)
    place
  end

  describe "parse/2" do
    test "the first segment is the vault, the rest the folder" do
      place = place!(["CRM", "Clients", "Acme Ltd"])
      assert place.vault_name == "CRM"
      assert place.folder == "Clients/Acme Ltd"
      assert place.key == "crm"
      assert place.path == ["CRM", "Clients", "Acme Ltd"]
    end

    test "a vault on its own is the vault root" do
      assert place!(["CRM"]).folder == ""
    end

    test "ids need no stringifying" do
      assert place!(["CRM", :clients, 42]).folder == "clients/42"
    end

    test "segments are trimmed" do
      assert place!(["  CRM ", " Acme "]).path == ["CRM", "Acme"]
    end

    test "a segment that cannot be a directory name is refused" do
      for bad <- ["", "  ", "a/b", "..", ".hidden", nil, %{}] do
        assert {:error, {:invalid_segment, _, _}} = Places.parse(["CRM", bad], :shared),
               "accepted #{inspect(bad)}"
      end
    end

    test "an empty or non-list path is refused" do
      assert {:error, {:invalid_path, []}} = Places.parse([], :shared)
      assert {:error, {:invalid_path, "CRM"}} = Places.parse("CRM", :shared)
    end

    test "visibility is :shared or :private" do
      assert {:ok, _} = Places.parse(["CRM"], :private)
      assert {:error, {:invalid_visibility, :public}} = Places.parse(["CRM"], :public)
    end

    test "a name with no slug-able characters still gets a key, distinct per name" do
      a = place!(["日本語"])
      b = place!(["中文"])
      assert a.key =~ ~r/^p-[0-9a-f]{16}$/
      refute a.key == b.key
    end
  end

  describe "within?/2" do
    test "the folder itself and everything under it" do
      place = place!(["CRM", "Clients", "Acme"])
      assert Places.within?(place, "Clients/Acme")
      assert Places.within?(place, "Clients/Acme/Calls")
      refute Places.within?(place, "Clients")
      refute Places.within?(place, "Clients/Acme Ltd")
      refute Places.within?(place, "")
    end

    test "the vault root contains every clean path" do
      place = place!(["CRM"])
      assert Places.within?(place, "")
      assert Places.within?(place, "Clients/Acme")
    end

    test "a path that climbs out is refused, however it starts" do
      place = place!(["CRM", "Clients", "Acme"])

      for sneaky <- [
            "Clients/Acme/../Other",
            "Clients/Acme/./x",
            "Clients/Acme//x",
            "/Clients/Acme"
          ] do
        refute Places.within?(place, sneaky), "accepted #{sneaky}"
      end

      refute Places.within?(place!(["CRM"]), "../elsewhere")
    end

    test "anything but a string is outside" do
      refute Places.within?(place!(["CRM"]), nil)
    end
  end

  describe "authorize/3" do
    defmodule Hooks do
      def allow(_action, _user, _path), do: true
      def deny(_action, _user, _path), do: false
      def view_only(action, _user, _path), do: action == :view
      def boom(_action, _user, _path), do: raise("down")
      def maybe(_action, _user, _path), do: :maybe
      def exit(_action, _user, _path), do: exit(:gone)
      def record(action, user, path), do: send(self(), {:asked, action, user, path}) && true
    end

    setup do
      previous = Application.get_env(:phoenix_kit_knowledge_base, :authorize)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:phoenix_kit_knowledge_base, :authorize, previous),
          else: Application.delete_env(:phoenix_kit_knowledge_base, :authorize)
      end)

      :ok
    end

    defp hook(name),
      do: Application.put_env(:phoenix_kit_knowledge_base, :authorize, {Hooks, name})

    @user %{uuid: "u1", email: "u@example.com"}

    test "nobody signed in is refused, whatever the hook says" do
      hook(:allow)
      refute Places.authorize(:view, nil, place!(["CRM"]))
      refute Places.authorize(:view, nil, place!(["CRM"], :private))
    end

    test "unconfigured, any signed-in user may use a shared place" do
      Application.delete_env(:phoenix_kit_knowledge_base, :authorize)
      assert Places.authorize(:edit, @user, place!(["CRM"]))
    end

    test "the hook decides a shared place, asked with the action, user and path" do
      hook(:record)
      assert Places.authorize(:edit, @user, place!(["CRM", "Clients", "Acme"]))
      assert_received {:asked, :edit, @user, ["CRM", "Clients", "Acme"]}

      hook(:view_only)
      assert Places.authorize(:view, @user, place!(["CRM"]))
      refute Places.authorize(:edit, @user, place!(["CRM"]))
    end

    test "a hook that fails is a no, and the log does not carry its arguments" do
      for name <- [:boom, :maybe, :exit] do
        hook(name)

        log =
          capture_log(fn ->
            refute Places.authorize(:view, @user, place!(["CRM", "Secret Client"]))
          end)

        assert log =~ "access refused"
        refute log =~ "Secret Client"
        refute log =~ "u@example.com"
      end
    end

    test "a malformed hook setting is a no" do
      Application.put_env(:phoenix_kit_knowledge_base, :authorize, :not_a_hook)
      capture_log(fn -> refute Places.authorize(:view, @user, place!(["CRM"])) end)
    end

    test "private places are the owner's: the hook is not asked and cannot refuse" do
      hook(:boom)
      assert Places.authorize(:edit, @user, place!(["CRM"], :private))
    end
  end
end
