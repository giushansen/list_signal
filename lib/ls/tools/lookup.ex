defmodule LS.Tools.Lookup do
  @moduledoc """
  On-demand single-domain enrichment for web tools.
  Runs LS.Pipeline in a monitored subprocess with timeout.
  """
  require Logger
  @timeout 30_000
  @cache_table :lookup_result_cache

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
        if fresh_today?(enriched_at) do
          {:ok, parse_row(row, domain)}
        else
          Logger.debug("[LOOKUP] #{domain} — ClickHouse data stale (#{enriched_at})")
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

  defp fresh_today?(nil), do: false
  defp fresh_today?(ts) when is_binary(ts) do
    case Date.from_iso8601(String.slice(ts, 0, 10)) do
      {:ok, date} -> date == Date.utc_today()
      _ -> false
    end
  end
  defp fresh_today?(_), do: false

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

        tech = (row[:http_tech] || "") |> String.split("|") |> Enum.reject(&(&1 == ""))
        is_shopify = Enum.any?(tech, &(String.downcase(&1) |> String.contains?("shopify")))

        {:ok, %{
          domain: domain,
          title: row[:http_title] || domain,
          tech: tech,
          status: row[:http_status],
          country: row[:bgp_asn_country] || "",
          is_shopify: is_shopify,
          fresh: true
        }}
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

  defp row_map_to_list(r) do
    [
      r[:enriched_at], r[:worker], r[:domain],
      r[:ctl_tld], r[:ctl_issuer], r[:ctl_subdomain_count], r[:ctl_subdomains],
      r[:dns_a], r[:dns_aaaa], r[:dns_mx], r[:dns_txt], r[:dns_cname],
      r[:http_status], r[:http_response_time], r[:http_blocked], r[:http_content_type],
      r[:http_tech], r[:http_apps] || "", r[:http_language] || "",
      r[:http_title], r[:http_meta_description], r[:http_pages], r[:http_emails], r[:http_error],
      r[:bgp_ip], r[:bgp_asn_number], r[:bgp_asn_org], r[:bgp_asn_country], r[:bgp_asn_prefix],
      r[:rdap_domain_created_at], r[:rdap_domain_expires_at], r[:rdap_domain_updated_at],
      r[:rdap_registrar], r[:rdap_registrar_iana_id], r[:rdap_nameservers],
      r[:rdap_status], r[:rdap_error],
      r[:tranco_rank], r[:majestic_rank], r[:majestic_ref_subnets],
      r[:is_malware], r[:is_phishing], r[:is_disposable_email]
    ]
  end

  defp parse_row(row, domain) do
    tech = (Enum.at(row, 16) || "") |> String.split("|") |> Enum.reject(&(&1 == ""))
    is_shopify = Enum.any?(tech, &(String.downcase(&1) |> String.contains?("shopify")))
    %{
      domain: domain,
      title: Enum.at(row, 19) || domain,
      tech: tech,
      status: Enum.at(row, 12),
      country: Enum.at(row, 27) || "",
      is_shopify: is_shopify,
      fresh: false
    }
  end
end
