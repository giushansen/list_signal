defmodule LS.DataCheck do
  @moduledoc """
  The data triple-check behind the alert email: quality, quantity, speed.

  Requested 2026-08-28. The infra alerts say whether machines are up; this
  says whether the DATA is right, which the machines cannot know:

  * **Quality**: the shape of the last hour's rows against the prior 24 hours.
    A column that is normally 85% filled and suddenly 40% filled means a
    parser broke or an upstream changed, even though every service is green.
    The h1 incident wrote 45M hollow rows over 3.1M enriched domains while
    every process reported healthy: this check exists so that class of
    failure emails within the hour.
  * **Quantity**: rows per hour into each pipeline's main table against its
    own trailing average. Catches a stalled lane whose process is still alive.
  * **Speed**: canonical queries timed live. Catches table degradation
    (unmerged parts, lost index, growth past a threshold) before users do.

  The baseline is SELF-CALIBRATING: last hour versus the prior 24h from the
  same table, so thresholds move with the product instead of rotting like
  hardcoded numbers. Bands are pure functions, pinned by tests.

  Snapshots are cached for ~55 minutes in `:persistent_term`: the alert tick
  runs every 15 minutes, but scanning 24h of domains_current more than hourly
  would cost real ClickHouse budget for no fresher answer.
  """

  alias LS.Clickhouse
  require Logger

  @cache_key {__MODULE__, :snapshot}
  @cache_ttl_ms 55 * 60_000
  # Below this many rows in the last hour, quality percentages are noise, and
  # the QUANTITY check is what will fire anyway.
  @min_sample 1_000

  # Fill-rate quality metrics: {label, SQL condition}. Higher is better.
  @fill_metrics [
    {"title on 200s", "http_title != ''", "http_status BETWEEN 200 AND 399"},
    {"country", "inferred_country != ''", "1"},
    {"tech on 200s", "http_tech != ''", "http_status BETWEEN 200 AND 399"},
    {"MX records", "dns_mx != ''", "1"},
    {"BGP org", "bgp_asn_org != ''", "1"}
  ]

  # Error-rate quality metrics. Lower is better.
  @error_metrics [
    {"HTTP errors", "http_error != ''"},
    {"HTTP 5xx", "http_status >= 500"},
    {"junk detected", "is_junk != ''"}
  ]

  # Quantity streams: {label, table, time column}.
  @streams [
    {"discovery rows", "domains_current", "enriched_at"},
    {"new businesses", "businesses", "first_seen"},
    {"enrichment rows", "biz_enrichment", "enriched_at"}
  ]

  # Speed probes: {label, sql, warn_ms, error_ms}. Thresholds are absolute:
  # these numbers are what a USER experiences, so they must not drift with a
  # degrading baseline the way the quality bands are allowed to.
  @speed_probes [
    {"domain point lookup", "SELECT domain FROM domains_current FINAL WHERE domain = 'google.com' LIMIT 1", 500, 2_500},
    {"shopify filter count", "SELECT count() FROM businesses WHERE is_shopify = 1", 1_000, 4_000},
    {"signal history lookup", "SELECT count() FROM biz_signal WHERE domain = 'google.com'", 500, 2_500}
  ]

  # ── snapshot (cached) ──────────────────────────────────────────────────

  @doc "The current data-health snapshot, at most ~1h old. Never raises."
  def snapshot do
    case :persistent_term.get(@cache_key, nil) do
      {ts, snap} ->
        if System.monotonic_time(:millisecond) - ts < @cache_ttl_ms, do: snap, else: refresh()

      _ ->
        refresh()
    end
  end

  defp refresh do
    snap = %{quality: quality(), quantity: quantity(), speed: speed(), at: DateTime.utc_now()}
    :persistent_term.put(@cache_key, {System.monotonic_time(:millisecond), snap})
    snap
  rescue
    e ->
      Logger.warning("[DATACHECK] refresh failed: #{Exception.message(e)}")
      %{quality: [], quantity: [], speed: [], at: DateTime.utc_now()}
  end

  # ── gather: quality ────────────────────────────────────────────────────

  defp quality do
    fills =
      Enum.map_join(@fill_metrics, ",\n", fn {_, cond_sql, base_sql} ->
        "round(countIf((#{cond_sql}) AND (#{base_sql}) AND recent)/greatest(countIf((#{base_sql}) AND recent),1)*100,1)," <>
          "round(countIf((#{cond_sql}) AND (#{base_sql}) AND NOT recent)/greatest(countIf((#{base_sql}) AND NOT recent),1)*100,1)"
      end)

    errs =
      Enum.map_join(@error_metrics, ",\n", fn {_, cond_sql} ->
        "round(countIf((#{cond_sql}) AND recent)/greatest(countIf(recent),1)*100,1)," <>
          "round(countIf((#{cond_sql}) AND NOT recent)/greatest(countIf(NOT recent),1)*100,1)"
      end)

    sql = """
    SELECT countIf(recent), #{fills}, #{errs}
    FROM (SELECT *, enriched_at >= now() - INTERVAL 1 HOUR AS recent
          FROM domains_current WHERE enriched_at >= now() - INTERVAL 25 HOUR)
    """

    case Clickhouse.query_raw(sql, 60_000, background: true) do
      {:ok, [[sample | pairs]]} ->
        sample = to_num(sample)

        metrics =
          (Enum.map(@fill_metrics, fn {label, _, _} -> {label, :fill} end) ++
             Enum.map(@error_metrics, fn {label, _} -> {label, :error} end))

        pairs
        |> Enum.map(&to_num/1)
        |> Enum.chunk_every(2)
        |> Enum.zip(metrics)
        |> Enum.map(fn {[recent, base], {label, kind}} ->
          %{label: label, kind: kind, recent: recent, base: base,
            band: quality_band(kind, recent, base, sample)}
        end)

      _ ->
        []
    end
  end

  # ── gather: quantity ───────────────────────────────────────────────────

  defp quantity do
    Enum.map(@streams, fn {label, table, col} ->
      sql = """
      SELECT countIf(#{col} >= now() - INTERVAL 1 HOUR),
             round(countIf(#{col} < now() - INTERVAL 1 HOUR) / 24.0)
      FROM #{table} WHERE #{col} >= now() - INTERVAL 25 HOUR
      """

      case Clickhouse.query_raw(sql, 60_000, background: true) do
        {:ok, [[recent, base]]} ->
          r = to_num(recent)
          b = to_num(base)
          %{label: label, recent: r, base: b, band: quantity_band(r, b)}

        _ ->
          %{label: label, recent: nil, base: nil, band: :ok}
      end
    end)
  end

  # ── gather: speed ──────────────────────────────────────────────────────

  defp speed do
    Enum.map(@speed_probes, fn {label, sql, warn, err} ->
      {us, res} = :timer.tc(fn -> Clickhouse.query_raw(sql, 10_000) end)
      ms = div(us, 1_000)

      band =
        case res do
          {:ok, _} -> speed_band(ms, warn, err)
          _ -> :error
        end

      %{label: label, ms: ms, warn: warn, error: err, band: band}
    end)
  end

  # ── pure bands ─────────────────────────────────────────────────────────

  @doc """
  Quality band: last-hour percentage against the trailing-24h baseline.

  Fill metrics (higher is better) warn 10 points under baseline and go
  critical 25 under; error metrics mirror that upward. Points, not ratios: a
  fill falling 60% to 50% and 20% to 10% are equally alarming, where a ratio
  would shrug at the first and scream at the second. Small samples are :ok by
  fiat, because the quantity check owns "almost no rows arrived".
  """
  def quality_band(_kind, _recent, _base, sample) when sample < @min_sample, do: :ok
  def quality_band(:fill, recent, base, _) when recent < base - 25, do: :error
  def quality_band(:fill, recent, base, _) when recent < base - 10, do: :warn
  def quality_band(:error, recent, base, _) when recent > base + 25, do: :error
  def quality_band(:error, recent, base, _) when recent > base + 10, do: :warn
  def quality_band(_, _, _, _), do: :ok

  @doc """
  Quantity band from the recent/baseline ratio. Half-to-double is normal (the
  CT diurnal cycle alone swings that much); a quarter or 4x is a warning;
  under a tenth, or a dead-silent hour against a live baseline, is critical.
  """
  def quantity_band(recent, base)
  def quantity_band(_recent, base) when base < 50, do: :ok
  def quantity_band(recent, base) when recent < base / 10, do: :error
  def quantity_band(recent, base) when recent < base / 4, do: :warn
  def quantity_band(recent, base) when recent > base * 4, do: :warn
  def quantity_band(_, _), do: :ok

  @doc "Speed band against absolute per-query thresholds."
  def speed_band(ms, _warn, err) when ms >= err, do: :error
  def speed_band(ms, warn, _err) when ms >= warn, do: :warn
  def speed_band(_, _, _), do: :ok

  # ── alerts (consumed by LS.Alerts.evaluate/1) ──────────────────────────

  @doc "Alert structs for every non-ok metric, in LS.Alerts's shape."
  def alerts(%{quality: q, quantity: n, speed: s}) do
    quality_alerts(q) ++ quantity_alerts(n) ++ speed_alerts(s)
  end

  def alerts(_), do: []

  defp quality_alerts(metrics) do
    for %{band: band} = m <- metrics, band != :ok do
      dir = if m.kind == :fill, do: "down to", else: "up to"

      %{severity: sev(band), key: "data_quality:#{m.label}",
        subject: "Data quality: #{m.label}",
        line: "#{m.label} #{dir} #{m.recent}% this hour against a 24h norm of #{m.base}%. " <>
          "A shape change like this is a parser or upstream break, not load."}
    end
  end

  defp quantity_alerts(streams) do
    for %{band: band} = m <- streams, band != :ok do
      %{severity: sev(band), key: "data_quantity:#{m.label}",
        subject: "Ingestion rate: #{m.label}",
        line: "#{m.label}: #{m.recent} rows this hour against a 24h hourly norm of #{m.base} (#{pct_of(m.recent, m.base)}%)."}
    end
  end

  defp speed_alerts(probes) do
    for %{band: band} = m <- probes, band != :ok do
      %{severity: sev(band), key: "data_speed:#{m.label}",
        subject: "Query speed: #{m.label}",
        line: "#{m.label} took #{m.ms}ms (warn at #{m.warn}, critical at #{m.error}). " <>
          "The table may need an OPTIMIZE, an index or a restructure."}
    end
  end

  defp sev(:error), do: :critical
  defp sev(_), do: :warning

  # ── email section ──────────────────────────────────────────────────────

  @doc """
  The color-coded data-health section appended to the bottom of every alert
  email, and sent alone on a quiet Monday. Green is the measured normal band,
  amber a drift, red a break, always with the percentages beside the color so
  the number survives a client that strips styles.
  """
  def html_section(%{quality: q, quantity: n, speed: s}) do
    rows =
      Enum.map_join(q, "", fn m ->
        row(m.band, m.label, "#{m.recent}%", "norm #{m.base}%")
      end) <>
        Enum.map_join(n, "", fn m ->
          row(m.band, m.label, "#{m.recent || "?"}/h", "norm #{m.base || "?"}/h (#{pct_of(m.recent, m.base)}%)")
        end) <>
        Enum.map_join(s, "", fn m ->
          row(m.band, m.label, "#{m.ms}ms", "warn #{m.warn}ms / crit #{m.error}ms")
        end)

    """
    <h3 style="margin:24px 0 4px;font-size:15px">Data health</h3>
    <p style="color:#666;margin:0 0 8px;font-size:12px">Last hour against its own trailing 24h. Quality, quantity, speed.</p>
    <table style="border-collapse:collapse;width:100%;font-size:13px">#{rows}</table>
    """
  end

  def html_section(_), do: ""

  defp row(band, label, value, norm) do
    {dot, color} =
      case band do
        :ok -> {"🟢", "#16a34a"}
        :warn -> {"🟡", "#d97706"}
        :error -> {"🔴", "#dc2626"}
      end

    "<tr><td style=\"padding:5px 8px;border-bottom:1px solid #f0f0f0\">#{dot}</td>" <>
      "<td style=\"padding:5px 8px;border-bottom:1px solid #f0f0f0\">#{label}</td>" <>
      "<td style=\"padding:5px 8px;border-bottom:1px solid #f0f0f0;text-align:right\"><b style=\"color:#{color}\">#{value}</b></td>" <>
      "<td style=\"padding:5px 8px;border-bottom:1px solid #f0f0f0;color:#888\">#{norm}</td></tr>"
  end

  defp pct_of(recent, base) when is_number(recent) and is_number(base) and base > 0,
    do: round(recent / base * 100)

  defp pct_of(_, _), do: "?"

  defp to_num(v) when is_number(v), do: v
  defp to_num(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> 0
    end
  end

  defp to_num(_), do: 0
end
