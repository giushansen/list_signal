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

  @doc """
  Lanes this worker runs, from `LS_LANES` (default `["discovery"]`).

  Unknown values are ignored and an empty result falls back to discovery, so a
  typo can never leave a node silently doing nothing.
  """
  @spec worker_lanes() :: [String.t()]
  def worker_lanes do
    System.get_env("LS_LANES", "discovery")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&(&1 in ["discovery", "enrichment"]))
    |> case do
      [] -> ["discovery"]
      lanes -> lanes
    end
  end

  defp common_children do
    [
      LSWeb.Telemetry, LS.Repo,
      {Ecto.Migrator, repos: Application.fetch_env!(:ls, :ecto_repos), skip: skip_migrations?()},
      {Phoenix.PubSub, name: LS.PubSub},
      LS.Cache,
      LS.UICache,
      # Feeds LSWeb.Plugs.OverloadGuard. Must start before the endpoint so the
      # guard has a reading; until it does, the guard fails open and serves.
      LS.MemorySampler,
      # Catches and kills runaway mailboxes — see LS.MailboxSentinel.
      LS.MailboxSentinel,
      # Primes the page cache after boot — see LS.CacheWarmer.
      LS.CacheWarmer,
      # Founder activation emails (welcome / wall / weekly digest) — master only.
      LS.Engagement,
      # Pipeline 3: job-platform boards (harvest + resync + WTTJ) — master only.
      LS.Verification.BoardScheduler,
      # Dedicated HTTP pools. Both 2026-08-03 outages trace to one cause:
      # every ClickHouse call AND the CT poller shared Req's default Finch
      # pool, so a heavy compaction holding connections while inserts churned
      # starved the pool — web queries then queued unboundedly and the site
      # went dark while the BEAM stayed "active". Separate pools mean the
      # crawler and the compactor can saturate THEIR pool without taking the
      # customer-facing one down with them.
      {Finch, name: LS.Finch.CH, pools: %{default: [size: 150, count: 1]}},
      {Finch, name: LS.Finch.CTL, pools: %{default: [size: 30, count: 1]}},
      # Periodic bulk downloads (Tranco, Majestic, blocklists) hold a
      # connection for minutes at a time. Isolated so they cannot queue
      # behind — or in front of — anything request-shaped.
      {Finch, name: LS.Finch.Bulk, pools: %{default: [size: 8, count: 1]}}
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
      # Reads the page caches back from /tmp so a deploy starts warm.
      #
      # ORDER IS LOAD-BEARING, both ways:
      #   * AFTER every table it restores (LS.UICache in common_children,
      #     LS.LandingCache on the line above) or there is nothing to write to.
      #   * BEFORE LSWeb.Endpoint, so the cache is populated before the port is
      #     bound and no request can ever arrive to a cold cache on a graceful
      #     restart. This is what stops the 25s 503 of 2026-08-24.
      # Pinned by ls/application_boot_order_test.exs.
      LS.CacheSnapshot,
      LS.Reputation.Tranco,
      LS.Reputation.Majestic,
      LS.Reputation.Blocklist,
      LS.ML.Classifier,
      LS.Cluster.WorkQueue,
      # Hour-long queue history behind the workers-needed figure.
      LS.Cluster.QueueTrend,
      # Allow time for the terminate/2 flush (ClickHouse insert has a 30s receive_timeout)
      Supervisor.child_spec(LS.Cluster.Inserter, shutdown: 35_000),
      LS.Cluster.Optimizer,
      LS.Cluster.Monitor,
      LS.Recrawl.Scheduler,
      # Pipeline 2 (depth): its own queue, plus the compactor that folds
      # discovery + enrichment into the `businesses` product table every 5 min.
      LS.Cluster.EnrichmentQueue,
      LS.Cluster.Compactor,
      # Pipeline 3 (verification): authoritative sources → verified_facts.
      # Runs on the master only — bulk downloads against official endpoints
      # from one polite client, never spread across the fleet.
      {Task.Supervisor, name: LS.Verification.TaskSupervisor},
      LS.Verification.Scheduler,
      # Ops: infra/quality alerts (email) + the weekly report. Master-only.
      LS.Ops.Sentinel,
      LSWeb.Endpoint
    ]
    if mode == "ctl_live", do: master ++ [LS.CTL.PlatformRegistry, LS.CTL.Poller],
    else: (Logger.info("📭 CTL polling disabled (mode=#{mode})"); master)
  end

  # A worker runs one or both lanes, set by `LS_LANES` (default "discovery"):
  #
  #     LS_LANES=discovery              small VPS — breadth, the CT firehose
  #     LS_LANES=discovery,enrichment   big node — also does depth
  #     LS_LANES=enrichment             dedicated depth node (e.g. the home NUC,
  #                                     where a residential IP and camoufox let
  #                                     us read sites that block the VPS fleet)
  #
  # Both lanes share every resolver, cache and rate limiter below — that is the
  # point: enrichment must be exactly as polite as discovery.
  defp role_children("worker", _mode) do
    LS.Signatures.load_all()
    LS.HTTP.DomainFilter.load_tlds()
    LS.HTTP.IPRateLimiter.init()

    shared = [
      LS.DNS.Resolver,
      LS.BGP.Resolver,
      LS.RDAP.Client,
      # Tranco STAYS on workers: LS.HTTP.DomainFilter uses it as a crawl
      # bypass, so dropping it would silently narrow discovery.
      LS.Reputation.Tranco,
      # Majestic deliberately absent — it is only a data column, and the
      # master backfills it in LS.Reputation.fill/1. That is 101 MB of ETS
      # (plus a daily reload spike) returned to every worker.
      LS.Reputation.Blocklist,
      LS.ML.Classifier,
      LS.HTTP.PerformanceTracker
    ]

    lanes = worker_lanes()
    Logger.info("🛣️  Worker lanes: #{Enum.join(lanes, ", ")}")

    shared ++
      if("discovery" in lanes, do: [LS.Cluster.WorkerAgent], else: []) ++
      if("enrichment" in lanes, do: [LS.Enrichment.Agent], else: [])
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
