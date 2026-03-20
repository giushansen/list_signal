defmodule LS.Application do
  @moduledoc """
  ListSignal OTP Application.

  Starts different supervisor trees based on LS_ROLE:
    - master:     CTL Poller + WorkQueue + Inserter + Monitor + Cache + Phoenix
    - worker:     WorkerAgent + Cache + BGP Resolver + DNS Resolver
    - standalone: master + worker (for single-node dev/testing)

  LS_MODE controls CTL polling:
    - ctl_live: polls Certificate Transparency logs in real-time
    - minimal:  no CTL polling (queue must be fed manually)
  """

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    role = System.get_env("LS_ROLE", "standalone")
    mode = System.get_env("LS_MODE", "minimal")

    Logger.info("🚀 ListSignal starting — role=#{role} mode=#{mode}")

    children =
      common_children() ++
      role_children(role, mode)

    opts = [strategy: :one_for_one, name: LS.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    if Process.whereis(LSWeb.Endpoint), do: LSWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # ==========================================================================
  # COMMON — always started regardless of role
  # ==========================================================================

  defp common_children do
    [
      LSWeb.Telemetry,
      LS.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:ls, :ecto_repos), skip: skip_migrations?()},
      {Phoenix.PubSub, name: LS.PubSub},
      # Cache is needed on all roles (CTL dedup on master, HTTP/BGP on workers)
      LS.Cache
    ]
  end

  # ==========================================================================
  # ROLE-SPECIFIC CHILDREN
  # ==========================================================================

  defp role_children("master", mode) do
    # Load scoring signatures into ETS
    LS.Signatures.load_all()

    master = [
      LS.Cluster.WorkQueue,
      LS.Cluster.Inserter,
      LS.Cluster.Monitor,
      LSWeb.Endpoint
    ]

    if mode == "ctl_live" do
      master ++ [LS.CTL.Poller]
    else
      Logger.info("📭 CTL polling disabled (mode=#{mode})")
      master
    end
  end

  defp role_children("worker", _mode) do
    # Workers need signatures for scoring, TLD filter, resolvers
    LS.Signatures.load_all()

    [
      LS.DNS.Resolver,
      LS.BGP.Resolver,
      LS.HTTP.PerformanceTracker,
      LS.Cluster.WorkerAgent
    ]
  end

  defp role_children("standalone", mode) do
    # Everything: master + worker on same node
    role_children("master", mode) ++
      [
        LS.DNS.Resolver,
        LS.BGP.Resolver,
        LS.HTTP.PerformanceTracker,
        LS.Cluster.WorkerAgent
      ]
  end

  defp role_children(unknown, _mode) do
    Logger.warning("⚠️  Unknown LS_ROLE=#{unknown}, starting as standalone")
    role_children("standalone", "minimal")
  end

  defp skip_migrations?() do
    System.get_env("RELEASE_NAME") == nil
  end
end
