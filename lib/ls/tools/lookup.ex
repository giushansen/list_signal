defmodule LS.Tools.Lookup do
  @moduledoc """
  On-demand single-domain enrichment for web tools.
  Runs LS.Pipeline in a monitored subprocess with timeout.
  """
  require Logger
  @timeout 30_000
  @cache_table :lookup_result_cache
  # Landing page lookups: re-crawl if older than 7 days regardless of business model
  @freshness_ttl_days 7

  @doc "Get a cached enrichment row for a domain, if available."
  def get_cached_row(domain) do
    case :ets.lookup(@cache_table, domain) do
      [{^domain, row, ts}] ->
        if System.monotonic_time(:second) - ts < 300, do: row, else: nil
      _ -> nil
    end
  rescue
    _ -> nil
  end

  def lookup(domain) when is_binary(domain) do
    domain = domain |> String.downcase() |> String.trim()
              |> String.replace(~r/^https?:\/\//, "") |> String.replace(~r/\/.*$/, "")

    Logger.info("[LOOKUP] Starting lookup for: #{domain}")

    # 1. Check ETS cache first (fastest)
    case get_cached_row(domain) do
      row when is_list(row) ->
        Logger.info("[LOOKUP] #{domain} — HIT from ETS cache")
        {:ok, parse_row(row, domain)}
      _ ->
        # 2. Check ClickHouse for fresh data
        case check_clickhouse(domain) do
          {:ok, data} ->
            Logger.info("[LOOKUP] #{domain} — HIT from ClickHouse (fresh)")
            {:ok, data}
          :stale ->
            # 3. Run the full pipeline
            Logger.info("[LOOKUP] #{domain} — cache miss, running pipeline")
            enrich_and_store(domain)
        end
    end
  rescue
    e ->
      Logger.error("[LOOKUP] #{domain} — EXCEPTION: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  defp check_clickhouse(domain) do
    case LS.Clickhouse.get_store(domain) do
      {:ok, [row | _]} ->
        enriched_at = Enum.at(row, 0)
        if fresh_enough?(enriched_at) do
          {:ok, parse_row(row, domain)}
        else
          Logger.debug("[LOOKUP] #{domain} — ClickHouse data older than #{@freshness_ttl_days}d (#{enriched_at})")
          :stale
        end
      {:ok, []} ->
        Logger.debug("[LOOKUP] #{domain} — not in ClickHouse")
        :stale
      {:error, reason} ->
        Logger.warning("[LOOKUP] #{domain} — ClickHouse error: #{inspect(reason)}")
        :stale
    end
  end

  defp fresh_enough?(nil), do: false
  defp fresh_enough?(ts) when is_binary(ts) do
    case Date.from_iso8601(String.slice(ts, 0, 10)) do
      {:ok, date} -> Date.diff(Date.utc_today(), date) < @freshness_ttl_days
      _ -> false
    end
  end
  defp fresh_enough?(_), do: false

  defp enrich_and_store(domain) do
    {pid, monitor_ref} = spawn_monitor(fn ->
      result = try do
        Logger.info("[LOOKUP][PIPELINE] Spawned pipeline for #{domain}")
        row = LS.Pipeline.run(domain, insert: true)
        Logger.info("[LOOKUP][PIPELINE] Pipeline complete for #{domain} — tech:#{row[:http_tech] || "none"}")

        # Cache the row in ETS
        cache_row = row_map_to_list(row)
        try do
          :ets.insert(@cache_table, {domain, cache_row, System.monotonic_time(:second)})
          Logger.debug("[LOOKUP] #{domain} — cached in ETS")
        catch _, _ -> :ok
        end

        {:ok, row_to_response(row, domain, true)}
      rescue
        e ->
          Logger.error("[LOOKUP][PIPELINE] #{domain} — EXCEPTION: #{Exception.message(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}")
          {:error, "Pipeline error: #{Exception.message(e)}"}
      catch
        kind, reason ->
          Logger.error("[LOOKUP][PIPELINE] #{domain} — #{kind}: #{inspect(reason)}")
          {:error, "#{kind}: #{inspect(reason)}"}
      end

      exit({:lookup_result, result})
    end)

    receive do
      {:DOWN, ^monitor_ref, :process, ^pid, {:lookup_result, result}} ->
        case result do
          {:ok, data} -> Logger.info("[LOOKUP] #{domain} — SUCCESS (#{length(data.tech)} techs, shopify:#{data[:is_shopify]})")
          {:error, reason} -> Logger.warning("[LOOKUP] #{domain} — FAILED: #{reason}")
        end
        result
      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        Logger.error("[LOOKUP] #{domain} — process crashed: #{inspect(reason)}")
        {:error, "Lookup process crashed: #{inspect(reason)}"}
    after
      @timeout ->
        Logger.error("[LOOKUP] #{domain} — TIMEOUT after #{div(@timeout, 1000)}s, killing process")
        Process.exit(pid, :kill)
        receive do
          {:DOWN, ^monitor_ref, :process, ^pid, _} -> :ok
        after 200 -> :ok
        end
        {:error, "Lookup timed out after #{div(@timeout, 1000)}s"}
    end
  end

  # Convert row map to list in column order (for ETS cache)
  defp row_map_to_list(r) do
    Enum.map(LS.Cluster.Inserter.columns(), fn col -> r[col] end)
  end

  # Convert column-ordered list (from ClickHouse SELECT * or ETS) to response map
  defp parse_row(row, domain) when is_list(row) do
    col_idx = LS.Cluster.Inserter.columns() |> Enum.with_index() |> Map.new()
    at = fn key -> Enum.at(row, Map.get(col_idx, key, -1)) end
    row_to_response(at, domain, false)
  end

  # Shared response builder — works with both map access (fresh) and index fn (cached)
  defp row_to_response(row, domain, fresh) when is_map(row) do
    row_to_response(fn key -> row[key] end, domain, fresh)
  end
  defp row_to_response(at, domain, fresh) when is_function(at) do
    tech = (at.(:http_tech) || "") |> String.split("|") |> Enum.reject(&(&1 == ""))
    is_shopify = Enum.any?(tech, &(String.downcase(&1) |> String.contains?("shopify")))
    %{
      domain: domain,
      title: at.(:http_title) || domain,
      tech: tech,
      status: at.(:http_status),
      country: LS.CountryInferrer.infer(
        at.(:ctl_tld),
        at.(:http_language),
        nil,
        at.(:bgp_asn_country)
      ),
      is_shopify: is_shopify,
      business_model: at.(:business_model) || "",
      industry: at.(:industry) || "",
      fresh: fresh,
      estimated_revenue: at.(:estimated_revenue) || "",
      estimated_employees: at.(:estimated_employees) || "",
      revenue_confidence: at.(:revenue_confidence),
      revenue_evidence: at.(:revenue_evidence) || ""
    }
  end
end
