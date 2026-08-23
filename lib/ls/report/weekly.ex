defmodule LS.Report.Weekly do
  @moduledoc """
  The Monday-morning email: one HTML page, three chapters, built entirely from
  `LS.Metrics` so it can never disagree with the dashboard or the alerts.

    1. Infrastructure — CPU / RAM / disk / network per node, in a table.
    2. Traffic — crawl outcome & error rates, ingestion trend, and the bytes
       every download (verification archives, reputation lists) pulled.
    3. Software — pipeline throughput & efficiency, crawl yield by domain kind,
       and data quality (classification, junk, verified coverage).

  `deliver/0` renders and emails it; `html/0` just renders (used by the test and
  handy from an IEx session). Kept deliberately flat — small private helpers
  build every table so a solo maintainer can read the whole thing top to bottom.
  """

  require Logger
  alias LS.Metrics

  @doc "Render and email the weekly report. Returns `:ok` / `{:error, _}`."
  def deliver do
    subject = "ListSignal weekly · #{Date.utc_today()}"
    LS.Ops.Mail.send(subject, html())
  end

  @doc "Render the report HTML (no send)."
  def html do
    res = node_rates()
    tc = Metrics.table_counts()
    daily = Metrics.daily_ingestion(8)
    enrich = Metrics.daily_enrichment(8)
    crawl = Metrics.crawl_outcomes(24 * 7)
    vdl = Metrics.verification_downloads()
    models = Metrics.by_model()
    clazz = Metrics.classification()
    est = Metrics.estimation()

    """
    <div style="font-family:-apple-system,Segoe UI,Helvetica,Arial,sans-serif;color:#1a2230;max-width:760px;margin:auto">
      #{header(tc)}
      #{chapter("1 · Infrastructure", infra_table(res))}
      #{chapter("2 · Traffic, errors &amp; downloads", crawl_block(crawl) <> ingestion_table(daily, enrich) <> downloads_table(vdl))}
      #{chapter("3 · Software — pipelines &amp; data quality", pipelines_block(tc, daily, enrich) <> quality_block(clazz, est, tc) <> models_table(models))}
      <p style="color:#9aa4b2;font-size:12px;margin-top:28px">Generated #{now()} UTC · reply to this email or open /admin for live detail.</p>
    </div>
    """
  end

  # ── header ──

  defp header(tc) do
    """
    <h1 style="margin:0 0 2px;font-size:22px">ListSignal — weekly report</h1>
    <p style="color:#667085;margin:0 0 20px">Week of #{Date.utc_today()} · #{fmt(tc.businesses)} businesses · #{fmt(tc.domains_current)} domains tracked</p>
    """
  end

  defp chapter(title, body) do
    """
    <h2 style="font-size:16px;margin:26px 0 10px;padding-bottom:6px;border-bottom:2px solid #eef0f4">#{title}</h2>
    #{body}
    """
  end

  # ── ch.1 infrastructure ──

  defp infra_table(nodes) do
    rows =
      Enum.map(nodes, fn {node, r, rx, tx} ->
        [
          short(node),
          r[:cores] || "—",
          fnum(r[:load1]),
          ram(r),
          disk(r),
          rate(rx),
          rate(tx),
          mb(r[:beam_mb])
        ]
      end)

    table(["node", "cores", "load 1m", "RAM", "disk", "net ↓/s", "net ↑/s", "BEAM"], rows)
  end

  defp ram(r) do
    cond do
      is_integer(r[:mem_avail_mb]) and is_integer(r[:mem_total_mb]) ->
        hot = r[:mem_used_pct] && r.mem_used_pct >= 85
        color(hot, "#{r.mem_used_pct}% · #{gb(r.mem_avail_mb)}G free")

      true -> "—"
    end
  end

  defp disk(r) do
    if is_integer(r[:disk_used_pct]) do
      color(r.disk_used_pct >= 85, "#{r.disk_used_pct}% · #{r[:disk_used_gb]}/#{r[:disk_total_gb]}G")
    else
      "—"
    end
  end

  # ── ch.2 traffic ──

  defp crawl_block(c) do
    t = max(c.total, 1)
    pct = fn n -> "#{Float.round(100 * n / t, 1)}%" end
    """
    <p style="margin:0 0 10px">Crawled <b>#{fmt(c.total)}</b> domain-fetches in 7 days:
      <span style="color:#059669">#{pct.(c.ok)} HTTP-OK</span> ·
      <span style="color:#d97706">#{pct.(c.blocked)} blocked</span> ·
      <span style="color:#dc2626">#{pct.(c.failed)} failed</span> ·
      <span style="color:#667085">#{pct.(c.no_dns)} no-DNS</span>.</p>
    """
  end

  defp ingestion_table(daily, enrich) do
    em = Map.new(enrich, &{&1.day, &1.rows})
    rows = Enum.map(daily, fn d -> [d.day, fmt(d.rows), fmt(Map.get(em, d.day, 0))] end)
    table(["day", "domains crawled", "deep-enriched"], rows)
  end

  defp downloads_table(vdl) do
    if vdl == [] do
      "<p style=\"color:#667085\">No verification downloads recorded yet.</p>"
    else
      rows =
        Enum.map(vdl, fn v ->
          [v.source, fmt(v.records), fmt(v.matched), bytes(v.bytes), fmt_ts(v.last_run)]
        end)

      "<p style=\"margin:14px 0 6px;font-weight:600\">Authoritative-source downloads (pipeline 3)</p>" <>
        table(["source", "records", "linked", "downloaded", "last run"], rows)
    end
  end

  # ── ch.3 software ──

  defp pipelines_block(tc, daily, enrich) do
    avg_d = avg(Enum.map(daily, & &1.rows))
    avg_e = avg(Enum.map(enrich, & &1.rows))
    stale = Metrics.businesses_stale_seconds()
    yield = Metrics.real_business_yield(7)

    """
    <ul style="margin:0 0 8px;padding-left:18px;line-height:1.7">
      <li><b>Discovery</b> — #{fmt(round(avg_d))} domains/day avg into #{fmt(tc.domains_history)} history rows.</li>
      <li><b>Enrichment</b> — #{fmt(round(avg_e))} deep crawls/day.</li>
      <li><b>Compaction</b> — product table #{if stale < 3600, do: "fresh (#{div(stale, 60)} min)", else: "<span style='color:#dc2626'>#{div(stale, 60)} min stale</span>"}.</li>
      <li><b>Sellable yield</b> — #{fmt(yield)} domains gained MX + a business model this week.</li>
    </ul>
    """
  end

  defp quality_block(clazz, est, tc) do
    b = max(tc.businesses, 1)
    p = fn n -> "#{Float.round(100 * n / b, 1)}%" end
    """
    <ul style="margin:0 0 8px;padding-left:18px;line-height:1.7">
      <li><b>Classified</b> — #{clazz.classified_pct}% of businesses have a model; junk flagged #{clazz.junk_pct}%.</li>
      <li><b>Revenue estimated</b> — #{p.(est.estimated_revenue)} of businesses.</li>
      <li><b>Verified facts</b> — #{fmt(est.verified_revenue)} revenue + #{fmt(est.verified_employees)} employees from authoritative sources.</li>
    </ul>
    """
  end

  defp models_table(models) do
    total = models |> Enum.map(& &1.count) |> Enum.sum() |> max(1)
    rows =
      models
      |> Enum.take(12)
      |> Enum.map(fn m -> [m.model, fmt(m.count), "#{Float.round(100 * m.count / total, 1)}%"] end)

    "<p style=\"margin:14px 0 6px;font-weight:600\">Crawl yield by domain kind</p>" <>
      table(["business model", "count", "share"], rows)
  end

  # ── node rates: two resource reads a few seconds apart → network throughput ──

  defp node_rates do
    a = Map.new(Metrics.node_resources())
    Process.sleep(4_000)
    b = Metrics.node_resources()

    Enum.map(b, fn {node, r2} ->
      r1 = Map.get(a, node)
      {rx, tx} = deltas(r1, r2)
      {node, r2, rx, tx}
    end)
  end

  defp deltas(%{net_rx_bytes: rx1, net_tx_bytes: tx1}, %{net_rx_bytes: rx2, net_tx_bytes: tx2})
       when is_integer(rx1) and is_integer(rx2),
       do: {max(rx2 - rx1, 0) / 4, max(tx2 - tx1, 0) / 4}

  defp deltas(_, _), do: {nil, nil}

  # ── html + number helpers (email-safe inline styles) ──

  defp table(headers, rows) do
    th = Enum.map_join(headers, "", &"<th style=\"text-align:left;padding:6px 10px;background:#f7f8fa;border-bottom:1px solid #e6e8ec;font-size:12px;color:#667085\">#{&1}</th>")
    trs =
      Enum.map_join(rows, "", fn cells ->
        tds = Enum.map_join(cells, "", &"<td style=\"padding:6px 10px;border-bottom:1px solid #f0f1f4;font-size:13px\">#{&1}</td>")
        "<tr>#{tds}</tr>"
      end)

    "<table style=\"border-collapse:collapse;width:100%;margin:4px 0 8px\"><thead><tr>#{th}</tr></thead><tbody>#{trs}</tbody></table>"
  end

  defp color(true, s), do: "<span style=\"color:#dc2626;font-weight:600\">#{s}</span>"
  defp color(_, s), do: s

  defp short(node), do: node |> to_string() |> String.split("@") |> hd() |> String.replace("worker_", "")
  defp avg([]), do: 0
  defp avg(list), do: Enum.sum(list) / length(list)
  defp gb(mb) when is_integer(mb), do: Float.round(mb / 1024, 1)
  defp gb(_), do: "—"
  defp mb(nil), do: "—"
  defp mb(v), do: "#{v}MB"
  defp fnum(nil), do: "—"
  defp fnum(v) when is_float(v), do: :erlang.float_to_binary(v, decimals: 2)
  defp fnum(v), do: "#{v}"
  defp rate(nil), do: "—"
  defp rate(bps), do: bytes(round(bps)) <> "/s"
  defp bytes(n) when is_integer(n) and n >= 1_073_741_824, do: "#{Float.round(n / 1_073_741_824, 1)}GB"
  defp bytes(n) when is_integer(n) and n >= 1_048_576, do: "#{Float.round(n / 1_048_576, 1)}MB"
  defp bytes(n) when is_integer(n) and n >= 1024, do: "#{Float.round(n / 1024, 1)}KB"
  defp bytes(n) when is_integer(n), do: "#{n}B"
  defp bytes(_), do: "—"
  defp fmt(n) when is_integer(n) and n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp fmt(n) when is_integer(n) and n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp fmt(n), do: "#{n}"
  defp fmt_ts(s) when is_binary(s) and byte_size(s) >= 10, do: String.slice(s, 0, 10)
  defp fmt_ts(_), do: "—"
  defp now, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_string()
end
