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

    # Create lookup cache table owned by the application process (long-lived)
    if :ets.whereis(:lookup_result_cache) == :undefined do
      :ets.new(:lookup_result_cache, [:set, :public, :named_table, read_concurrency: true])
    end

    LS.RateLimiter.init()
    pin_vm_resolver()
    children = common_children() ++ role_children(role, mode)
    Supervisor.start_link(children, strategy: :one_for_one, name: LS.Supervisor)
  end

  # Point the whole BEAM's name resolution at local Unbound, the same server
  # LS.DNS.Resolver pins explicitly.
  #
  # Without this the VM falls back to /etc/resolv.conf for everything that
  # resolves a hostname itself — Mint (LS.HTTP.Client), Team Cymru whois
  # (LS.BGP.Resolver) and RDAP — while the DNS enrichment stage keeps working,
  # because it passes `nameservers:` on every lookup. On 2026-07-04 the h1
  # worker's /etc/resolv.conf broke and produced exactly that split brain: DNS
  # resolved fine, then HTTP returned `transport::nxdomain` for the very domain
  # it had just resolved, and BGP/RDAP silently returned nothing. It ran that
  # way for 21 days and wrote ~56M empty rows over good data.
  #
  # Pinning here makes a broken OS resolver impossible to hit: either Unbound
  # is up and everything resolves, or it's down and DNS enrichment fails loudly
  # too, which the dashboards already alert on.
  defp pin_vm_resolver do
    :inet_db.set_lookup([:dns])
    :inet_db.add_ns({127, 0, 0, 1})
    Logger.info("🌐 VM resolver pinned to Unbound (127.0.0.1:53) — HTTP/BGP/RDAP included")
  rescue
    e -> Logger.error("Failed to pin VM resolver: #{Exception.message(e)}")
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
    LS.HTTP.DomainFilter.load_tlds()
    LS.HTTP.IPRateLimiter.init()
    master = [
      LS.DNS.Resolver,
      LS.BGP.Resolver,
      LS.RDAP.Client,
      {LS.LandingCache, []},
      LS.Reputation.Tranco,
      LS.Reputation.Majestic,
      LS.Reputation.Blocklist,
      LS.ML.Classifier,
      LS.Cluster.WorkQueue,
      # Allow time for the terminate/2 flush (ClickHouse insert has a 30s receive_timeout)
      Supervisor.child_spec(LS.Cluster.Inserter, shutdown: 35_000),
      LS.Cluster.Optimizer,
      LS.Cluster.Monitor,
      LS.Recrawl.Scheduler,
      LSWeb.Endpoint
    ]
    if mode == "ctl_live", do: master ++ [LS.CTL.Poller],
    else: (Logger.info("📭 CTL polling disabled (mode=#{mode})"); master)
  end

  defp role_children("worker", _mode) do
    LS.Signatures.load_all()
    LS.HTTP.DomainFilter.load_tlds()
    LS.HTTP.IPRateLimiter.init()
    [
      LS.DNS.Resolver,
      LS.BGP.Resolver,
      LS.RDAP.Client,
      LS.Reputation.Tranco,
      LS.Reputation.Majestic,
      LS.Reputation.Blocklist,
      LS.ML.Classifier,
      LS.HTTP.PerformanceTracker,
      LS.Cluster.WorkerAgent
    ]
  end

  defp role_children("standalone", mode) do
    role_children("master", mode) ++
      [LS.HTTP.PerformanceTracker, LS.Cluster.WorkerAgent]
  end

  defp role_children(unknown, _mode) do
    Logger.warning("⚠️  Unknown LS_ROLE=#{unknown}, starting as standalone")
    role_children("standalone", "minimal")
  end

  defp skip_migrations?, do: System.get_env("RELEASE_NAME") == nil
end
