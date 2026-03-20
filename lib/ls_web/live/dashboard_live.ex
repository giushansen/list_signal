defmodule LSWeb.DashboardLive do
  @moduledoc """
  Real-time pipeline flow dashboard.

  Shows data flowing left→right through each stage:
    CTL Poller → Queue → Workers (DNS→HTTP→BGP) → ClickHouse

  Peek: click any stage to see 5 sample rows without impacting performance.
  Errors: centralized error log from all nodes, newest first.
  """

  use LSWeb, :live_view

  @refresh_interval 3_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh_interval)
    {:ok,
     assign(socket,
       role: System.get_env("LS_ROLE", "standalone"),
       master_stats: collect_master_stats(),
       worker_stats: collect_worker_stats(),
       all_errors: collect_all_errors(),
       peek: nil, peek_data: nil, show_errors: false
     )}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_interval)
    {:noreply,
     assign(socket,
       master_stats: collect_master_stats(),
       worker_stats: collect_worker_stats(),
       all_errors: if(socket.assigns.show_errors, do: collect_all_errors(), else: socket.assigns.all_errors)
     )}
  end

  @peek_stages %{"dns" => :dns, "http" => :http, "bgp" => :bgp, "merged" => :merged}

  @impl true
  def handle_event("peek", %{"worker" => worker, "stage" => stage}, socket) do
    node = String.to_existing_atom(worker)
    stage_atom = Map.get(@peek_stages, stage, :merged)
    samples = try do
      GenServer.call({LS.Cluster.WorkerAgent, node}, {:peek, stage_atom}, 5_000)
    catch
      :exit, _ -> []
    end
    {:noreply, assign(socket, peek: %{worker: worker, stage: stage}, peek_data: samples)}
  end

  @impl true
  def handle_event("close_peek", _params, socket) do
    {:noreply, assign(socket, peek: nil, peek_data: nil)}
  end

  @impl true
  def handle_event("toggle_errors", _params, socket) do
    show = !socket.assigns.show_errors
    errors = if show, do: collect_all_errors(), else: socket.assigns.all_errors
    {:noreply, assign(socket, show_errors: show, all_errors: errors)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <style>
      * { box-sizing: border-box; margin: 0; padding: 0; }
      @import url('https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;600;700&family=IBM+Plex+Sans:wght@400;500;600&display=swap');
      body { background: #0a0e17; }
      .dash { font-family: 'IBM Plex Sans', -apple-system, sans-serif; color: #c8d3e0; max-width: 1400px; margin: 0 auto; padding: 24px; }
      .header { display: flex; align-items: baseline; gap: 16px; margin-bottom: 32px; border-bottom: 1px solid #1a2235; padding-bottom: 16px; }
      .header h1 { font-family: 'JetBrains Mono', monospace; font-size: 20px; font-weight: 700; color: #e8edf4; letter-spacing: -0.5px; }
      .role-badge { font-family: 'JetBrains Mono', monospace; font-size: 11px; font-weight: 500; color: #38bdf8; background: rgba(56,189,248,0.08); border: 1px solid rgba(56,189,248,0.2); padding: 3px 10px; border-radius: 4px; text-transform: uppercase; letter-spacing: 1px; }
      .err-toggle { font-family: 'JetBrains Mono', monospace; font-size: 11px; color: #64748b; background: transparent; border: 1px solid #1e293b; border-radius: 4px; padding: 3px 10px; cursor: pointer; margin-left: auto; transition: all 0.15s; }
      .err-toggle:hover { border-color: #334155; color: #94a3b8; }
      .err-toggle.has-errors { color: #fbbf24; border-color: rgba(251,191,36,0.3); }
      .section-label { font-family: 'JetBrains Mono', monospace; font-size: 10px; font-weight: 600; color: #4a5568; text-transform: uppercase; letter-spacing: 2px; margin-bottom: 12px; }
      .alert-warn { background: rgba(251,191,36,0.06); border: 1px solid rgba(251,191,36,0.25); border-radius: 6px; padding: 10px 16px; margin-bottom: 20px; font-size: 13px; color: #fbbf24; }
      .pipeline { display: flex; align-items: stretch; gap: 0; margin-bottom: 32px; }
      .stage { flex: 1; background: #111827; border: 1px solid #1e293b; border-radius: 8px; padding: 16px; min-width: 0; }
      .stage-name { font-family: 'JetBrains Mono', monospace; font-size: 10px; font-weight: 600; color: #64748b; text-transform: uppercase; letter-spacing: 1.5px; margin-bottom: 8px; }
      .stage-value { font-family: 'JetBrains Mono', monospace; font-size: 26px; font-weight: 700; color: #e2e8f0; line-height: 1.1; }
      .stage-unit { font-size: 12px; font-weight: 500; color: #64748b; }
      .stage-sub { font-family: 'JetBrains Mono', monospace; font-size: 11px; color: #4a5568; margin-top: 6px; line-height: 1.5; }
      .flow-arrow { display: flex; flex-direction: column; align-items: center; justify-content: center; padding: 0 6px; min-width: 60px; }
      .arrow-line { font-family: 'JetBrains Mono', monospace; font-size: 16px; color: #334155; letter-spacing: -2px; }
      .arrow-rate { font-family: 'JetBrains Mono', monospace; font-size: 10px; color: #38bdf8; white-space: nowrap; margin-top: 2px; }
      .worker-card { background: #111827; border: 1px solid #1e293b; border-radius: 8px; padding: 16px; margin-bottom: 12px; }
      .worker-header { display: flex; align-items: center; gap: 10px; margin-bottom: 14px; }
      .worker-name { font-family: 'JetBrains Mono', monospace; font-size: 13px; font-weight: 600; color: #e2e8f0; }
      .badge { font-family: 'JetBrains Mono', monospace; font-size: 10px; font-weight: 500; padding: 2px 8px; border-radius: 3px; text-transform: uppercase; letter-spacing: 0.5px; }
      .badge-green { color: #4ade80; background: rgba(74,222,128,0.08); border: 1px solid rgba(74,222,128,0.2); }
      .badge-yellow { color: #fbbf24; background: rgba(251,191,36,0.08); border: 1px solid rgba(251,191,36,0.2); }
      .badge-red { color: #f87171; background: rgba(248,113,113,0.08); border: 1px solid rgba(248,113,113,0.2); }
      .worker-batch-info { font-family: 'JetBrains Mono', monospace; font-size: 11px; color: #4a5568; margin-left: auto; }
      .worker-pipeline { display: flex; align-items: stretch; gap: 0; }
      .w-stage { flex: 1; background: #0d1320; border: 1px solid #1a2235; border-radius: 6px; padding: 10px 12px; text-align: center; min-width: 0; }
      .w-stage-name { font-family: 'JetBrains Mono', monospace; font-size: 9px; font-weight: 600; color: #4a5568; text-transform: uppercase; letter-spacing: 1.5px; margin-bottom: 4px; }
      .w-stage-count { font-family: 'JetBrains Mono', monospace; font-size: 18px; font-weight: 700; color: #e2e8f0; }
      .w-stage-time { font-family: 'JetBrains Mono', monospace; font-size: 10px; color: #64748b; margin-top: 2px; }
      .w-stage-detail { font-family: 'JetBrains Mono', monospace; font-size: 9px; color: #374151; margin-top: 2px; }
      .w-arrow { display: flex; align-items: center; justify-content: center; padding: 0 4px; min-width: 24px; }
      .w-arrow-char { font-family: 'JetBrains Mono', monospace; font-size: 14px; color: #1e293b; }
      .peek-btn { font-family: 'JetBrains Mono', monospace; font-size: 9px; font-weight: 500; color: #38bdf8; background: transparent; border: 1px solid rgba(56,189,248,0.15); border-radius: 3px; padding: 2px 6px; cursor: pointer; margin-top: 4px; text-transform: uppercase; letter-spacing: 0.5px; transition: all 0.15s; }
      .peek-btn:hover { background: rgba(56,189,248,0.08); border-color: rgba(56,189,248,0.35); }
      .no-workers { font-family: 'JetBrains Mono', monospace; font-size: 12px; color: #374151; padding: 24px; text-align: center; background: #111827; border: 1px dashed #1e293b; border-radius: 8px; }
      .peek-panel { background: #0d1320; border: 1px solid #1e293b; border-radius: 8px; padding: 16px; margin-top: 16px; margin-bottom: 24px; overflow-x: auto; }
      .peek-header { display: flex; align-items: center; gap: 10px; margin-bottom: 12px; }
      .peek-title { font-family: 'JetBrains Mono', monospace; font-size: 11px; font-weight: 600; color: #64748b; text-transform: uppercase; letter-spacing: 1px; }
      .peek-close { font-family: 'JetBrains Mono', monospace; font-size: 11px; color: #4a5568; background: transparent; border: 1px solid #1e293b; border-radius: 4px; padding: 2px 8px; cursor: pointer; margin-left: auto; }
      .peek-close:hover { color: #f87171; border-color: rgba(248,113,113,0.3); }
      .peek-table { width: 100%; border-collapse: collapse; font-family: 'JetBrains Mono', monospace; font-size: 11px; min-width: 800px; }
      .peek-table th { text-align: left; padding: 6px 10px; color: #4a5568; font-weight: 600; font-size: 9px; text-transform: uppercase; letter-spacing: 1px; border-bottom: 1px solid #1a2235; white-space: nowrap; }
      .peek-table td { padding: 5px 10px; color: #94a3b8; border-bottom: 1px solid #0f1729; white-space: nowrap; }
      .peek-table tr:hover td { color: #e2e8f0; }
      .peek-empty { font-family: 'JetBrains Mono', monospace; font-size: 11px; color: #374151; padding: 16px; text-align: center; }
      .error-panel { background: #111827; border: 1px solid #1e293b; border-radius: 8px; padding: 16px; margin-bottom: 24px; }
      .error-row { display: flex; gap: 12px; padding: 5px 0; border-bottom: 1px solid #0f1729; font-family: 'JetBrains Mono', monospace; font-size: 11px; }
      .error-time { color: #374151; min-width: 80px; flex-shrink: 0; }
      .error-node { color: #64748b; min-width: 160px; flex-shrink: 0; }
      .error-stage { min-width: 70px; flex-shrink: 0; padding: 1px 6px; border-radius: 3px; text-align: center; font-size: 9px; text-transform: uppercase; letter-spacing: 0.5px; }
      .error-stage-dns { color: #38bdf8; background: rgba(56,189,248,0.08); }
      .error-stage-http { color: #a78bfa; background: rgba(167,139,250,0.08); }
      .error-stage-bgp { color: #fbbf24; background: rgba(251,191,36,0.08); }
      .error-stage-connection { color: #f87171; background: rgba(248,113,113,0.08); }
      .error-msg { color: #94a3b8; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .error-empty { font-family: 'JetBrains Mono', monospace; font-size: 11px; color: #374151; padding: 12px; text-align: center; }
      .text-red { color: #f87171; }

      /* Health bar */
      .health-bar {
        margin-bottom: 24px; padding: 12px 16px;
        background: #111827; border: 1px solid #1e293b; border-radius: 8px;
        display: flex; align-items: center; gap: 16px;
        font-family: 'JetBrains Mono', monospace; font-size: 11px;
      }
      .health-dot {
        width: 10px; height: 10px; border-radius: 50%; flex-shrink: 0;
        box-shadow: 0 0 6px currentColor;
      }
      .health-green { background: #4ade80; color: #4ade80; }
      .health-amber { background: #fbbf24; color: #fbbf24; }
      .health-red { background: #f87171; color: #f87171; }
      .health-label { color: #94a3b8; }
      .health-detail { color: #4a5568; margin-left: auto; }
      .health-needed { color: #64748b; }

      /* DNS success indicator on worker stages */
      .dns-rate { font-size: 9px; margin-top: 2px; }
      .dns-rate-good { color: #4ade80; }
      .dns-rate-warn { color: #fbbf24; }
      .dns-rate-bad { color: #f87171; }
    </style>

    <div class="dash">
      <div class="header">
        <h1>ListSignal</h1>
        <span class="role-badge">{@role}</span>
        <button class={"err-toggle" <> if(length(@all_errors) > 0, do: " has-errors", else: "")} phx-click="toggle_errors">
          <%= if @show_errors do %>✕ hide errors<% else %>{length(@all_errors)} errors<% end %>
        </button>
      </div>

      <%= if @master_stats.queue && @master_stats.queue.queue_pct >= 80.0 do %>
        <div class="alert-warn">⚠ Queue at {@master_stats.queue.queue_pct}% — add workers</div>
      <% end %>

      <%= if @show_errors do %>
        <div class="error-panel">
          <div class="section-label" style="margin-bottom: 8px;">Recent Errors (all nodes)</div>
          <%= if @all_errors == [] do %>
            <div class="error-empty">No errors — pipeline running clean</div>
          <% else %>
            <%= for e <- Enum.take(@all_errors, 30) do %>
              <div class="error-row">
                <span class="error-time">{fmt_err_time(e.time)}</span>
                <span class="error-node">{e.node}</span>
                <span class={"error-stage error-stage-#{e.stage}"}>{e.stage}</span>
                <span class="error-msg">{e.msg}</span>
              </div>
            <% end %>
          <% end %>
        </div>
      <% end %>

      <div class="section-label">Pipeline Flow</div>

      <% {health_color, health_msg, workers_needed} = pipeline_health(@master_stats) %>
      <div class="health-bar">
        <span class={"health-dot " <> health_color}></span>
        <span class="health-label">{health_msg}</span>
        <span class="health-detail">
          in: {pr(@master_stats.poller)}/s · out: {fmt_rate(qv(@master_stats.queue, :drain_rate_per_min))}/s
          · ratio: {capacity_ratio(@master_stats)}
        </span>
        <%= if workers_needed > length(@worker_stats) do %>
          <span class="health-needed">need ~{workers_needed} workers</span>
        <% end %>
      </div>
      <div class="pipeline">
        <div class="stage">
          <div class="stage-name">CTL Poller</div>
          <div class="stage-value">{pr(@master_stats.poller)}<span class="stage-unit">/s</span></div>
          <div class="stage-sub">{plc(@master_stats.poller)} logs active<br/>{fmt(@master_stats.cache.ctl.entries)} domains seen<br/>{@master_stats.cache.ctl.memory_mb} MB</div>
        </div>
        <div class="flow-arrow"><span class="arrow-line">———→</span><span class="arrow-rate">{pr(@master_stats.poller)}/s</span></div>
        <div class="stage">
          <div class="stage-name">Queue</div>
          <div class="stage-value">{fmt(qv(@master_stats.queue, :queue_depth))}</div>
          <div class="stage-sub">{qv(@master_stats.queue, :queue_pct)}% of 5M<br/>{fmt(qv(@master_stats.queue, :total_completed))} completed<br/>{fmt(qv(@master_stats.queue, :total_requeued))} requeued</div>
        </div>
        <div class="flow-arrow"><span class="arrow-line">———→</span><span class="arrow-rate">{qv(@master_stats.queue, :drain_rate_per_min)}/min</span></div>
        <div class="stage">
          <div class="stage-name">Workers</div>
          <div class="stage-value">{length(@worker_stats)}</div>
          <div class="stage-sub">{qv(@master_stats.queue, :drain_rate_per_min)}/min drain<br/>{qv(@master_stats.queue, :inflight_batches)} in-flight</div>
        </div>
        <div class="flow-arrow"><span class="arrow-line">———→</span><span class="arrow-rate">{iv(@master_stats.inserter, :insert_rate_per_min)}/min</span></div>
        <div class="stage">
          <div class="stage-name">ClickHouse</div>
          <div class="stage-value">{iv(@master_stats.inserter, :insert_rate_per_min)}<span class="stage-unit">/min</span></div>
          <div class="stage-sub">buffer: {iv(@master_stats.inserter, :buffer_size)}<br/>errors: <span class={if(iv(@master_stats.inserter, :total_errors) > 0, do: "text-red", else: "")}>{iv(@master_stats.inserter, :total_errors)}</span></div>
        </div>
      </div>

      <div class="section-label">Worker Nodes</div>
      <%= if @worker_stats == [] do %>
        <div class="no-workers">No workers connected</div>
      <% else %>
        <%= for {node_name, ws} <- @worker_stats do %>
          <div class="worker-card">
            <div class="worker-header">
              <span class="worker-name">{node_name}</span>
              <span class={badge_class(ws)}>{badge_text(ws)}</span>
              <span class="worker-batch-info">
                {Map.get(ws, :total_batches, 0)} batches · {fmt(Map.get(ws, :total_enriched, 0))} enriched · {Map.get(ws, :domains_per_sec, 0)}/s
                <%= if (ec = Map.get(ws, :error_count, 0)) > 0 do %> · <span class="text-red">{ec} errors</span><% end %>
              </span>
            </div>
            <%= if stages = Map.get(ws, :last_stages) do %>
              <div class="worker-pipeline">
                <div class="w-stage"><div class="w-stage-name">Input</div><div class="w-stage-count">{Map.get(stages.dns, :input, 0)}</div><div class="w-stage-detail">domains</div></div>
                <div class="w-arrow"><span class="w-arrow-char">→</span></div>
                <div class="w-stage"><div class="w-stage-name">DNS</div><div class="w-stage-count">{Map.get(stages.dns, :output, 0)}</div><div class="w-stage-time">{fdur(Map.get(stages.dns, :ms, 0))}</div><div class={"w-stage-detail dns-rate " <> dns_rate_class(stages.dns)}>{dns_pct(stages.dns)}% resolved</div><div class="w-stage-detail">{Map.get(ws, :dns_concurrency, 50)} conc</div><button class="peek-btn" phx-click="peek" phx-value-worker={node_name} phx-value-stage="dns">peek</button></div>
                <div class="w-arrow"><span class="w-arrow-char">→</span></div>
                <div class="w-stage"><div class="w-stage-name">HTTP</div><div class="w-stage-count">{Map.get(stages.http, :output, 0)}</div><div class="w-stage-time">{fdur(Map.get(stages.http, :ms, 0))}</div><div class="w-stage-detail">{Map.get(stages.http, :input, 0)} in · {Map.get(stages.http, :filtered, 0)} skip</div><button class="peek-btn" phx-click="peek" phx-value-worker={node_name} phx-value-stage="http">peek</button></div>
                <div class="w-arrow"><span class="w-arrow-char">→</span></div>
                <div class="w-stage"><div class="w-stage-name">BGP</div><div class="w-stage-count">{Map.get(stages.bgp, :output, 0)}</div><div class="w-stage-time">{fdur(Map.get(stages.bgp, :ms, 0))}</div><div class="w-stage-detail">{Map.get(stages.bgp, :input, 0)} IPs</div><button class="peek-btn" phx-click="peek" phx-value-worker={node_name} phx-value-stage="bgp">peek</button></div>
                <div class="w-arrow"><span class="w-arrow-char">→</span></div>
                <div class="w-stage"><div class="w-stage-name">Output</div><div class="w-stage-count">{stages.total}</div><div class="w-stage-detail">rows</div><button class="peek-btn" phx-click="peek" phx-value-worker={node_name} phx-value-stage="merged">peek</button></div>
              </div>
            <% else %>
              <div style="padding: 12px; color: #374151; font-family: 'JetBrains Mono', monospace; font-size: 11px;">Waiting for first batch...</div>
            <% end %>
          </div>
        <% end %>
      <% end %>

      <%= if @peek do %>
        <div class="peek-panel">
          <div class="peek-header">
            <span class="peek-title">{@peek.stage} samples — {@peek.worker}</span>
            <button class="peek-close" phx-click="close_peek">✕ close</button>
          </div>
          <%= if @peek_data == nil or @peek_data == [] do %>
            <div class="peek-empty">No samples yet</div>
          <% else %>
            <table class="peek-table">
              <thead><tr><%= for col <- pcols(@peek.stage) do %><th>{col}</th><% end %></tr></thead>
              <tbody>
                <%= for row <- @peek_data do %>
                  <tr><%= for col <- pcols(@peek.stage) do %><td>{pcell(row, col)}</td><% end %></tr>
                <% end %>
              </tbody>
            </table>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  defp collect_master_stats do
    queue = sc(LS.Cluster.WorkQueue, :stats)
    inserter = sc(LS.Cluster.Inserter, :stats)
    poller = sc(LS.CTL.Poller, :stats)
    cache = try do LS.Cache.stats() rescue _ -> dc() catch :exit, _ -> dc() end
    %{queue: queue, inserter: inserter, poller: poller, cache: cache}
  end

  defp collect_worker_stats do
    Node.list()
    |> Enum.map(fn node ->
      stats = try do
        GenServer.call({LS.Cluster.WorkerAgent, node}, :detailed_stats, 5_000)
      catch
        :exit, _ ->
          try do GenServer.call({LS.Cluster.WorkerAgent, node}, :stats, 5_000)
          catch :exit, _ -> %{status: :unreachable} end
      end
      {Atom.to_string(node), stats}
    end)
  end

  defp collect_all_errors do
    Node.list()
    |> Enum.flat_map(fn node ->
      try do
        errors = GenServer.call({LS.Cluster.WorkerAgent, node}, :errors, 3_000)
        Enum.map(errors, &Map.put(&1, :node, Atom.to_string(node)))
      catch :exit, _ -> [] end
    end)
    |> Enum.sort_by(& &1.time, :desc)
    |> Enum.take(50)
  end

  defp sc(mod, msg), do: (try do GenServer.call(mod, msg, 5_000) rescue _ -> nil catch :exit, _ -> nil end)
  defp dc, do: %{ctl: %{entries: 0, memory_mb: 0, usage_pct: 0}, http: %{entries: 0, memory_mb: 0}, bgp: %{entries: 0, memory_mb: 0}}

  defp qv(nil, _), do: 0
  defp qv(q, k), do: Map.get(q, k, 0)
  defp iv(nil, _), do: 0
  defp iv(i, k), do: Map.get(i, k, 0)
  defp pr(nil), do: "0"
  defp pr(p), do: "#{Map.get(p, :domains_per_sec, 0)}"
  defp plc(nil), do: 0
  defp plc(p), do: Map.get(p, :active_logs, 0)

  # Pipeline health: compares inflow to drain rate
  defp pipeline_health(ms) do
    inflow_per_sec = case ms.poller do
      nil -> 0
      p -> Map.get(p, :domains_per_sec, 0)
    end
    drain_per_sec = qv(ms.queue, :drain_rate_per_min) / 60.0
    worker_count = length(Node.list())

    cond do
      inflow_per_sec == 0 -> {"health-green", "No CTL inflow", 0}
      drain_per_sec == 0 and worker_count == 0 -> {"health-red", "No workers — queue growing", 1}
      drain_per_sec == 0 -> {"health-red", "Workers not draining", max(worker_count, 1)}
      true ->
        ratio = drain_per_sec / inflow_per_sec
        per_worker = if worker_count > 0, do: drain_per_sec / worker_count, else: drain_per_sec
        needed = if per_worker > 0, do: ceil(inflow_per_sec / per_worker), else: 99
        cond do
          ratio >= 0.9 -> {"health-green", "Workers keeping up", needed}
          ratio >= 0.5 -> {"health-amber", "Queue growing slowly", needed}
          true -> {"health-red", "Queue growing fast", needed}
        end
    end
  end

  defp capacity_ratio(ms) do
    inflow = case ms.poller do nil -> 0; p -> Map.get(p, :domains_per_sec, 0) end
    drain = qv(ms.queue, :drain_rate_per_min) / 60.0
    if inflow > 0, do: "#{Float.round(drain / inflow * 100, 0)}%", else: "-"
  end

  defp fmt_rate(per_min) when is_number(per_min), do: "#{Float.round(per_min / 60.0, 1)}"
  defp fmt_rate(_), do: "0"

  # DNS success rate on worker
  defp dns_pct(%{input: 0}), do: 0
  defp dns_pct(%{input: i, output: o}), do: round(o / i * 100)
  defp dns_pct(_), do: 0

  defp dns_rate_class(dns) do
    pct = dns_pct(dns)
    cond do
      pct >= 80 -> "dns-rate-good"
      pct >= 30 -> "dns-rate-warn"
      true -> "dns-rate-bad"
    end
  end

  defp fmt(n) when is_integer(n) and n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp fmt(n) when is_integer(n) and n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp fmt(n) when is_float(n), do: "#{Float.round(n, 1)}"
  defp fmt(n), do: "#{n}"

  defp fdur(ms) when is_number(ms) and ms >= 60_000, do: "#{Float.round(ms / 60_000, 1)}m"
  defp fdur(ms) when is_number(ms) and ms >= 1_000, do: "#{Float.round(ms / 1_000, 1)}s"
  defp fdur(ms) when is_number(ms), do: "#{ms}ms"
  defp fdur(_), do: "-"

  defp fmt_err_time(t) when is_binary(t) do
    case String.split(t, "T") do
      [_, rest] -> rest |> String.split(".") |> hd() |> String.slice(0, 8)
      _ -> String.slice(t, 0, 8)
    end
  end
  defp fmt_err_time(_), do: "-"

  defp badge_class(%{status: :unreachable}), do: "badge badge-red"
  defp badge_class(%{connected: false}), do: "badge badge-yellow"
  defp badge_class(_), do: "badge badge-green"
  defp badge_text(%{status: :unreachable}), do: "unreachable"
  defp badge_text(%{connected: false}), do: "reconnecting"
  defp badge_text(_), do: "connected"

  defp pcols("dns"), do: ~w(domain a mx txt web_score email_score)
  defp pcols("http"), do: ~w(domain status server tech title error)
  defp pcols("bgp"), do: ~w(domain ip asn org country)
  defp pcols("merged"), do: ~w(domain tld http_title http_tech bgp_asn_org dns_web http_status)
  defp pcols(_), do: ~w(domain)

  defp pcell(row, col) when is_map(row) do
    val = Map.get(row, col) || Map.get(row, String.to_atom(col)) || ppre(row, col)
    case val do
      nil -> "-"
      v when is_list(v) -> Enum.join(v, ", ")
      v when is_binary(v) -> v
      v -> "#{v}"
    end
  end
  defp pcell(_, _), do: "-"

  defp ppre(r, "a"), do: Map.get(r, :a) || Map.get(r, :dns_a)
  defp ppre(r, "mx"), do: Map.get(r, :mx) || Map.get(r, :dns_mx)
  defp ppre(r, "txt"), do: Map.get(r, :txt) || Map.get(r, :dns_txt)
  defp ppre(r, "web_score"), do: Map.get(r, :dns_web_scoring)
  defp ppre(r, "email_score"), do: Map.get(r, :dns_email_scoring)
  defp ppre(r, "status"), do: Map.get(r, :http_status)
  defp ppre(r, "server"), do: Map.get(r, :http_server)
  defp ppre(r, "tech"), do: Map.get(r, :http_tech)
  defp ppre(r, "title"), do: Map.get(r, :http_title)
  defp ppre(r, "error"), do: Map.get(r, :http_error)
  defp ppre(r, "ip"), do: Map.get(r, :bgp_ip)
  defp ppre(r, "asn"), do: Map.get(r, :bgp_asn_number)
  defp ppre(r, "org"), do: Map.get(r, :bgp_asn_org)
  defp ppre(r, "country"), do: Map.get(r, :bgp_asn_country)
  defp ppre(r, "tld"), do: Map.get(r, :ctl_tld)
  defp ppre(r, "http_title"), do: Map.get(r, :http_title)
  defp ppre(r, "http_tech"), do: Map.get(r, :http_tech)
  defp ppre(r, "dns_web"), do: Map.get(r, :dns_web_scoring)
  defp ppre(r, "http_status"), do: Map.get(r, :http_status)
  defp ppre(_, _), do: nil
end
