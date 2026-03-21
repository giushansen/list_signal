defmodule LS.Cluster.Monitor do
  @moduledoc "Cluster health monitor. Logs stats every 30s. Runs on master node."

  use GenServer
  require Logger

  @log_interval_ms 30_000
  @alert_queue_pct 80.0

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def stats, do: GenServer.call(__MODULE__, :stats)
  def watch, do: GenServer.cast(__MODULE__, :start_watch)
  def stop_watch, do: GenServer.cast(__MODULE__, :stop_watch)

  @impl true
  def init(_opts) do
    schedule_log()
    Logger.info("📊 Cluster Monitor started (interval: #{div(@log_interval_ms, 1000)}s)")
    {:ok, %{watching: false}}
  end

  @impl true
  def handle_call(:stats, _from, state), do: {:reply, collect_stats(), state}

  @impl true
  def handle_cast(:start_watch, state) do
    unless state.watching, do: Process.send_after(self(), :watch_tick, 5_000)
    {:noreply, %{state | watching: true}}
  end
  def handle_cast(:stop_watch, state), do: {:noreply, %{state | watching: false}}

  @impl true
  def handle_info(:log_stats, state), do: (log_cluster_status(); schedule_log(); {:noreply, state})
  def handle_info(:watch_tick, %{watching: true} = state), do: (print_dashboard(); Process.send_after(self(), :watch_tick, 5_000); {:noreply, state})
  def handle_info(:watch_tick, state), do: {:noreply, state}

  defp collect_stats do
    q = sc(LS.Cluster.WorkQueue, :stats)
    i = sc(LS.Cluster.Inserter, :stats)
    t = sc(LS.Reputation.Tranco, :stats)
    m = sc(LS.Reputation.Majestic, :stats)
    b = sc(LS.Reputation.Blocklist, :stats)
    workers = Node.list() |> Enum.map(&Atom.to_string/1)
    %{queue: q, inserter: i, tranco: t, majestic: m, blocklist: b,
      workers: workers, worker_count: length(workers), node: Node.self() |> Atom.to_string()}
  end

  defp log_cluster_status do
    s = collect_stats()
    q = s.queue || %{}
    i = s.inserter || %{}
    t_count = get_in(s, [:tranco, :domains_loaded]) || 0
    m_count = get_in(s, [:majestic, :domains_loaded]) || 0
    b_count = get_in(s, [:blocklist, :total]) || 0

    depth = Map.get(q, :queue_depth, 0)
    pct = Map.get(q, :queue_pct, 0.0)
    dr = Map.get(q, :drain_rate_per_min, 0.0)
    er = Map.get(q, :enqueue_rate_per_min, 0.0)
    ir = Map.get(i, :insert_rate_per_min, 0.0)
    buf = Map.get(i, :buffer_size, 0)
    ch_err = Map.get(i, :total_errors, 0)

    w_str = if s.worker_count > 0, do: "#{s.worker_count} (#{Enum.join(s.workers, ", ")})", else: "0 ⚠️"

    Logger.info(
      "[CLUSTER] Queue: #{fnum(depth)} (#{pct}%) | In: #{er}/min | Out: #{dr}/min | " <>
      "Workers: #{w_str} | CH: #{ir}/min buf=#{buf}" <>
      if(ch_err > 0, do: " err=#{ch_err}", else: "") <>
      " | Rep: T:#{fnum(t_count)} M:#{fnum(m_count)} B:#{fnum(b_count)}"
    )

    if pct >= @alert_queue_pct do
      net = er - dr
      eta = if net > 0, do: Float.round((5_000_000 - depth) / net, 0), else: :inf
      Logger.warning("⚠️  QUEUE #{pct}% (#{fnum(depth)}/5M) growing +#{Float.round(net, 0)}/min ETA: #{eta}min")
    end
    if s.worker_count == 0 and depth > 0, do: Logger.warning("⚠️  NO WORKERS — depth: #{fnum(depth)}")
  end

  defp print_dashboard do
    s = collect_stats()
    q = s.queue || %{}
    i = s.inserter || %{}
    IO.puts("\n" <> String.duplicate("━", 60))
    IO.puts("  LISTSIGNAL CLUSTER DASHBOARD")
    IO.puts(String.duplicate("━", 60))
    IO.puts("  Queue:      #{fnum(Map.get(q, :queue_depth, 0))} (#{Map.get(q, :queue_pct, 0)}%)")
    IO.puts("  In:         #{Map.get(q, :enqueue_rate_per_min, 0)}/min")
    IO.puts("  Out:        #{Map.get(q, :drain_rate_per_min, 0)}/min")
    IO.puts("  Workers:    #{s.worker_count} #{inspect(s.workers)}")
    IO.puts("  CH insert:  #{Map.get(i, :insert_rate_per_min, 0)}/min (buf: #{Map.get(i, :buffer_size, 0)})")
    IO.puts("  Tranco:     #{get_in(s, [:tranco, :domains_loaded]) || 0} domains")
    IO.puts("  Majestic:   #{get_in(s, [:majestic, :domains_loaded]) || 0} domains")
    IO.puts("  Blocklist:  #{get_in(s, [:blocklist, :total]) || 0} domains")
    IO.puts(String.duplicate("━", 60))
  end

  defp sc(mod, msg), do: (try do GenServer.call(mod, msg, 5_000) rescue _ -> nil catch :exit, _ -> nil end)
  defp fnum(n) when is_integer(n) and n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp fnum(n) when is_integer(n) and n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp fnum(n), do: to_string(n)
  defp schedule_log, do: Process.send_after(self(), :log_stats, @log_interval_ms)
end
