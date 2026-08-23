defmodule LS.Alerts do
  @moduledoc """
  Emails the operator when something that hurts the business is wrong.

  Two halves, kept apart so the judgement is testable without a cluster:

    * `evaluate/1` — PURE. Takes one gathered metrics map (see `gather/0`) and
      returns the list of firing alerts. Every threshold lives here, chosen
      from measured prod baselines (see `LS.Metrics`) with wide margins so a
      normal daily dip never pages anyone.
    * `run/0` — gathers metrics, evaluates, drops any alert still inside its
      per-key COOLDOWN (so a condition that persists for a day is one email,
      not ninety-six), and sends ONE digest email for whatever remains.

  The whole point is to be quiet: silence means healthy, an email means act.
  Cooldowns and the weekly-report dedup share `ls.ops_email_log` (migration
  013) so a master restart cannot re-page or double-send.
  """

  require Logger
  alias LS.{Metrics, Clickhouse}

  # Thresholds (measured 2026-08-23). Wide margins on purpose.
  @ingestion_3h_floor 150_000        # normal ~500-800k/3h
  @worker_6h_floor 20_000            # normal ~170-230k/6h; below this a node is effectively dead
  @resolved_fail_ceiling 30.0        # normal 5-9%; ~100% is the h1 split-brain
  @stale_seconds_ceiling 5_400       # businesses should be < ~90 min old (compactor)
  @disk_pct_ceiling 88               # 240G disk-full caused a 521 outage before
  @mem_avail_mb_floor 900            # master beam is capped ~8G on a 16G box
  @queue_pct_ceiling 92.0
  @reputation_age_ceiling_h 50       # 24h/12h download loops; >2 days = downloads failing
  @verification_running_ceiling_h 8  # a source stuck 'running' this long is wedged
  @cooldown_hours 6

  @doc "Gather everything `evaluate/1` needs. Master-only; each field is independently safe."
  def gather do
    %{
      ingestion_3h: Metrics.ingestion(3),
      per_worker: Metrics.per_worker(6),
      known_workers: Metrics.known_workers(3),
      stale_seconds: Metrics.businesses_stale_seconds(),
      worker_health: Metrics.worker_health(),
      queue: Metrics.queue(),
      node_resources: Metrics.node_resources(),
      reputation_ages: Metrics.reputation_ages(),
      verification: Metrics.verification(),
      poller: Metrics.poller(),
      ctl_diff: LS.CTL.LogList.diff_current()
    }
  end

  @doc "Pure: metrics map → firing alerts, most severe first."
  @spec evaluate(map()) :: [%{key: String.t(), severity: :critical | :warning, subject: String.t(), line: String.t()}]
  def evaluate(m) do
    []
    |> ingestion(m)
    |> workers_dead(m)
    |> workers_quality(m)
    |> workers_quarantined(m)
    |> compaction(m)
    |> resources(m)
    |> queue(m)
    |> reputation(m)
    |> verification(m)
    |> ctl_sources(m)
    |> Enum.sort_by(&(&1.severity == :critical), :desc)
  end

  # ── checks (each prepends firing alerts) ──

  defp ingestion(acc, %{ingestion_3h: n}) when is_integer(n) and n < @ingestion_3h_floor,
    do: [al(:critical, "ingestion_low", "Ingestion stalled", "only #{fmt(n)} domains crawled in the last 3h (floor #{fmt(@ingestion_3h_floor)})") | acc]

  defp ingestion(acc, _), do: acc

  defp workers_dead(acc, %{known_workers: known, per_worker: pw}) do
    live = Map.new(pw, &{&1.worker, &1.rows})

    Enum.reduce(known, acc, fn w, a ->
      rows = Map.get(live, w, 0)
      if rows < @worker_6h_floor,
        do: [al(:critical, "worker_dead:#{w}", "Worker down: #{short(w)}", "#{short(w)} produced #{fmt(rows)} rows in 6h (floor #{fmt(@worker_6h_floor)})") | a],
        else: a
    end)
  end

  defp workers_quality(acc, %{per_worker: pw}) do
    Enum.reduce(pw, acc, fn w, a ->
      if w.rows > 5_000 and w.resolved_fail_pct > @resolved_fail_ceiling,
        do: [al(:critical, "worker_quality:#{w.worker}", "Worker degraded: #{short(w.worker)}", "#{short(w.worker)} resolves DNS but #{w.resolved_fail_pct}% of those fail HTTP (split-brain resolver?)") | a],
        else: a
    end)
  end

  defp workers_quarantined(acc, %{worker_health: wh}) do
    q = for {w, h} <- wh, Map.get(h, :quarantined), do: w

    if q == [],
      do: acc,
      else: [al(:critical, "quarantined", "Worker(s) quarantined", "#{Enum.join(Enum.map(q, &short/1), ", ")} — hollow rows being dropped; fix then Inserter.release_worker/1") | acc]
  end

  defp compaction(acc, %{stale_seconds: s}) when is_integer(s) and s > @stale_seconds_ceiling,
    do: [al(:critical, "compaction_stale", "Product table stale", "businesses last updated #{div(s, 60)} min ago — compactor may be failing") | acc]

  defp compaction(acc, _), do: acc

  defp resources(acc, %{node_resources: nodes}) do
    Enum.reduce(nodes, acc, fn {node, r}, a ->
      a
      |> then(fn a ->
        if is_integer(r[:disk_used_pct]) and r.disk_used_pct >= @disk_pct_ceiling,
          do: [al(:critical, "disk:#{node}", "Disk almost full: #{short(node)}", "#{short(node)} disk #{r.disk_used_pct}% used (#{r[:disk_used_gb]}/#{r[:disk_total_gb]}GB)") | a],
          else: a
      end)
      |> then(fn a ->
        if is_integer(r[:mem_avail_mb]) and r.mem_avail_mb < @mem_avail_mb_floor,
          do: [al(:warning, "mem:#{node}", "Low memory: #{short(node)}", "#{short(node)} only #{r.mem_avail_mb}MB RAM available") | a],
          else: a
      end)
    end)
  end

  defp queue(acc, %{queue: %{queue_pct: p}}) when is_number(p) and p > @queue_pct_ceiling,
    do: [al(:warning, "queue_full", "Work queue near cap", "queue at #{p}% — discovery inflow being shed; add workers") | acc]

  defp queue(acc, _), do: acc

  defp reputation(acc, %{reputation_ages: ages}) do
    for {name, age} <- ages, is_integer(age) and age > @reputation_age_ceiling_h, reduce: acc do
      a -> [al(:warning, "reputation:#{name}", "#{name} download stale", "#{name} data is #{age}h old — download loop may be failing") | a]
    end
  end

  defp verification(acc, %{verification: %{sources: sources, scheduler: sched}}) when is_list(sources) do
    running = sched && Map.get(sched, :running)

    Enum.reduce(sources, acc, fn s, a ->
      cond do
        running && to_string(running) == s.source && s.duration_s == 0 && stale_run?(s) ->
          [al(:warning, "verify_stuck:#{s.source}", "Verification wedged: #{s.source}", "#{s.source} has been running > #{@verification_running_ceiling_h}h") | a]

        s.status == "error" ->
          [al(:warning, "verify_error:#{s.source}", "Verification failed: #{s.source}", "last #{s.source} run errored: #{String.slice(s.error || "", 0, 100)}") | a]

        true -> a
      end
    end)
  end

  defp verification(acc, _), do: acc

  defp ctl_sources(acc, %{ctl_diff: %{new: new, retired: retired}}) do
    acc
    |> then(fn a ->
      if new == [], do: a, else: [al(:warning, "ctl_new:#{keyify(new)}", "New CT log source(s) available", "Chrome lists usable CT logs we don't poll: #{Enum.join(new, ", ")}. Add to LS.CTL.Poller @log_configs.") | a]
    end)
    |> then(fn a ->
      if retired == [], do: a, else: [al(:warning, "ctl_retired:#{keyify(retired)}", "CT log source(s) retiring", "logs we poll are no longer usable in Chrome's list: #{Enum.join(retired, ", ")}. They will stop yielding certs.") | a]
    end)
  end

  defp ctl_sources(acc, _), do: acc

  # ── run: gather → evaluate → cooldown → one email ──

  @doc "Evaluate now, send a digest for any alert past its cooldown. Returns the alerts sent."
  def run do
    alerts = evaluate(gather())
    fresh = Enum.reject(alerts, &cooling_down?/1)

    if fresh != [] do
      subject = digest_subject(fresh)
      case LS.Ops.Mail.send(subject, digest_html(fresh)) do
        :ok -> Enum.each(fresh, &record_sent/1)
        _ -> :noop
      end
    end

    fresh
  end

  # ── cooldown via ops_email_log ──

  defp cooling_down?(%{key: key}) do
    case Clickhouse.query_raw("SELECT max(sent_at) FROM ops_email_log WHERE key = '#{Clickhouse.escape_public(key)}' AND sent_at > now() - INTERVAL #{@cooldown_hours} HOUR", 5_000) do
      {:ok, [[t]]} when is_binary(t) and t not in ["", "1970-01-01 00:00:00"] -> true
      _ -> false
    end
  end

  defp record_sent(%{key: key, subject: subject}) do
    body = Jason.encode!(%{key: key, sent_at: now_str(), subject: String.slice(subject, 0, 200)})
    Clickhouse.insert_raw("INSERT INTO ops_email_log FORMAT JSONEachRow", body)
  end

  # ── formatting ──

  defp digest_subject([%{severity: :critical} | _] = a), do: "🔴 ListSignal alert: #{hd(a).subject}" <> more(a)
  defp digest_subject(a), do: "🟡 ListSignal alert: #{hd(a).subject}" <> more(a)
  defp more([_]), do: ""
  defp more(a), do: " (+#{length(a) - 1} more)"

  defp digest_html(alerts) do
    rows =
      Enum.map_join(alerts, "", fn a ->
        color = if a.severity == :critical, do: "#dc2626", else: "#d97706"
        dot = if a.severity == :critical, do: "🔴", else: "🟡"
        "<tr><td style=\"padding:8px 12px;border-bottom:1px solid #eee;vertical-align:top\">#{dot}</td>" <>
          "<td style=\"padding:8px 12px;border-bottom:1px solid #eee\"><b style=\"color:#{color}\">#{esc(a.subject)}</b><br><span style=\"color:#555;font-size:13px\">#{esc(a.line)}</span></td></tr>"
      end)

    """
    <div style="font-family:-apple-system,Segoe UI,Helvetica,Arial,sans-serif;max-width:640px">
      <h2 style="margin:0 0 4px">ListSignal alerts</h2>
      <p style="color:#666;margin:0 0 16px;font-size:13px">#{length(alerts)} condition(s) need attention · #{now_str()} UTC</p>
      <table style="border-collapse:collapse;width:100%">#{rows}</table>
      <p style="color:#999;font-size:12px;margin-top:16px">Each alert repeats at most every #{@cooldown_hours}h. Full picture: the /admin dashboard.</p>
    </div>
    """
  end

  defp al(sev, key, subject, line), do: %{severity: sev, key: key, subject: subject, line: line}
  defp short(w), do: w |> to_string() |> String.split("@") |> hd() |> String.replace("worker_", "")
  defp keyify(list), do: list |> Enum.join(",") |> then(&:crypto.hash(:md5, &1)) |> Base.encode16() |> binary_part(0, 8)
  defp stale_run?(_s), do: true
  defp fmt(n) when is_integer(n) and n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp fmt(n) when is_integer(n) and n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp fmt(n), do: "#{n}"
  defp esc(s), do: s |> to_string() |> String.replace("&", "&amp;") |> String.replace("<", "&lt;") |> String.replace(">", "&gt;")
  defp now_str, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_string()
end
