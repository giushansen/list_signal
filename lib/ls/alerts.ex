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
  # normal ~500-800k/3h
  @ingestion_3h_floor 150_000
  # normal ~170-230k/6h; below this a node is effectively dead
  @worker_6h_floor 20_000
  # normal 5-9%; ~100% is the h1 split-brain
  @resolved_fail_ceiling 30.0
  # businesses should be < ~90 min old (compactor)
  @stale_seconds_ceiling 5_400
  # early runway: the CH backup needs ~1.5x the DB free
  @disk_pct_warn 80
  # 240G disk-full caused a 521 outage before
  @disk_pct_ceiling 88
  # hourly job; 6h means it has missed several
  @sqlite_backup_age_h 6
  # runs every 6h; businesses+biz_* = weeks of crawling
  @product_backup_age_h 14
  # weekly job (domains_history); >9d = it has skipped a run
  @ch_backup_age_h 216
  # Low-memory floor, twice recalibrated (2026-08-25/26).
  #
  # 900MB was written for the 16G master and applied to EVERY node. Then 10%
  # (200MB on a 2G box) still cried wolf: MEASURED healthy steady state on the
  # 1-core crawlers is 205-373MB available, because Linux fills a small box
  # with page cache and MemAvailable counts conservatively. Meanwhile the nodes
  # in genuine distress (chi1, ny2 — thousands of swap-ins/second) sat at
  # 241-277MB on 4G, i.e. BELOW 5% but above 10%.
  #
  # So the floor is 5% of the node's RAM, never below 100MB: a 2G crawler
  # alerts under 100MB (swap engaged, OOM killer near) and a 4G worker under
  # 195MB (which is where the real thrashing showed up). Cheap, honest, and
  # it fires on distress rather than on "busy".
  #
  # SUPERSEDED 2026-08-30 by PSI (see mem_pressure_band/2) wherever a node
  # reports it — which is every current node, since PSI needs only kernel
  # 4.20+. This raw-% floor stays ONLY as the fallback for a node too old to
  # expose /proc/pressure/memory, because "no PSI" must never mean "no check
  # at all". Workers were found to run with NO cgroup memory limit and swap
  # freely available (up to 13.7GB observed in use on one node) — running
  # near-full-with-swap is normal there, not dangerous, which is exactly the
  # distinction raw-% cannot make and PSI can: it measures whether tasks were
  # actually STALLED waiting on memory, not how much is merely occupied.
  @mem_avail_pct_floor 5
  @mem_avail_mb_min 100
  # Used only when a node does not report its total RAM at all.
  @mem_avail_mb_floor 900
  # PSI `full` = ALL runnable tasks stalled on memory reclaim, i.e. genuine
  # thrashing, not "memory is full" (which alone is fine — that is what RAM
  # is for). avg60 >= 5.0 means at least 5% of the last minute was spent with
  # nothing able to make progress; avg10 >= 15.0 is acute, last-breath-before-
  # OOM territory. Thresholds follow the common oomd/PSI convention, not a
  # measurement specific to this fleet — recalibrate once real fleet data
  # exists to compare against.
  @mem_pressure_warn_pct 5.0
  @mem_pressure_crit_pct 15.0
  @queue_pct_ceiling 92.0
  # 24h/12h download loops; >2 days = downloads failing
  @reputation_age_ceiling_h 50
  # a source stuck 'running' this long is wedged
  @verification_running_ceiling_h 8
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
      unmonitored_nodes: Metrics.unmonitored_nodes(),
      watchdog_restarts: Metrics.watchdog_restarts(24),
      data_check: LS.DataCheck.snapshot(),
      reputation_ages: Metrics.reputation_ages(),
      backups: Metrics.backup_status(),
      verification: Metrics.verification(),
      poller: Metrics.poller(),
      ctl_diff: LS.CTL.LogList.diff_current()
    }
  end

  @doc "Pure: metrics map → firing alerts, most severe first."
  @spec evaluate(map()) :: [
          %{
            key: String.t(),
            severity: :critical | :warning,
            subject: String.t(),
            line: String.t()
          }
        ]
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
    |> backups(m)
    |> verification(m)
    |> ctl_sources(m)
    |> unmonitored(m)
    |> watchdog(m)
    |> data_check(m)
    |> Enum.sort_by(&(&1.severity == :critical), :desc)
  end

  # ── checks (each prepends firing alerts) ──

  defp ingestion(acc, %{ingestion_3h: n}) when is_integer(n) and n < @ingestion_3h_floor,
    do: [
      al(
        :critical,
        "ingestion_low",
        "Ingestion stalled",
        "only #{fmt(n)} domains crawled in the last 3h (floor #{fmt(@ingestion_3h_floor)})"
      )
      | acc
    ]

  defp ingestion(acc, _), do: acc

  defp workers_dead(acc, %{known_workers: known, per_worker: pw}) do
    live = Map.new(pw, &{&1.worker, &1.rows})

    Enum.reduce(known, acc, fn w, a ->
      rows = Map.get(live, w, 0)

      if rows < @worker_6h_floor,
        do: [
          al(
            :critical,
            "worker_dead:#{w}",
            "Worker down: #{short(w)}",
            "#{short(w)} produced #{fmt(rows)} rows in 6h (floor #{fmt(@worker_6h_floor)})"
          )
          | a
        ],
        else: a
    end)
  end

  defp workers_quality(acc, %{per_worker: pw}) do
    Enum.reduce(pw, acc, fn w, a ->
      if w.rows > 5_000 and w.resolved_fail_pct > @resolved_fail_ceiling,
        do: [
          al(
            :critical,
            "worker_quality:#{w.worker}",
            "Worker degraded: #{short(w.worker)}",
            "#{short(w.worker)} resolves DNS but #{w.resolved_fail_pct}% of those fail HTTP (split-brain resolver?)"
          )
          | a
        ],
        else: a
    end)
  end

  defp workers_quarantined(acc, %{worker_health: wh}) do
    q = for {w, h} <- wh, Map.get(h, :quarantined), do: w

    if q == [],
      do: acc,
      else: [
        al(
          :critical,
          "quarantined",
          "Worker(s) quarantined",
          "#{Enum.join(Enum.map(q, &short/1), ", ")}, hollow rows being dropped; fix then Inserter.release_worker/1"
        )
        | acc
      ]
  end

  defp compaction(acc, %{stale_seconds: s}) when is_integer(s) and s > @stale_seconds_ceiling,
    do: [
      al(
        :critical,
        "compaction_stale",
        "Product table stale",
        "businesses last updated #{div(s, 60)} min ago, compactor may be failing"
      )
      | acc
    ]

  defp compaction(acc, _), do: acc

  # Quality, quantity and speed of the data itself, from LS.DataCheck. The
  # infra checks above say the machines are fine; these say the ROWS are fine,
  # which machines cannot know (the h1 incident wrote 45M hollow rows while
  # every process was green).
  defp data_check(acc, %{data_check: snap}), do: LS.DataCheck.alerts(snap) ++ acc
  defp data_check(acc, _), do: acc

  # The watchdog restarting the web means the site WAS down. Alerting runs
  # inside the process that died, so nothing else can report it — and a silent
  # auto-recovery reads exactly like uptime. That is how the same stall
  # recurred four times before anyone looked (2026-08-27).
  defp watchdog(acc, %{watchdog_restarts: []}), do: acc

  defp watchdog(acc, %{watchdog_restarts: [%{at: at} | _] = restarts}) when is_list(restarts) do
    [
      al(
        :critical,
        "watchdog_restart:#{DateTime.to_unix(at)}",
        "Site auto-restarted #{length(restarts)}x in 24h",
        "The web watchdog restarted listsignal@master, the site was DOWN until it did. " <>
          "Most recent: #{DateTime.to_string(at)}. Check /var/log/listsignal_watchdog.log " <>
          "for the memory reading that preceded it."
      )
      | acc
    ]
  end

  defp watchdog(acc, _), do: acc

  # A node the resource alerts cannot see is worse than a node with a problem:
  # its silence is indistinguishable from health. See Metrics.unmonitored_nodes/0.
  defp unmonitored(acc, %{unmonitored_nodes: []}), do: acc

  defp unmonitored(acc, %{unmonitored_nodes: nodes}) when is_list(nodes) do
    names = nodes |> Enum.map(&short/1) |> Enum.sort() |> Enum.join(", ")

    [
      al(
        :warning,
        "unmonitored:#{length(nodes)}",
        "#{length(nodes)} node(s) report no resources",
        "#{names} answer Erlang distribution but not LS.Ops.NodeResources, " <>
          "usually a stale release (restarted, never re-deployed). They are invisible " <>
          "to every RAM/disk/CPU alert until deployed."
      )
      | acc
    ]
  end

  defp unmonitored(acc, _), do: acc

  defp resources(acc, %{node_resources: nodes}) do
    Enum.reduce(nodes, acc, fn {node, r}, a ->
      a
      |> then(fn a ->
        cond do
          not is_integer(r[:disk_used_pct]) ->
            a

          r.disk_used_pct >= @disk_pct_ceiling ->
            [
              al(
                :critical,
                "disk:#{node}",
                "Disk almost full: #{short(node)}",
                "#{short(node)} disk #{r.disk_used_pct}% used (#{r[:disk_used_gb]}/#{r[:disk_total_gb]}GB)"
              )
              | a
            ]

          # Early warning: below this the ClickHouse dump (needs ~1.5x the DB
          # free) starts getting skipped silently — that is how the product DB
          # went unbacked in Aug 2026.
          r.disk_used_pct >= @disk_pct_warn ->
            [
              al(
                :warning,
                "disk_warn:#{node}",
                "Disk filling: #{short(node)}",
                "#{short(node)} disk #{r.disk_used_pct}% used (#{r[:disk_used_gb]}/#{r[:disk_total_gb]}GB), backups need headroom"
              )
              | a
            ]

          true ->
            a
        end
      end)
      |> then(fn a -> mem_alert(a, node, r) end)
      |> then(fn a -> restart_alert(a, node, r) end)
    end)
  end

  # PSI when the node reports it (every current node); the raw-% floor is the
  # fallback for one that cannot. Never both at once — PSI already IS the
  # "is this dangerous" answer, so falling back on top of it would just be
  # the noise this replaced.
  defp mem_alert(a, node, r) do
    case mem_pressure_band(r[:mem_pressure_full_avg10], r[:mem_pressure_full_avg60]) do
      :critical ->
        [
          al(
            :critical,
            "mem_pressure:#{node}",
            "Memory thrashing: #{short(node)}",
            "#{short(node)} spent #{r.mem_pressure_full_avg10}% of the last 10s with EVERY task " <>
              "stalled on memory reclaim (60s avg #{r.mem_pressure_full_avg60}%). This is genuine " <>
              "distress, not just high usage."
          )
          | a
        ]

      :warning ->
        [
          al(
            :warning,
            "mem_pressure:#{node}",
            "Memory pressure: #{short(node)}",
            "#{short(node)} 60s memory-stall average #{r.mem_pressure_full_avg60}%. Tasks are " <>
              "regularly waiting on memory. Not yet critical, worth watching."
          )
          | a
        ]

      :unknown ->
        if is_integer(r[:mem_avail_mb]) and r.mem_avail_mb < mem_floor_mb(r[:mem_total_mb]) do
          [
            al(
              :warning,
              "mem:#{node}",
              "Low memory: #{short(node)}",
              "#{short(node)} only #{r.mem_avail_mb}MB RAM available (floor #{mem_floor_mb(r[:mem_total_mb])}MB for a " <>
                "#{r[:mem_total_mb] || "?"}MB node), PSI unavailable on this kernel, falling back to raw %."
            )
            | a
          ]
        else
          a
        end

      :ok ->
        a
    end
  end

  # "Down or restarted, and why" (2026-08-30). Keyed on restart_count so the
  # SAME restart is reported once — a node that stays up afterward must not
  # re-alert on every 15-minute tick forever. A fresh restart_count is a
  # fresh key with no cooldown history, so a genuinely new event always fires
  # immediately regardless of the 6h cooldown window.
  defp restart_alert(a, node, %{restart_result: res, restart_count: n})
       when is_binary(res) and res != "success" and is_integer(n) do
    [
      al(
        :critical,
        "restart_reason:#{node}:#{n}",
        "#{short(node)} restarted: #{res}",
        "#{short(node)}'s service exited with result \"#{res}\" (restart ##{n} since boot). " <>
          "this was not a clean stop, so it was not a deploy."
      )
      | a
    ]
  end

  defp restart_alert(a, _node, _r), do: a

  @doc """
  PSI severity band. `:unknown` when the node has no PSI to report (old
  kernel), so the caller can fall back rather than silently skip the check.
  """
  @spec mem_pressure_band(number() | nil, number() | nil) :: :ok | :warning | :critical | :unknown
  def mem_pressure_band(a10, a60)
  def mem_pressure_band(nil, nil), do: :unknown

  def mem_pressure_band(a10, _a60) when is_number(a10) and a10 >= @mem_pressure_crit_pct,
    do: :critical

  def mem_pressure_band(_a10, a60) when is_number(a60) and a60 >= @mem_pressure_warn_pct,
    do: :warning

  def mem_pressure_band(_, _), do: :ok

  defp queue(acc, %{queue: %{queue_pct: p}}) when is_number(p) and p > @queue_pct_ceiling,
    do: [
      al(
        :warning,
        "queue_full",
        "Work queue near cap",
        "queue at #{p}%, discovery inflow being shed; add workers"
      )
      | acc
    ]

  defp queue(acc, _), do: acc

  defp reputation(acc, %{reputation_ages: ages}) do
    for {name, age} <- ages, is_integer(age) and age > @reputation_age_ceiling_h, reduce: acc do
      a ->
        [
          al(
            :warning,
            "reputation:#{name}",
            "#{name} download stale",
            "#{name} data is #{age}h old, download loop may be failing"
          )
          | a
        ]
    end
  end

  # Silent backup failure is the worst bug class: you learn about it only when
  # you need the backup. Severity follows how expensive the tier is to rebuild
  # (backup.sh's own reasoning): the product tier is weeks of crawling, sqlite
  # is irreplaceable-but-tiny, and the ClickHouse tier is domains_history,
  # which is history rather than derived state.
  # No backup directory (dev box, a worker, a fresh install) => nothing to judge.
  # Without this, a machine that never had backups reports three missing ones.
  defp backups(acc, %{backups: %{dir: nil}}), do: acc

  defp backups(acc, %{backups: b}) when is_map(b) do
    acc
    |> stale_backup(
      b[:product_age_h],
      @product_backup_age_h,
      :critical,
      "backup_product",
      "Product backup stale",
      "businesses + biz_*, weeks of crawling to rebuild"
    )
    |> stale_backup(
      b[:sqlite_age_h],
      @sqlite_backup_age_h,
      :critical,
      "backup_sqlite",
      "SQLite backup stale",
      "users/plans/Stripe, irreplaceable"
    )
    |> stale_backup(
      b[:ch_age_h],
      @ch_backup_age_h,
      :warning,
      "backup_ch",
      "ClickHouse backup stale",
      "domains_history weekly dump"
    )
  end

  defp backups(acc, _), do: acc

  # One shape for all three tiers: missing entirely, or older than its cadence.
  defp stale_backup(acc, age, ceiling, severity, key, subject, what) do
    cond do
      is_nil(age) ->
        [
          al(
            severity,
            "#{key}_missing",
            "No #{subject |> String.downcase() |> String.replace(" stale", "")} exists",
            "no archive at all, #{what}"
          )
          | acc
        ]

      age > ceiling ->
        [
          al(
            severity,
            key,
            subject,
            "newest archive is #{age}h old (expected < #{ceiling}h), #{what}"
          )
          | acc
        ]

      true ->
        acc
    end
  end

  defp verification(acc, %{verification: %{sources: sources, scheduler: sched}})
       when is_list(sources) do
    running = sched && Map.get(sched, :running)

    Enum.reduce(sources, acc, fn s, a ->
      cond do
        running && to_string(running) == s.source && s.duration_s == 0 && stale_run?(s) ->
          [
            al(
              :warning,
              "verify_stuck:#{s.source}",
              "Verification wedged: #{s.source}",
              "#{s.source} has been running > #{@verification_running_ceiling_h}h"
            )
            | a
          ]

        s.status == "error" ->
          [
            al(
              :warning,
              "verify_error:#{s.source}",
              "Verification failed: #{s.source}",
              "last #{s.source} run errored: #{String.slice(s.error || "", 0, 100)}"
            )
            | a
          ]

        true ->
          a
      end
    end)
  end

  defp verification(acc, _), do: acc

  defp ctl_sources(acc, %{ctl_diff: %{new: new, retired: retired}}) do
    acc
    |> then(fn a ->
      if new == [],
        do: a,
        else: [
          al(
            :warning,
            "ctl_new:#{keyify(new)}",
            "New CT log source(s) available",
            "Chrome lists ingestible CT logs we don't poll: #{Enum.join(new, ", ")}. The poller reconciles every 6h, if this alert persists, the reconcile loop is broken (check [CTL] lines in the master journal)."
          )
          | a
        ]
    end)
    |> then(fn a ->
      if retired == [],
        do: a,
        else: [
          al(
            :warning,
            "ctl_retired:#{keyify(retired)}",
            "CT log source(s) retiring",
            "Logs we poll are no longer ingestible in Chrome's list: #{Enum.join(retired, ", ")}. The poller retires them itself within 6h, if this alert persists, the reconcile loop is broken."
          )
          | a
        ]
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
      # The data-health section rides at the bottom of EVERY alert email, so
      # the owner sees the full quality/quantity/speed picture in the same
      # message that raised the alarm.
      body = digest_html(fresh) <> LS.DataCheck.html_section(LS.DataCheck.snapshot())

      case LS.Ops.Mail.send(subject, body) do
        :ok -> Enum.each(fresh, &record_sent/1)
        _ -> :noop
      end
    end

    fresh
  end

  @doc """
  The quiet-week data email: every Monday morning, if not one alert went out
  in the past 7 days, send the data-health section alone. Silence for a week
  is either health or a dead alerting pipeline, and those must not read the
  same (the watchdog restarts stayed invisible for exactly that reason).
  """
  def send_quiet_week_email do
    body =
      """
      <div style="font-family:-apple-system,Segoe UI,Helvetica,Arial,sans-serif;max-width:640px">
        <h2 style="margin:0 0 4px">ListSignal data health</h2>
        <p style="color:#666;margin:0 0 12px;font-size:13px">No alerts this week. Here is the proof the data is healthy, not just quiet.</p>
      #{LS.DataCheck.html_section(LS.DataCheck.snapshot())}
      </div>
      """

    case LS.Ops.Mail.send("\u{1F7E2} ListSignal data health: quiet week", body) do
      :ok ->
        record_sent(%{key: "data_quiet_week", subject: "data health quiet week"})
        :ok

      other ->
        other
    end
  end

  @doc "True when zero alert emails went out in the past 7 days (weekly digests excluded)."
  def quiet_week? do
    sql =
      "SELECT count() FROM ops_email_log WHERE sent_at > now() - INTERVAL 7 DAY " <>
        "AND key NOT IN ('weekly_report', 'data_quiet_week')"

    case Clickhouse.query_raw(sql, 5_000) do
      {:ok, [[n]]} -> to_i(n) == 0
      _ -> false
    end
  end

  defp to_i(v) when is_integer(v), do: v
  defp to_i(v) when is_binary(v), do: String.to_integer(String.trim(v))
  defp to_i(_), do: 1

  # ── cooldown via ops_email_log ──

  defp cooling_down?(%{key: key}) do
    case Clickhouse.query_raw(
           "SELECT max(sent_at) FROM ops_email_log WHERE key = '#{Clickhouse.escape_public(key)}' AND sent_at > now() - INTERVAL #{@cooldown_hours} HOUR",
           5_000
         ) do
      {:ok, [[t]]} when is_binary(t) and t not in ["", "1970-01-01 00:00:00"] -> true
      _ -> false
    end
  end

  defp record_sent(%{key: key, subject: subject}) do
    body = Jason.encode!(%{key: key, sent_at: now_str(), subject: String.slice(subject, 0, 200)})
    Clickhouse.insert_raw("INSERT INTO ops_email_log FORMAT JSONEachRow", body)
  end

  # ── formatting ──

  defp digest_subject([%{severity: :critical} | _] = a),
    do: "🔴 ListSignal alert: #{hd(a).subject}" <> more(a)

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
  @doc false
  # Size-aware low-memory floor: 5% of total RAM, never below 100MB;
  # @mem_avail_mb_floor when the node did not report its total.
  def mem_floor_mb(nil), do: @mem_avail_mb_floor

  def mem_floor_mb(total_mb) when is_integer(total_mb) and total_mb > 0,
    do: max(@mem_avail_mb_min, div(total_mb * @mem_avail_pct_floor, 100))

  def mem_floor_mb(_), do: @mem_avail_mb_floor

  defp short(w),
    do: w |> to_string() |> String.split("@") |> hd() |> String.replace("worker_", "")

  defp keyify(list),
    do:
      list
      |> Enum.join(",")
      |> then(&:crypto.hash(:md5, &1))
      |> Base.encode16()
      |> binary_part(0, 8)

  defp stale_run?(_s), do: true
  defp fmt(n) when is_integer(n) and n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp fmt(n) when is_integer(n) and n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp fmt(n), do: "#{n}"

  defp esc(s),
    do:
      s
      |> to_string()
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")

  defp now_str,
    do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_string()
end
