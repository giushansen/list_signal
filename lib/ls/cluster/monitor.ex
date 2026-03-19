defmodule LS.Cluster.Monitor do
  @moduledoc """
  Cluster health monitor. Logs stats every 30 seconds.

  Runs on master node. Reports queue depth, worker status, insert rate, alerts.

  ## Stats

      LS.Cluster.Monitor.stats()
      LS.Cluster.Monitor.watch()   # live refresh every 5s
      LS.Cluster.Monitor.stop_watch()
  """

  use GenServer
  require Logger

  @log_interval_ms 30_000
  @alert_queue_pct 80.0

  # ==========================================================================
  # CLIENT API
  # ==========================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get full cluster status."
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc "Start live watch (prints every 5s)."
  def watch do
    GenServer.cast(__MODULE__, :start_watch)
  end

  @doc "Stop live watch."
  def stop_watch do
    GenServer.cast(__MODULE__, :stop_watch)
  end

  # ==========================================================================
  # GENSERVER
  # ==========================================================================

  @impl true
  def init(_opts) do
    schedule_log()
    Logger.info("📊 Cluster Monitor started (interval: #{div(@log_interval_ms, 1000)}s)")
    {:ok, %{watching: false}}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply, collect_stats(), state}
  end

  @impl true
  def handle_cast(:start_watch, state) do
    unless state.watching do
      Process.send_after(self(), :watch_tick, 5_000)
    end
    {:noreply, %{state | watching: true}}
  end

  @impl true
  def handle_cast(:stop_watch, state) do
    {:noreply, %{state | watching: false}}
  end

  @impl true
  def handle_info(:log_stats, state) do
    log_cluster_status()
    schedule_log()
    {:noreply, state}
  end

  @impl true
  def handle_info(:watch_tick, %{watching: true} = state) do
    print_dashboard()
    Process.send_after(self(), :watch_tick, 5_000)
    {:noreply, state}
  end

  @impl true
  def handle_info(:watch_tick, state), do: {:noreply, state}

  # ==========================================================================
  # PRIVATE
  # ==========================================================================

  defp collect_stats do
    queue = try do LS.Cluster.WorkQueue.stats() rescue _ -> nil catch :exit, _ -> nil end
    inserter = try do LS.Cluster.Inserter.stats() rescue _ -> nil catch :exit, _ -> nil end
    workers = Node.list() |> Enum.map(&Atom.to_string/1)

    %{
      queue: queue,
      inserter: inserter,
      workers: workers,
      worker_count: length(workers),
      node: Node.self() |> Atom.to_string()
    }
  end

  defp log_cluster_status do
    s = collect_stats()

    q = s.queue || %{}
    i = s.inserter || %{}

    queue_depth = Map.get(q, :queue_depth, 0)
    queue_pct = Map.get(q, :queue_pct, 0.0)
    inflight = Map.get(q, :inflight_batches, 0)
    enqueue_rate = Map.get(q, :enqueue_rate_per_min, 0.0)
    drain_rate = Map.get(q, :drain_rate_per_min, 0.0)
    insert_rate = Map.get(i, :insert_rate_per_min, 0.0)
    ch_buffer = Map.get(i, :buffer_size, 0)
    ch_errors = Map.get(i, :total_errors, 0)

    workers_str = if s.worker_count > 0,
      do: "#{s.worker_count} (#{Enum.join(s.workers, ", ")})",
      else: "0 ⚠️"

    Logger.info(
      "[CLUSTER] Queue: #{format_num(queue_depth)} (#{queue_pct}%) | " <>
      "In: #{enqueue_rate}/min | Out: #{drain_rate}/min | " <>
      "Workers: #{workers_str} | Inflight: #{inflight} | " <>
      "CH insert: #{insert_rate}/min buf=#{ch_buffer}" <>
      if(ch_errors > 0, do: " errors=#{ch_errors}", else: "")
    )

    # Alerts
    if queue_pct >= @alert_queue_pct do
      net_rate = enqueue_rate - drain_rate
      eta_min = if net_rate > 0, do: Float.round((5_000_000 - queue_depth) / net_rate, 0), else: :inf

      Logger.warning(
        "⚠️  QUEUE #{queue_pct}% FULL (#{format_num(queue_depth)}/5M) | " <>
        "Growing at +#{Float.round(net_rate, 0)}/min | " <>
        "ETA to full: #{eta_min} min → Add workers or increase concurrency"
      )
    end

    if s.worker_count == 0 and queue_depth > 0 do
      Logger.warning("⚠️  NO WORKERS CONNECTED — queue depth: #{format_num(queue_depth)}")
    end
  end

  defp print_dashboard do
    s = collect_stats()
    q = s.queue || %{}
    i = s.inserter || %{}

    IO.puts("\n" <> String.duplicate("━", 60))
    IO.puts("  LISTSIGNAL CLUSTER DASHBOARD")
    IO.puts(String.duplicate("━", 60))
    IO.puts("  Queue:     #{format_num(Map.get(q, :queue_depth, 0))} (#{Map.get(q, :queue_pct, 0)}%)")
    IO.puts("  In:        #{Map.get(q, :enqueue_rate_per_min, 0)}/min")
    IO.puts("  Out:       #{Map.get(q, :drain_rate_per_min, 0)}/min")
    IO.puts("  Workers:   #{s.worker_count} #{inspect(s.workers)}")
    IO.puts("  Inflight:  #{Map.get(q, :inflight_batches, 0)} batches")
    IO.puts("  CH insert: #{Map.get(i, :insert_rate_per_min, 0)}/min (buf: #{Map.get(i, :buffer_size, 0)})")
    IO.puts("  Completed: #{format_num(Map.get(q, :total_completed, 0))}")
    IO.puts(String.duplicate("━", 60))
  end

  defp format_num(n) when is_integer(n) and n >= 1_000_000 do
    "#{Float.round(n / 1_000_000, 1)}M"
  end
  defp format_num(n) when is_integer(n) and n >= 1_000 do
    "#{Float.round(n / 1_000, 1)}K"
  end
  defp format_num(n), do: to_string(n)

  defp schedule_log do
    Process.send_after(self(), :log_stats, @log_interval_ms)
  end
end
