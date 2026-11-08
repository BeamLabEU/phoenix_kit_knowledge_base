defmodule PhoenixKitKnowledgeBase.Integration.PlacesTest do
  @moduledoc """
  A notes panel's path against a real database and disk: what `ensure/2`
  creates, who shares it, and what two people creating it at once end up with.
  """
  use PhoenixKitKnowledgeBase.DataCase

  alias PhoenixKitKnowledgeBase.{Notes, Places, Storage, Vaults}
  alias PhoenixKitKnowledgeBase.Schemas.Vault

  defp place!(path, visibility \\ :shared) do
    {:ok, place} = Places.parse(path, visibility)
    place
  end

  defp panel_vaults, do: Repo.all(from(v in Vault, where: not is_nil(v.path_key)))

  describe "a shared place" do
    test "the first ensure creates an organisation vault and the folder chain" do
      user = user_fixture()
      place = place!(["CRM", "Clients", "Acme"])

      assert Places.locate(place, user) == nil
      assert {:ok, vault} = Places.ensure(place, user)

      assert vault.name == "CRM"
      assert vault.scope == "system"
      assert vault.owner_uuid == nil
      assert vault.created_by == user.uuid
      assert vault.path_key == "crm"

      assert File.dir?(Path.join(Storage.vault_path(vault.directory), "Clients/Acme"))
      folders = vault.uuid |> Notes.list_folders() |> Enum.map(& &1.relative_path)
      assert "Clients" in folders
      assert "Clients/Acme" in folders

      assert Places.locate(place, user).uuid == vault.uuid
    end

    test "everyone reaching the same path shares one vault; other paths add folders to it" do
      alice = user_fixture()
      bob = user_fixture()

      {:ok, v1} = Places.ensure(place!(["CRM", "Clients", "Acme"]), alice)
      {:ok, v2} = Places.ensure(place!(["CRM", "Clients", "Acme"]), bob)
      {:ok, v3} = Places.ensure(place!(["CRM", "Clients", "Globex"]), bob)

      assert v1.uuid == v2.uuid
      assert v1.uuid == v3.uuid
      assert length(panel_vaults()) == 1
      assert File.dir?(Path.join(Storage.vault_path(v1.directory), "Clients/Globex"))
    end

    test "a different first segment is a different vault" do
      user = user_fixture()
      {:ok, crm} = Places.ensure(place!(["CRM"]), user)
      {:ok, hr} = Places.ensure(place!(["HR"]), user)
      refute crm.uuid == hr.uuid
    end

    test "an organisation vault that merely has the same name is not adopted" do
      user = user_fixture()

      existing =
        %Vault{}
        |> Vault.changeset(%{name: "CRM", slug: "crm", scope: "system", directory: "system/crm"})
        |> Repo.insert!()

      {:ok, vault} = Places.ensure(place!(["CRM"]), user)
      refute vault.uuid == existing.uuid
      refute vault.slug == "crm"
      assert vault.path_key == "crm"
    end

    test "the hook decides whether it may be created" do
      user = user_fixture()

      with_hook({__MODULE__.Hooks, :view_only}, fn ->
        assert {:error, :unauthorized} = Places.ensure(place!(["CRM"]), user)
      end)

      assert panel_vaults() == []
    end

    test "nobody signed in creates nothing" do
      assert {:error, :unauthorized} = Places.ensure(place!(["CRM"]), nil)
      assert panel_vaults() == []
    end
  end

  describe "a private place" do
    test "is the person's own personal vault of that name" do
      user = user_fixture()
      {:ok, vault} = Places.ensure(place!(["CRM", "Acme"], :private), user)

      assert vault.scope == "user"
      assert vault.owner_uuid == user.uuid
      assert vault.path_key == "crm"
      assert String.starts_with?(vault.directory, "users/")
      assert Vaults.role_for(vault, %PhoenixKit.Users.Auth.Scope{user: user}) == "owner"
    end

    test "each person gets their own, and cannot find anyone else's" do
      alice = user_fixture()
      bob = user_fixture()
      place = place!(["CRM"], :private)

      {:ok, mine} = Places.ensure(place, alice)
      assert Places.locate(place, bob) == nil

      {:ok, theirs} = Places.ensure(place, bob)
      refute mine.uuid == theirs.uuid
    end

    test "shares its name with the shared vault without colliding" do
      user = user_fixture()
      {:ok, shared} = Places.ensure(place!(["CRM"]), user)
      {:ok, private} = Places.ensure(place!(["CRM"], :private), user)
      refute shared.uuid == private.uuid
      assert shared.path_key == private.path_key
    end
  end

  describe "two people creating the same place at once" do
    test "the database lets only one vault exist per shared name" do
      user = user_fixture()
      {:ok, _} = Places.ensure(place!(["CRM"]), user)

      assert {:error, changeset} =
               Vaults.create_for_place(
                 %{"name" => "CRM", "scope" => "system", "created_by" => user.uuid},
                 :system,
                 nil,
                 "crm"
               )

      assert {:path_key, {_, opts}} = List.keyfind(changeset.errors, :path_key, 0)
      assert opts[:constraint] == :unique
    end

    test "all of them end up in the same vault, with no stray directories", %{root: root} do
      users = for _ <- 1..6, do: user_fixture()
      place = place!(["CRM", "Clients", "Acme"])

      results =
        users
        |> Task.async_stream(&Places.ensure(place, &1), max_concurrency: 6, timeout: 30_000)
        |> Enum.map(fn {:ok, result} -> result end)

      uuids = for {:ok, vault} <- results, uniq: true, do: vault.uuid
      assert length(uuids) == 1, "results: #{inspect(results)}"
      assert length(panel_vaults()) == 1

      assert root |> Path.join("system") |> File.ls!() |> length() == 1
    end
  end

  defmodule Hooks do
    def view_only(action, _user, _path), do: action == :view
  end
end
