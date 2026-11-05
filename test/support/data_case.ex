defmodule PhoenixKitKnowledgeBase.DataCase do
  @moduledoc """
  Test case for tests that hit the database — and the disk, since a vault is a
  directory.

  Tests using this case are tagged `:integration` and excluded automatically
  when PostgreSQL is unavailable, so `mix test` still runs the unit half on a
  machine with no database.

  Not async: each test points the storage root at its own temporary directory,
  which is global configuration. ExUnit runs every async module first, so the
  unit tests that do the same never overlap these.

      defmodule PhoenixKitKnowledgeBase.Integration.SomethingTest do
        use PhoenixKitKnowledgeBase.DataCase
      end
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :integration

      import Ecto.Query, except: [update: 2, update: 3]
      import PhoenixKitKnowledgeBase.DataCase

      alias PhoenixKitKnowledgeBase.Test.Repo
    end
  end

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitKnowledgeBase.Test.Repo, as: TestRepo

  setup tags do
    pid = Sandbox.start_owner!(TestRepo, shared: not tags[:async])

    root = Path.join(System.tmp_dir!(), "kb_it_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous = Application.get_env(:phoenix_kit_knowledge_base, :root)
    Application.put_env(:phoenix_kit_knowledge_base, :root, root)

    on_exit(fn ->
      Sandbox.stop_owner(pid)
      File.rm_rf(root)

      if previous,
        do: Application.put_env(:phoenix_kit_knowledge_base, :root, previous),
        else: Application.delete_env(:phoenix_kit_knowledge_base, :root)
    end)

    %{root: root}
  end

  @doc "A persisted, confirmed user (inserted directly: registration needs the rate limiter)."
  def user_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    %PhoenixKit.Users.Auth.User{}
    |> Ecto.Changeset.change(
      Map.merge(
        %{
          email: "kb-#{n}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("ValidPassword123!"),
          confirmed_at: DateTime.utc_now() |> DateTime.truncate(:second),
          is_active: true
        },
        attrs
      )
    )
    |> TestRepo.insert!()
  end

  @doc "Runs `fun` with the `:authorize` hook set to `hook`, restoring it after."
  def with_hook(hook, fun) do
    previous = Application.get_env(:phoenix_kit_knowledge_base, :authorize)
    Application.put_env(:phoenix_kit_knowledge_base, :authorize, hook)

    try do
      fun.()
    after
      if previous,
        do: Application.put_env(:phoenix_kit_knowledge_base, :authorize, previous),
        else: Application.delete_env(:phoenix_kit_knowledge_base, :authorize)
    end
  end
end
