defmodule LS.Application do
  @moduledoc """
  ListSignal OTP Application.

  Starts different supervisor trees based on LS_ROLE:
    - master:     CTL + Queue + Inserter + Monitor + Reputation + Phoenix
    - worker:     WorkerAgent + Cache + Resolvers + RDAP + Reputation
    - standalone: master + worker
  """

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    role = System.get_env("LS_ROLE", "standalone")
    mode = System.get_env("LS_MODE", "minimal")
    Logger.info("🚀 ListSignal starting — role=#{role} mode=#{mode}")
    children = common_children() ++ role_children(role, mode)
    Supervisor.start_link(children, strategy: :one_for_one, name: LS.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    if Process.whereis(LSWeb.Endpoint), do: LSWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp common_children do
    [
      LSWeb.Telemetry, LS.Repo,
      {Ecto.Migrator, repos: Application.fetch_env!(:ls, :ecto_repos), skip: skip_migrations?()},
      {Phoenix.PubSub, name: LS.PubSub},
      LS.Cache
    ]
  end

  defp role_children("master", mode) do
    LS.Signatures.load_all()
    master = [
      LS.Reputation.Tranco,
      LS.Reputation.Majestic,
      LS.Reputation.Blocklist,
      LS.Cluster.WorkQueue,
      LS.Cluster.Inserter,
      LS.Cluster.Monitor,
      LSWeb.Endpoint
    ]
    if mode == "ctl_live", do: master ++ [LS.CTL.Poller],
    else: (Logger.info("📭 CTL polling disabled (mode=#{mode})"); master)
  end

  defp role_children("worker", _mode) do
    LS.Signatures.load_all()
    [
      LS.DNS.Resolver,
      LS.BGP.Resolver,
      LS.RDAP.Client,
      LS.Reputation.Tranco,
      LS.Reputation.Majestic,
      LS.Reputation.Blocklist,
      LS.HTTP.PerformanceTracker,
      LS.Cluster.WorkerAgent
    ]
  end

  defp role_children("standalone", mode) do
    role_children("master", mode) ++
      [LS.DNS.Resolver, LS.BGP.Resolver, LS.RDAP.Client,
       LS.HTTP.PerformanceTracker, LS.Cluster.WorkerAgent]
  end

  defp role_children(unknown, _mode) do
    Logger.warning("⚠️  Unknown LS_ROLE=#{unknown}, starting as standalone")
    role_children("standalone", "minimal")
  end

  defp skip_migrations?, do: System.get_env("RELEASE_NAME") == nil
end
