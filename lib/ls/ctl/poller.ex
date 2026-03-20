defmodule LS.CTL.Poller do
  @moduledoc """
  Adaptive Multi-Worker CT Log Poller with Smart Platform Detection

  Features:
  - Smart CTL cache with platform detection
  - Allows duplicate domains until platform detected
  - Auto-scaling workers (up to 100 per log)
  - Multiple CT logs in parallel

  CT Log URLs updated February 2026.
  Source: Chrome CT log list v80.6 (2025-12-25)
  https://chromium.googlesource.com/chromium/src/+/refs/heads/main/components/certificate_transparency/data/log_list.json

  NOTE: CT logs are sharded by certificate expiry date (H1 = Jan-Jun, H2 = Jul-Dec).
  Logs must be updated every ~6 months as old shards freeze and new ones become active.
  DigiCert replaced Nessie/Yeti with Wyvern+Sphinx lines in 2025.
  Let's Encrypt shut down all RFC 6962 logs (Feb 28 2026) — migrated to Static CT API.
  Sectigo replaced Mammoth/Sabre (read-only Sep 2025) with Elephant+Tiger lines.
  """

  use GenServer
  require Logger

  alias LS.CTL.{DomainParser, SharedHostingFilter, Scorer}
  alias LS.Cache

  @ets_work_queue :ctl_work_queue

  # ===========================================================================
  # CT LOG CONFIGS - Updated February 2026
  #
  # To update in future: check Chrome's log_list.json for "usable" logs
  # whose temporal_interval covers the current date.
  # Google logs cap batch_size at 32.
  # Cloudflare/Sectigo support larger batches (256-512).
  # DigiCert Wyvern/Sphinx - test batch sizes with scripts/analyze_ct_logs.exs
  # ===========================================================================

  @log_configs [
    # --- Google (US-based, "Argon" line) ---
    # Covers certs expiring Jan 1 2026 – Jul 1 2026
    %{
      name: "Google Argon 2026h1",
      url: "https://ct.googleapis.com/logs/us1/argon2026h1/ct/v1",
      batch_size: 32,
      avg_entries: 26,
      min_workers: 2,
      max_workers: 30,
      target_lag: 10_000
    },
    # Covers certs expiring Jul 1 2026 – Jan 1 2027
    %{
      name: "Google Argon 2026h2",
      url: "https://ct.googleapis.com/logs/us1/argon2026h2/ct/v1",
      batch_size: 32,
      avg_entries: 26,
      min_workers: 2,
      max_workers: 30,
      target_lag: 10_000
    },

    # --- Google (EU-based, "Xenon" line) ---
    # Same cert coverage as Argon but EU infrastructure — often faster for bulk scraping
    %{
      name: "Google Xenon 2026h1",
      url: "https://ct.googleapis.com/logs/eu1/xenon2026h1/ct/v1",
      batch_size: 32,
      avg_entries: 26,
      min_workers: 2,
      max_workers: 20,
      target_lag: 10_000
    },
    %{
      name: "Google Xenon 2026h2",
      url: "https://ct.googleapis.com/logs/eu1/xenon2026h2/ct/v1",
      batch_size: 32,
      avg_entries: 26,
      min_workers: 2,
      max_workers: 20,
      target_lag: 10_000
    },

    # --- Cloudflare (Nimbus line) ---
    # Covers all certs expiring in 2026 (full year shard)
    %{
      name: "Cloudflare Nimbus 2026",
      url: "https://ct.cloudflare.com/logs/nimbus2026/ct/v1",
      batch_size: 512,
      avg_entries: 512,
      min_workers: 1,
      max_workers: 5,
      target_lag: 50_000
    },

    # --- DigiCert (Wyvern line — replaces Nessie, retired Apr 2025) ---
    %{
      name: "DigiCert Wyvern 2026h1",
      url: "https://wyvern.ct.digicert.com/2026h1/ct/v1",
      batch_size: 64,
      avg_entries: 64,
      min_workers: 1,
      max_workers: 5,
      target_lag: 20_000
    },
    %{
      name: "DigiCert Wyvern 2026h2",
      url: "https://wyvern.ct.digicert.com/2026h2/ct/v1",
      batch_size: 128,    # was 64 — actual yield is ~116
      avg_entries: 116,    # was 64
      min_workers: 1,
      max_workers: 5,
      target_lag: 20_000
    },

    # --- Sectigo (Elephant line — replaces Mammoth/Sabre, read-only Sep 2025) ---
    %{
      name: "Sectigo Tiger 2026h1",
      url: "https://tiger2026h1.ct.sectigo.com/ct/v1",
      batch_size: 128,
      avg_entries: 128,
      min_workers: 1,
      max_workers: 5,
      target_lag: 50_000
    }
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def stats do
    GenServer.call(__MODULE__, :stats, 30_000)
  end

  @impl true
  def init(_opts) do
    :ets.new(@ets_work_queue, [:set, :public, :named_table, read_concurrency: true, write_concurrency: true])

    logs = Application.get_env(:ls, :ctl_logs, @log_configs)

    log_states = Enum.map(logs, fn config ->
      case get_tree_size(config.url) do
        {:ok, tree_size} ->
          :ets.insert(@ets_work_queue, {config.name, tree_size})
          Logger.info("📊 #{config.name}: tree_size=#{tree_size}")
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
      case get_tree_size(log_state.config.url) do
        {:ok, current_tree_size} ->
          [{_, next_index}] = :ets.lookup(@ets_work_queue, log_state.config.name)
          behind = current_tree_size - next_index
          optimal_workers = calculate_optimal_workers(behind, log_state.config)

          cond do
            # Revive a previously failed log
            log_state.tree_size == 0 and current_tree_size > 0 ->
              Logger.info("🔄 #{log_state.config.name}: Revived! tree_size=#{current_tree_size}")
              :ets.insert(@ets_work_queue, {log_state.config.name, current_tree_size})
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
  def handle_call(:stats, _from, state) do
    uptime = System.monotonic_time(:second) - state.start_time

    log_stats = Enum.map(state.logs, fn log_state ->
      [{_, next_index}] = :ets.lookup(@ets_work_queue, log_state.config.name)
      behind = log_state.tree_size - next_index

      %{
        name: log_state.config.name,
        tree_size: log_state.tree_size,
        next_index: next_index,
        behind: behind,
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
    # Check tree_size BEFORE claiming to avoid index racing
    case get_tree_size(log_config.url) do
      {:ok, tree_size} ->
        [{_, current_index}] = :ets.lookup(@ets_work_queue, log_config.name)
        cond do
          # Caught up — wait for new entries
          current_index >= tree_size ->
            Process.sleep(5_000)
            worker_loop(log_config, manager_pid)
          # Index way ahead of tree (log shrank or reset) — fix once, quietly
          current_index > tree_size + 1000 ->
            Logger.info("🔄 #{log_config.name}: Index reset (was #{current_index}, tree: #{tree_size})")
            :ets.insert(@ets_work_queue, {log_config.name, tree_size})
            Process.sleep(5_000)
            worker_loop(log_config, manager_pid)
          # Behind — claim and process
          true ->
            case claim_next_batch(log_config.name, log_config.batch_size) do
              {:ok, start_idx, end_idx} ->
                actual_end = min(end_idx, tree_size - 1)
                if start_idx < tree_size do
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

  defp fetch_and_process(log_config, start_idx, end_idx) do
    case fetch_entries(log_config.url, start_idx, end_idx) do
      {:ok, entries} ->
        process_entries_with_cache(entries)

      {:error, _reason} ->
        %{processed: 0, written: 0, filtered: 0}
    end
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

  defp fetch_entries(log_url, start_idx, end_idx) do
    url = "#{log_url}/get-entries"

    case Req.get(url, params: [start: start_idx, end: end_idx], receive_timeout: 30_000, retry: false) do
      {:ok, %{status: 200, body: %{"entries" => entries}}} ->
        {:ok, entries}
      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}
      {:error, error} ->
        {:error, error}
    end
  end

  defp get_tree_size(log_url) do
    url = "#{log_url}/get-sth"

    case Req.get(url, receive_timeout: 10_000, retry: false) do
      {:ok, %{status: 200, body: %{"tree_size" => size}}} ->
        {:ok, size}
      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}
      {:error, error} ->
        {:error, error}
    end
  end

  # ============================================================================
  # ENTRY PROCESSING - SIMPLIFIED WITH SMART CACHE
  # ============================================================================

  defp process_entries_with_cache(entries) do
    Enum.reduce(entries, %{processed: 0, written: 0, filtered: 0}, fn entry, acc ->
      case parse_entry(entry) do
        {:ok, cert_data} ->
          domain = cert_data.ctl_domain

          # Step 1: Manual filter (fastest - known platforms)
          if SharedHostingFilter.shared_platform?(domain) do
            %{acc | processed: acc.processed + 1, filtered: acc.filtered + 1}
          else
            # Step 2: Track in smart cache (updates cert_count, subdomain_count)
            track_result = Cache.ctl_track(domain, cert_data.ctl_subdomain_count)
            if Cache.ctl_is_platform?(domain) do
              %{acc | filtered: acc.filtered + 1}
            else
              if track_result == :new do
                scores = Scorer.score(cert_data)
                LS.Cluster.WorkQueue.enqueue(Map.merge(cert_data, scores))
              end
              %{acc | written: acc.written + 1}
            end
          end

        {:error, _} ->
          %{acc | processed: acc.processed + 1}
      end
    end)
  end

  defp parse_entry(%{"leaf_input" => leaf_input}) do
    with {:ok, decoded} <- Base.decode64(leaf_input),
         {:ok, cert_data} <- parse_leaf_input(decoded) do
      {:ok, cert_data}
    else
      _ -> {:error, :parse_failed}
    end
  end
  defp parse_entry(_), do: {:error, :invalid_entry}

  defp parse_leaf_input(<<_version::8, _leaf_type::8, _timestamp::64, 0::16, cert_length::24, cert_der::binary-size(cert_length), _rest::binary>>) do
    case X509.Certificate.from_der(cert_der) do
      {:ok, cert} -> parse_certificate(cert)
      {:error, _} -> {:error, :invalid_x509_cert}
    end
  end
  defp parse_leaf_input(<<_version::8, _leaf_type::8, _timestamp::64, 1::16, _rest::binary>>), do: {:error, :skip_precert}
  defp parse_leaf_input(_), do: {:error, :invalid_format}

  defp parse_certificate(cert) do
    domain = extract_domain(cert)

    if domain do
      case DomainParser.parse(domain) do
        {:ok, base_domain, tld} ->
          {subdomain_count, subdomain_list} = extract_subdomains(domain, base_domain)

          {:ok, %{
            ctl_domain: base_domain,
            ctl_tld: tld,
            ctl_issuer: extract_issuer(cert),
            ctl_subdomain_count: subdomain_count,
            ctl_subdomains: subdomain_list
          }}
        :error ->
          {:error, :invalid_domain}
      end
    else
      {:error, :no_domain}
    end
  end

  defp extract_subdomains(full_domain, base_domain) do
    clean_full = String.replace(full_domain, ~r/^\*\./, "")

    if clean_full == base_domain do
      {0, ""}
    else
      base_len = String.length(base_domain)
      full_len = String.length(clean_full)

      if full_len > base_len + 1 do
        subdomain_part = String.slice(clean_full, 0, full_len - base_len - 1)
        subdomains = String.split(subdomain_part, ".")
        |> Enum.take(50)
        |> Enum.join("|")

        {length(String.split(subdomains, "|")), subdomains}
      else
        {0, ""}
      end
    end
  end

  defp extract_domain(cert) do
    case X509.Certificate.subject(cert) do
      {:rdnSequence, attrs} ->
        find_cn(attrs) || find_san(cert)
      _ ->
        find_san(cert)
    end
  end

  defp find_cn(attrs) do
    attrs
    |> Enum.find(fn attr_list ->
      Enum.any?(attr_list, fn
        {:AttributeTypeAndValue, {2, 5, 4, 3}, _} -> true
        _ -> false
      end)
    end)
    |> case do
      nil -> nil
      attr_list ->
        Enum.find_value(attr_list, fn
          {:AttributeTypeAndValue, {2, 5, 4, 3}, {:utf8String, domain}} -> domain
          _ -> nil
        end)
    end
  end

  defp find_san(cert) do
    case X509.Certificate.extension(cert, :subject_alt_name) do
      {:Extension, {2, 5, 29, 17}, _, san_value} ->
        san_value
        |> Enum.find_value(fn
          {:dNSName, domain} -> to_string(domain)
          _ -> nil
        end)
      _ ->
        nil
    end
  end

  defp extract_issuer(cert) do
    case X509.Certificate.issuer(cert) do
      {:rdnSequence, attrs} ->
        attrs
        |> Enum.find(fn attr_list ->
          Enum.any?(attr_list, fn
            {:AttributeTypeAndValue, {2, 5, 4, 3}, _} -> true
            _ -> false
          end)
        end)
        |> case do
          nil -> "Unknown"
          attr_list ->
            Enum.find_value(attr_list, fn
              {:AttributeTypeAndValue, {2, 5, 4, 3}, {:utf8String, issuer}} -> issuer
              {:AttributeTypeAndValue, {2, 5, 4, 3}, {:printableString, issuer}} -> to_string(issuer)
              _ -> nil
            end) || "Unknown"
        end
      _ ->
        "Unknown"
    end
  end

  defp schedule_worker_adjustment do
    Process.send_after(self(), :adjust_workers, 30_000)
  end
end
