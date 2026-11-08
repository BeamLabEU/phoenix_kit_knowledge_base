defmodule Mix.Tasks.PhoenixKitKnowledgeBase.Rescan do
  @shortdoc "Reindex knowledge base vaults from their files on disk"

  @moduledoc """
  Reconciles vault indexes with the markdown files on disk.

  The web UI has a Rescan button; this is the same operation from a shell, so it
  can run from cron, from a deploy script, or from a git hook after a `pull`.

      # every vault
      mix phoenix_kit_knowledge_base.rescan

      # one vault, by slug
      mix phoenix_kit_knowledge_base.rescan research

      # quiet: only print vaults that actually changed, and errors
      mix phoenix_kit_knowledge_base.rescan --quiet

  Exits non-zero if any vault reported an error, so a cron job or CI step fails
  loudly rather than logging into the void.

  This is a separate OS process from the running app, with no PubSub: browsers
  open on a vault pick its changes up on their next navigation, not at once.
  To refresh them immediately, call `PhoenixKitKnowledgeBase.Rescan.run/1` on
  the live node instead (a release's `bin/<app> rpc`).
  """

  use Mix.Task

  import Ecto.Query

  alias PhoenixKitKnowledgeBase.{Rescan, Storage}
  alias PhoenixKitKnowledgeBase.Schemas.Vault

  @impl Mix.Task
  def run(args) do
    {opts, slugs} = OptionParser.parse!(args, strict: [quiet: :boolean], aliases: [q: :quiet])
    quiet? = Keyword.get(opts, :quiet, false)

    # `app.config` rather than `app.start`: the whole task is database work, and
    # starting the host application would also start its Phoenix endpoint —
    # which fails with `:eaddrinuse` whenever a dev server is already running,
    # exactly when you are most likely to want a rescan.
    Mix.Task.run("app.config")
    start_repo!()

    vaults = load_vaults(slugs)

    if vaults == [] do
      Mix.shell().info("No vaults to scan.")
    else
      unless quiet?, do: Mix.shell().info("Root: #{Storage.root()}\n")

      failed = Enum.reduce(vaults, 0, &scan(&1, &2, quiet?))

      if failed > 0 do
        Mix.raise("#{failed} vault(s) reported errors during rescan")
      end
    end
  end

  # Tolerates an already-running repo, so the task also works from inside a
  # release or an `iex -S mix` session.
  defp start_repo! do
    # `ecto_sql` brings up `db_connection` and the Postgrex types; without it
    # the pool has no supervisor to attach to and start_link dies with an
    # opaque "no process" from DBConnection.Watcher.
    {:ok, _apps} = Application.ensure_all_started(:ecto_sql)

    repo = PhoenixKit.RepoHelper.repo()

    case repo.start_link(pool_size: 2, log: false) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> Mix.raise("Could not start #{inspect(repo)}: #{inspect(reason)}")
    end
  end

  defp load_vaults([]) do
    PhoenixKit.RepoHelper.repo().all(from(v in Vault, order_by: [asc: v.directory]))
  end

  defp load_vaults(slugs) do
    vaults = PhoenixKit.RepoHelper.repo().all(from(v in Vault, where: v.slug in ^slugs))
    found = MapSet.new(vaults, & &1.slug)

    case Enum.reject(slugs, &MapSet.member?(found, &1)) do
      [] -> vaults
      missing -> Mix.raise("No such vault(s): #{Enum.join(missing, ", ")}")
    end
  end

  defp scan(vault, failed, quiet?) do
    case Rescan.run(vault) do
      {:ok, report} ->
        unless quiet? and Rescan.no_changes?(report) do
          Mix.shell().info("#{vault.slug} (#{vault.directory}) — #{Rescan.summarize(report)}")
        end

        Enum.each(report.errors, fn error ->
          Mix.shell().error("  ! #{error.path}: #{error.reason}")
        end)

        if report.errors == [], do: failed, else: failed + 1

      {:error, reason} ->
        Mix.shell().error("#{vault.slug} — rescan failed: #{inspect(reason)}")
        failed + 1
    end
  end
end
