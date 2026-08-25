defmodule LS.CTL.Poller do
  @moduledoc """
  Multi-worker CT log poller across BOTH publication protocols — classic
  RFC 6962 (`get-sth`/`get-entries`) and the Static CT API (checkpoint +
  CDN-served 256-entry data tiles, `c2sp.org/static-ct-api`), which is how
  Let's Encrypt publishes since Feb 2026 and how several newer operators
  publish exclusively.

  ## Where the log list comes from (2026-08-25)

  Sources are no longer hardcoded. `LS.CTL.Sources.desired/2` derives them
  from Chrome's log list at boot, and `:reconcile_sources` re-derives every
  #{div(21_600_000, 3_600_000)}h — starting pollers for logs Chrome added and retiring pollers for logs
  it pulled, then emailing what changed. The hand-maintained list went stale
  twice in two days (frozen 2026h1 shards polling for zero rows; Sectigo
  Mammoth/Sabre retired under us) and each staleness silently narrows
  discovery, which is the product's most upstream data.

  Entry parsing lives in `LS.CTL.Wire` (pure, hostile-input-tested): both
  entry types (precerts included — most CAs log nothing else) and every SAN
  in each certificate, not just the first.

  Downstream: `LS.Cache.ctl_track/2` dedups the cross-log firehose, the
  `PlatformRegistry` filters shared-hosting platforms, and only genuinely new
  base domains reach `LS.Cluster.WorkQueue`.
  """

  use GenServer
  require Logger

  alias LS.Cache
  alias LS.CTL.{PlatformRegistry, Sources, Wire}

  @ets_work_queue :ctl_work_queue
  @reconcile_ms :timer.hours(6)
  # Tiles are immutable 256-entry CDN objects; claims stay tile-aligned.
  @tile_size 256

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def stats do
    GenServer.call(__MODULE__, :stats, 30_000)
  end

  @doc "The sources being polled right now (admin display + LS.CTL.LogList's drift diff)."
  def configs do
    case Application.get_env(:ls, :ctl_logs) do
      nil -> GenServer.call(__MODULE__, :configs, 5_000)
      logs -> logs
    end
  catch
    :exit, _ -> Sources.fallback()
  end

  @impl true
  def init(_opts) do
    :ets.new(@ets_work_queue, [:set, :public, :named_table, read_concurrency: true, write_concurrency: true])

    logs = Application.get_env(:ls, :ctl_logs) || boot_sources()

    log_states = Enum.map(logs, fn config ->
      case get_tree_size(config) do
        {:ok, tree_size} ->
          :ets.insert(@ets_work_queue, {config.name, start_index(config, tree_size)})
          Logger.info("📊 #{config.name}: tree_size=#{tree_size} (#{config[:protocol] || :rfc6962})")
          spawn_workers(config, config.min_workers)

          %{
            config: config,
            tree_size: tree_size,
            active_workers: config.min_workers,
            total_processed: 0
          }

        {:error, reason} ->
          Logger.error("❌ Failed to get tree size for #{config.name}: #{inspect(reason)}")
          :ets.insert(@ets_work_queue, {config.name, 0})

          %{
            config: config,
            tree_size: 0,
            active_workers: 0,
            total_processed: 0
          }
      end
    end)

    active_count = Enum.count(log_states, fn s -> s.tree_size > 0 end)
    failed_count = Enum.count(log_states, fn s -> s.tree_size == 0 end)

    state = %{
      logs: log_states,
      total_written: 0,
      total_filtered: 0,
      start_time: System.monotonic_time(:second)
    }

    schedule_worker_adjustment()
    Process.send_after(self(), :reconcile_sources, @reconcile_ms)

    if failed_count > 0 do
      Logger.warning("⚠️  CTL Poller started: #{active_count}/#{length(logs)} logs active (#{failed_count} failed)")
    else
      Logger.info("✅ CTL Poller started with #{active_count} CT logs + smart platform detection")
    end

    {:ok, state}
  end

  @impl true
  def handle_info(:adjust_workers, state) do
    new_logs = Enum.map(state.logs, fn log_state ->
      case get_tree_size(log_state.config) do
        {:ok, current_tree_size} ->
          next_index = next_index_of(log_state.config.name)
          behind = current_tree_size - next_index
          optimal_workers = calculate_optimal_workers(behind, log_state.config)

          cond do
            # Revive a previously failed log
            log_state.tree_size == 0 and current_tree_size > 0 ->
              Logger.info("🔄 #{log_state.config.name}: Revived! tree_size=#{current_tree_size}")
              :ets.insert(@ets_work_queue, {log_state.config.name, start_index(log_state.config, current_tree_size)})
              spawn_workers(log_state.config, log_state.config.min_workers)
              %{log_state | active_workers: log_state.config.min_workers, tree_size: current_tree_size}

            optimal_workers > log_state.active_workers ->
              new_workers = optimal_workers - log_state.active_workers
              spawn_workers(log_state.config, new_workers)
              Logger.info("📈 #{log_state.config.name}: Scaling UP to #{optimal_workers} workers (behind: #{behind})")
              %{log_state | active_workers: optimal_workers, tree_size: current_tree_size}

            true ->
              %{log_state | tree_size: current_tree_size}
          end

        {:error, _} ->
          log_state
      end
    end)

    schedule_worker_adjustment()
    {:noreply, %{state | logs: new_logs}}
  end

  @impl true
  def handle_info(:reconcile_sources, state) do
    Process.send_after(self(), :reconcile_sources, @reconcile_ms)

    case Sources.fetch_desired() do
      {:ok, desired} ->
        {:noreply, apply_reconcile(state, Sources.reconcile(running_configs(state), desired))}

      {:error, reason} ->
        # A failed fetch changes nothing (Sources.reconcile also refuses to
        # stop anything on an empty list) — ingestion outlives gstatic blips.
        Logger.warning("[CTL] source reconcile skipped: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:cleanup_cache, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:work_done, log_name, stats}, state) do
    new_logs = Enum.map(state.logs, fn log_state ->
      if log_state.config.name == log_name do
        %{log_state | total_processed: log_state.total_processed + stats.processed}
      else
        log_state
      end
    end)

    new_state = %{state |
      logs: new_logs,
      total_written: state.total_written + stats.written,
      total_filtered: state.total_filtered + stats.filtered
    }

    {:noreply, new_state}
  end

  @impl true
  def handle_call(:configs, _from, state), do: {:reply, running_configs(state), state}

  @impl true
  def handle_call(:stats, _from, state) do
    uptime = System.monotonic_time(:second) - state.start_time

    log_stats = Enum.map(state.logs, fn log_state ->
      next_index = next_index_of(log_state.config.name)

      %{
        name: log_state.config.name,
        protocol: log_state.config[:protocol] || :rfc6962,
        tree_size: log_state.tree_size,
        next_index: next_index,
        behind: max(log_state.tree_size - next_index, 0),
        active_workers: log_state.active_workers,
        total_processed: log_state.total_processed
      }
    end)

    cache_stats = Cache.ctl_stats()

    stats = %{
      uptime_seconds: uptime,
      total_logs: length(state.logs),
      active_logs: Enum.count(log_stats, fn s -> s.tree_size > 0 end),
      total_written: state.total_written,
      total_filtered: state.total_filtered,
      filter_rate: if state.total_written > 0 do
        Float.round(state.total_filtered / state.total_written * 100, 1)
      else
        0.0
      end,
      domains_per_sec: if uptime > 0 do
        Float.round(state.total_written / uptime, 2)
      else
        0.0
      end,
      ctl_cache: cache_stats,
      logs: log_stats
    }

    {:reply, stats, state}
  end

  # ============================================================================
  # WORKER SPAWNING & MANAGEMENT
  # ============================================================================

  defp spawn_workers(log_config, count) do
    manager_pid = self()

    for _ <- 1..count do
      spawn_link(fn ->
        worker_loop(log_config, manager_pid)
      end)
    end
  end

  defp worker_loop(log_config, manager_pid) do
    # A retired source's ETS row is deleted by :reconcile_sources; its workers
    # notice here and exit. They are spawn_linked, so anything but a normal
    # exit would take the whole poller down with them.
    case :ets.lookup(@ets_work_queue, log_config.name) do
      [] ->
        :ok

      [{_, current_index}] ->
        # Check tree_size BEFORE claiming to avoid index racing
        case get_tree_size(log_config) do
          {:ok, tree_size} ->
            # Static logs are read in immutable full tiles: entries past the
            # last complete tile stay unclaimed until the tile fills (≤255
            # entries of lag, i.e. seconds).
            head = effective_head(log_config, tree_size)

            cond do
              # Caught up — wait for new entries
              current_index >= head ->
                Process.sleep(5_000)
                worker_loop(log_config, manager_pid)

              # Index way ahead of tree (log shrank or reset) — fix once, quietly
              current_index > head + 1000 ->
                Logger.info("🔄 #{log_config.name}: Index reset (was #{current_index}, tree: #{tree_size})")
                :ets.insert(@ets_work_queue, {log_config.name, start_index(log_config, tree_size)})
                Process.sleep(5_000)
                worker_loop(log_config, manager_pid)

              # Behind — claim and process
              true ->
                case claim_next_batch(log_config.name, log_config.batch_size) do
                  {:ok, start_idx, end_idx} ->
                    actual_end = min(end_idx, head - 1)

                    if start_idx < head do
                      stats = fetch_and_process(log_config, start_idx, actual_end)
                      send(manager_pid, {:work_done, log_config.name, stats})
                    end

                    worker_loop(log_config, manager_pid)

                  {:error, _} ->
                    Process.sleep(5_000)
                    worker_loop(log_config, manager_pid)
                end
            end

          {:error, _reason} ->
            Process.sleep(5_000)
            worker_loop(log_config, manager_pid)
        end
    end
  end

  defp next_index_of(name) do
    case :ets.lookup(@ets_work_queue, name) do
      [{_, idx}] -> idx
      [] -> 0
    end
  end

  # Static logs start at (and reset to) a tile boundary so claims of
  # @tile_size stay aligned with the immutable tile objects forever.
  defp start_index(%{protocol: :static_ct}, tree_size), do: tree_size - rem(tree_size, @tile_size)
  defp start_index(_config, tree_size), do: tree_size

  defp effective_head(%{protocol: :static_ct}, tree_size), do: tree_size - rem(tree_size, @tile_size)
  defp effective_head(_config, tree_size), do: tree_size

  defp claim_next_batch(log_name, batch_size) do
    try do
      old_value = :ets.update_counter(@ets_work_queue, log_name, {2, batch_size})
      start_idx = old_value
      end_idx = old_value + batch_size - 1
      {:ok, start_idx, end_idx}
    catch
      _ -> {:error, :claim_failed}
    end
  end

  # A data tile is an immutable CDN object: it arrives whole or not at all,
  # so the range-consumer below does not apply — but a transient CDN error
  # would otherwise skip 256 claimed entries forever, so failures get retried
  # in place a few times before giving up.
  defp fetch_and_process(%{protocol: :static_ct} = config, start_idx, end_idx) do
    Enum.reduce_while(1..3, %{processed: 0, written: 0, filtered: 0}, fn attempt, zero ->
      case fetch_parsed(config, start_idx, end_idx) do
        {:ok, parsed_entries} ->
          {:halt, process_entries_with_cache(parsed_entries)}

        {:error, _} when attempt < 3 ->
          Process.sleep(2_000 * attempt)
          {:cont, zero}

        {:error, _} ->
          {:halt, zero}
      end
    end)
  end

  defp fetch_and_process(log_config, start_idx, end_idx) do
    {parsed_entries, _consumed} =
      consume_range(start_idx, end_idx, fn s, e -> fetch_parsed(log_config, s, e) end)

    process_entries_with_cache(parsed_entries)
  end

  @doc false
  # Fetch [start, end] completely, however many round-trips it takes. A log
  # may return fewer entries than asked (Google caps get-entries by response
  # size, so 32 asked can be 7 answered) and the claim counter has already
  # advanced past `end` — anything not fetched here is skipped FOREVER. Found
  # live 2026-08-25: 25 of 32 entries silently dropped on a Google batch.
  # Returns {entries, consumed}; an error mid-range keeps what was fetched;
  # the guard bounds a log that keeps answering short.
  def consume_range(start_idx, end_idx, fetch_fun), do: do_consume(start_idx, end_idx, fetch_fun, [], 0)

  defp do_consume(start_idx, end_idx, _f, acc, guard) when start_idx > end_idx or guard >= 50,
    do: finish(acc)

  defp do_consume(start_idx, end_idx, fetch_fun, acc, guard) do
    case fetch_fun.(start_idx, end_idx) do
      {:ok, entries} when is_list(entries) and entries != [] ->
        do_consume(start_idx + length(entries), end_idx, fetch_fun, [entries | acc], guard + 1)

      _empty_or_error ->
        finish(acc)
    end
  end

  defp finish(acc) do
    entries = acc |> Enum.reverse() |> Enum.concat()
    {entries, length(entries)}
  end

  defp calculate_optimal_workers(behind, config) do
    cond do
      behind > 500_000 -> config.max_workers
      behind > 100_000 -> min(config.max_workers, div(behind, 2_000) * config.min_workers)
      behind > 50_000 -> min(config.max_workers, div(config.max_workers * 3, 4))
      behind > config.target_lag -> min(config.max_workers, div(config.max_workers, 4))
      true -> config.min_workers
    end
  end

  # ============================================================================
  # CT LOG API
  # ============================================================================

  # Returns `{:ok, [[cert_data]]}` — one inner list per log entry, each
  # holding one cert_data per base domain in that certificate (LS.CTL.Wire).
  defp fetch_parsed(%{protocol: :static_ct} = config, start_idx, _end_idx) do
    tile = div(start_idx, @tile_size)
    url = "#{config.url}/tile/data/#{Wire.tile_path(tile)}"

    case Req.get(url, receive_timeout: 30_000, retry: false, finch: LS.Finch.CTL, pool_timeout: 10_000) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok, tile_entries(body)}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp fetch_parsed(config, start_idx, end_idx) do
    url = "#{config.url}/get-entries"

    case Req.get(url, params: [start: start_idx, end: end_idx], receive_timeout: 30_000, retry: false, finch: LS.Finch.CTL, pool_timeout: 10_000) do
      {:ok, %{status: 200, body: %{"entries" => entries}}} when is_list(entries) ->
        {:ok, Enum.map(entries, &leaf_entries/1)}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp leaf_entries(%{"leaf_input" => leaf_input}) when is_binary(leaf_input) do
    with {:ok, decoded} <- Base.decode64(leaf_input),
         {:ok, entries} <- Wire.parse_leaf_input(decoded) do
      entries
    else
      _ -> []
    end
  end

  defp leaf_entries(_), do: []

  defp tile_entries(body) do
    {:ok, flat} = Wire.parse_data_tile(body)
    # One wrapper per cert_data keeps the `processed` counter per-certificate,
    # matching the RFC-6962 path closely enough for the admin display.
    Enum.map(flat, &[&1])
  end

  defp get_tree_size(%{protocol: :static_ct} = config) do
    case Req.get("#{config.url}/checkpoint", receive_timeout: 10_000, retry: false, finch: LS.Finch.CTL, pool_timeout: 10_000, decode_body: false) do
      {:ok, %{status: 200, body: body}} when is_binary(body) -> Wire.parse_checkpoint(body)
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      {:error, error} -> {:error, error}
    end
  end

  defp get_tree_size(config) do
    case Req.get("#{config.url}/get-sth", receive_timeout: 10_000, retry: false, finch: LS.Finch.CTL, pool_timeout: 10_000) do
      {:ok, %{status: 200, body: %{"tree_size" => size}}} when is_integer(size) -> {:ok, size}
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      {:error, error} -> {:error, error}
    end
  end

  # ============================================================================
  # ENTRY PROCESSING - SIMPLIFIED WITH SMART CACHE
  # ============================================================================

  defp process_entries_with_cache(parsed_entries) do
    Enum.reduce(parsed_entries, %{processed: 0, written: 0, filtered: 0}, fn cert_datas, acc ->
      acc = %{acc | processed: acc.processed + 1}
      Enum.reduce(cert_datas, acc, &process_cert_data/2)
    end)
  end

  # One base domain from one certificate: platform-filter, dedup, enqueue.
  defp process_cert_data(cert_data, acc) do
    domain = cert_data.ctl_domain

    # Step 1: ONE platform check. The registry's ETS holds the static curated
    # list, the seeds, the persisted table and every velocity-learned platform
    # — an O(labels) suffix walk per domain.
    if PlatformRegistry.known?(domain) do
      %{acc | filtered: acc.filtered + 1}
    else
      # Step 2: track in the smart cache (updates cert_count, subdomain_count)
      track_result = Cache.ctl_track(domain, cert_data.ctl_subdomain_count)

      if Cache.ctl_is_platform?(domain) do
        # Feed the registry. It applies its own grace window, so a startup
        # that briefly spikes subdomains is not promoted permanently.
        PlatformRegistry.observe(domain, %{
          reason: "cert_rate",
          cert_count: Cache.ctl_cert_count(domain),
          max_subdomain_count: cert_data.ctl_subdomain_count || 0,
          estimated_hosted_domains: Cache.ctl_cert_count(domain)
        })

        %{acc | filtered: acc.filtered + 1}
      else
        if track_result == :new do
          LS.Cluster.WorkQueue.enqueue(cert_data)
        end

        %{acc | written: acc.written + 1}
      end
    end
  end

  defp running_configs(state), do: Enum.map(state.logs, & &1.config)

  # Start pollers Chrome added, retire pollers it pulled, email the change.
  # Retiring = deleting the ETS row; the log's workers see it and exit on
  # their next loop, so no process bookkeeping is needed here.
  defp apply_reconcile(state, %{start: [], stop: []}), do: state

  defp apply_reconcile(state, %{start: to_start, stop: to_stop}) do
    kept =
      Enum.reject(state.logs, fn ls ->
        if ls.config.name in to_stop do
          :ets.delete(@ets_work_queue, ls.config.name)
          Logger.info("[CTL] retired source: #{ls.config.name}")
          true
        end
      end)

    started =
      Enum.flat_map(to_start, fn config ->
        case get_tree_size(config) do
          {:ok, tree_size} ->
            :ets.insert(@ets_work_queue, {config.name, start_index(config, tree_size)})
            spawn_workers(config, config.min_workers)
            Logger.info("[CTL] new source: #{config.name} (#{config.protocol}, tree=#{tree_size})")
            [%{config: config, tree_size: tree_size, active_workers: config.min_workers, total_processed: 0}]

          {:error, reason} ->
            # Enter it at tree 0; the :adjust_workers revive path retries it.
            Logger.warning("[CTL] new source #{config.name} unreachable (#{inspect(reason)}) — will retry")
            :ets.insert(@ets_work_queue, {config.name, 0})
            [%{config: config, tree_size: 0, active_workers: 0, total_processed: 0}]
        end
      end)

    email_source_change(to_start, to_stop)
    %{state | logs: kept ++ started}
  end

  # The owner asked to hear about every CT source change by email — this is
  # the upstream of ALL domain discovery (and of Scoutbloc's phishing watch),
  # so a silent rotation is never acceptable. Sent directly, not via
  # LS.Alerts' cooldown: rotations are rare and each one matters.
  defp email_source_change(started, stopped) do
    body =
      "<h3>CT log sources reconciled</h3>" <>
        "<p>The poller updated itself from Chrome's log list:</p><ul>" <>
        Enum.map_join(started, "", &"<li>ADDED: #{&1.name} (#{&1.protocol})</li>") <>
        Enum.map_join(stopped, "", &"<li>RETIRED: #{&1}</li>") <>
        "</ul><p>No action needed unless a name here surprises you — " <>
        "LS.CTL.Sources.fallback/0 should be refreshed in the next deploy.</p>"

    case LS.Ops.Mail.send("[ListSignal] CT sources: +#{length(started)} −#{length(stopped)}", body) do
      :ok -> :ok
      other -> Logger.warning("[CTL] source-change email failed: #{inspect(other)}")
    end
  end

  # Chrome's list at boot, the baked snapshot if the fetch fails — a booting
  # poller must never sit sourceless waiting on gstatic.
  defp boot_sources do
    case Sources.fetch_desired() do
      {:ok, sources} ->
        sources

      {:error, reason} ->
        Logger.warning("[CTL] live log list unavailable at boot (#{inspect(reason)}); using baked fallback")
        Sources.fallback()
    end
  end

  defp schedule_worker_adjustment do
    Process.send_after(self(), :adjust_workers, 30_000)
  end
end
