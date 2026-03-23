defmodule LSWeb.DashboardLive do
  @moduledoc """
  Real-time pipeline dashboard showing accurate data flow:
    CTL Poller -> Queue -> Workers -> ClickHouse

  Worker pipeline shows the actual execution model:
    DNS (sequential) -> fork[ HTTP | BGP | RDAP ] (parallel) -> Merge+Reputation -> Output
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

  @peek_stages %{"dns" => :dns, "http" => :http, "bgp" => :bgp, "rdap" => :rdap, "merged" => :merged}

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
      .header { display: flex; align-items: baseline; gap: 16px; margin-bottom: 24px; border-bottom: 1px solid #1a2235; padding-bottom: 16px; }
      .header h1 { font-family: 'JetBrains Mono', monospace; font-size: 20px; font-weight: 700; color: #e8edf4; letter-spacing: -0.5px; }
      .role-badge { font-family: 'JetBrains Mono', monospace; font-size: 11px; font-weight: 500; color: #38bdf8; background: rgba(56,189,248,0.08); border: 1px solid rgba(56,189,248,0.2); padding: 3px 10px; border-radius: 4px; text-transform: uppercase; letter-spacing: 1px; }
      .err-toggle { font-family: 'JetBrains Mono', monospace; font-size: 11px; color: #64748b; background: transparent; border: 1px solid #1e293b; border-radius: 4px; padding: 3px 10px; cursor: pointer; margin-left: auto; transition: all 0.15s; }
      .err-toggle:hover { border-color: #334155; color: #94a3b8; }
      .err-toggle.has-errors { color: #fbbf24; border-color: rgba(251,191,36,0.3); }
      .section-label { font-family: 'JetBrains Mono', monospace; font-size: 10px; font-weight: 600; color: #4a5568; text-transform: uppercase; letter-spacing: 2px; margin-bottom: 12px; margin-top: 24px; }
      .alert-warn { background: rgba(251,191,36,0.06); border: 1px solid rgba(251,191,36,0.25); border-radius: 6px; padding: 10px 16px; margin-bottom: 20px; font-size: 13px; color: #fbbf24; }

      /* Health summary bar */
      .health-bar { margin-bottom: 20px; padding: 14px 20px; background: #111827; border: 1px solid #1e293b; border-radius: 8px; display: flex; align-items: center; gap: 20px; font-family: 'JetBrains Mono', monospace; font-size: 11px; flex-wrap: wrap; }
      .health-dot { width: 10px; height: 10px; border-radius: 50%; flex-shrink: 0; box-shadow: 0 0 6px currentColor; }
      .health-green { background: #4ade80; color: #4ade80; }
      .health-amber { background: #fbbf24; color: #fbbf24; }
      .health-red { background: #f87171; color: #f87171; }
      .health-label { color: #94a3b8; font-weight: 600; }
      .health-metrics { display: flex; gap: 16px; margin-left: auto; flex-wrap: wrap; }
      .hm { color: #4a5568; }
      .hm b { color: #94a3b8; font-weight: 600; }
      .hm-warn { color: #fbbf24; }

      /* Pipeline flow (master level) */
      .pipeline { display: flex; align-items: stretch; gap: 0; margin-bottom: 16px; }
      .stage { flex: 1; background: #111827; border: 1px solid #1e293b; border-radius: 8px; padding: 14px; min-width: 0; }
      .stage-name { font-family: 'JetBrains Mono', monospace; font-size: 10px; font-weight: 600; color: #64748b; text-transform: uppercase; letter-spacing: 1.5px; margin-bottom: 6px; }
      .stage-value { font-family: 'JetBrains Mono', monospace; font-size: 24px; font-weight: 700; color: #e2e8f0; line-height: 1.1; }
      .stage-unit { font-size: 12px; font-weight: 500; color: #64748b; }
      .stage-sub { font-family: 'JetBrains Mono', monospace; font-size: 10px; color: #4a5568; margin-top: 5px; line-height: 1.6; }
      .flow-arrow { display: flex; flex-direction: column; align-items: center; justify-content: center; padding: 0 4px; min-width: 50px; }
      .arrow-line { font-family: 'JetBrains Mono', monospace; font-size: 14px; color: #334155; letter-spacing: -2px; }
      .arrow-rate { font-family: 'JetBrains Mono', monospace; font-size: 9px; color: #38bdf8; white-space: nowrap; margin-top: 2px; }

      /* Reputation bar */
      .rep-bar { display: flex; gap: 12px; margin-bottom: 24px; flex-wrap: wrap; }
      .rep-chip { font-family: 'JetBrains Mono', monospace; font-size: 10px; padding: 5px 12px; background: #111827; border: 1px solid #1e293b; border-radius: 6px; color: #64748b; }
      .rep-chip b { color: #94a3b8; }
      .rep-chip .rep-ok { color: #4ade80; }
      .rep-chip .rep-warn { color: #fbbf24; }

      /* Worker cards */
      .worker-card { background: #111827; border: 1px solid #1e293b; border-radius: 8px; padding: 16px; margin-bottom: 12px; }
      .worker-header { display: flex; align-items: center; gap: 10px; margin-bottom: 14px; }
      .worker-name { font-family: 'JetBrains Mono', monospace; font-size: 13px; font-weight: 600; color: #e2e8f0; }
      .badge { font-family: 'JetBrains Mono', monospace; font-size: 10px; font-weight: 500; padding: 2px 8px; border-radius: 3px; text-transform: uppercase; letter-spacing: 0.5px; }
      .badge-green { color: #4ade80; background: rgba(74,222,128,0.08); border: 1px solid rgba(74,222,128,0.2); }
      .badge-yellow { color: #fbbf24; background: rgba(251,191,36,0.08); border: 1px solid rgba(251,191,36,0.2); }
      .badge-red { color: #f87171; background: rgba(248,113,113,0.08); border: 1px solid rgba(248,113,113,0.2); }
      .worker-batch-info { font-family: 'JetBrains Mono', monospace; font-size: 11px; color: #4a5568; margin-left: auto; }

      /* Worker pipeline — parallel fork/join layout */
      .wp { font-family: 'JetBrains Mono', monospace; }
      .wp-row { display: flex; align-items: stretch; gap: 0; }
      .wp-box { background: #0d1320; border: 1px solid #1a2235; border-radius: 6px; padding: 8px 10px; text-align: center; min-width: 0; }
      .wp-box-name { font-size: 9px; font-weight: 600; color: #4a5568; text-transform: uppercase; letter-spacing: 1.5px; margin-bottom: 3px; }
      .wp-box-val { font-size: 16px; font-weight: 700; color: #e2e8f0; }
      .wp-box-time { font-size: 9px; color: #64748b; margin-top: 1px; }
      .wp-box-detail { font-size: 8px; color: #374151; margin-top: 1px; }
      .wp-arr { display: flex; align-items: center; justify-content: center; padding: 0 3px; min-width: 20px; font-size: 12px; color: #1e293b; }

      /* Parallel group — vertical stack with bracket */
      .wp-parallel { display: flex; align-items: stretch; gap: 0; }
      .wp-bracket { width: 12px; display: flex; flex-direction: column; justify-content: center; }
      .wp-bracket-left { border-left: 2px solid #334155; border-top: 2px solid #334155; border-bottom: 2px solid #334155; border-radius: 4px 0 0 4px; }
      .wp-bracket-right { border-right: 2px solid #334155; border-top: 2px solid #334155; border-bottom: 2px solid #334155; border-radius: 0 4px 4px 0; }
      .wp-parallel-stack { display: flex; flex-direction: column; gap: 4px; padding: 4px 0; }
      .wp-parallel-stack .wp-box { flex: 1; min-height: 48px; display: flex; flex-direction: column; justify-content: center; }
      .wp-parallel-label { font-size: 8px; color: #334155; text-align: center; margin-bottom: 2px; letter-spacing: 1px; text-transform: uppercase; }

      .peek-btn { font-family: 'JetBrains Mono', monospace; font-size: 8px; font-weight: 500; color: #38bdf8; background: transparent; border: 1px solid rgba(56,189,248,0.15); border-radius: 3px; padding: 1px 5px; cursor: pointer; margin-top: 3px; text-transform: uppercase; letter-spacing: 0.5px; transition: all 0.15s; }
      .peek-btn:hover { background: rgba(56,189,248,0.08); border-color: rgba(56,189,248,0.35); }
      .no-workers { font-family: 'JetBrains Mono', monospace; font-size: 12px; color: #374151; padding: 24px; text-align: center; background: #111827; border: 1px dashed #1e293b; border-radius: 8px; }

      /* Peek panel */
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

      /* Error panel */
      .error-panel { background: #111827; border: 1px solid #1e293b; border-radius: 8px; padding: 16px; margin-bottom: 24px; }
      .error-row { display: flex; gap: 12px; padding: 5px 0; border-bottom: 1px solid #0f1729; font-family: 'JetBrains Mono', monospace; font-size: 11px; }
      .error-time { color: #374151; min-width: 80px; flex-shrink: 0; }
      .error-node { color: #64748b; min-width: 160px; flex-shrink: 0; }
      .error-stage { min-width: 70px; flex-shrink: 0; padding: 1px 6px; border-radius: 3px; text-align: center; font-size: 9px; text-transform: uppercase; letter-spacing: 0.5px; }
      .error-stage-dns { color: #38bdf8; background: rgba(56,189,248,0.08); }
      .error-stage-http { color: #a78bfa; background: rgba(167,139,250,0.08); }
      .error-stage-bgp { color: #fbbf24; background: rgba(251,191,36,0.08); }
      .error-stage-rdap { color: #fb923c; background: rgba(251,146,60,0.08); }
      .error-stage-connection { color: #f87171; background: rgba(248,113,113,0.08); }
      .error-msg { color: #94a3b8; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .error-empty { font-family: 'JetBrains Mono', monospace; font-size: 11px; color: #374151; padding: 12px; text-align: center; }
      .text-red { color: #f87171; }
      .dns-rate { font-size: 8px; margin-top: 1px; }
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

      <%!-- HEALTH SUMMARY --%>
      <% {health_color, health_msg, workers_needed} = pipeline_health(@master_stats) %>
      <div class="health-bar">
        <span class={"health-dot " <> health_color}></span>
        <span class="health-label">{health_msg}</span>
        <div class="health-metrics">
          <span class="hm">in <b>{pr(@master_stats.poller)}/s</b></span>
          <span class="hm">out <b>{fmt_rate(qv(@master_stats.queue, :drain_rate_per_min))}/s</b></span>
          <span class="hm">ratio <b>{capacity_ratio(@master_stats)}</b></span>
          <span class="hm">workers <b>{length(@worker_stats)}</b></span>
          <span class="hm">CH err <b class={if(iv(@master_stats.inserter, :total_errors) > 0, do: "hm-warn", else: "")}>{iv(@master_stats.inserter, :total_errors)}</b></span>
          <%= if workers_needed > length(@worker_stats) do %>
            <span class="hm hm-warn">need ~{workers_needed}</span>
          <% end %>
        </div>
      </div>

      <%!-- ERRORS --%>
      <%= if @show_errors do %>
        <div class="error-panel">
          <div class="section-label" style="margin: 0 0 8px 0;">Recent Errors (all nodes)</div>
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

      <%!-- MASTER PIPELINE --%>
      <div class="section-label" style="margin-top: 0;">Pipeline Flow</div>
      <div class="pipeline">
        <div class="stage">
          <div class="stage-name">CTL Poller</div>
          <div class="stage-value">{pr(@master_stats.poller)}<span class="stage-unit">/s</span></div>
          <div class="stage-sub">{plc(@master_stats.poller)} logs active<br/>{fmt(@master_stats.cache.ctl.entries)} seen · {@master_stats.cache.ctl.memory_mb} MB</div>
        </div>
        <div class="flow-arrow"><span class="arrow-line">———→</span><span class="arrow-rate">{pr(@master_stats.poller)}/s</span></div>
        <div class="stage">
          <div class="stage-name">Queue</div>
          <div class="stage-value">{fmt(qv(@master_stats.queue, :queue_depth))}</div>
          <div class="stage-sub">{qv(@master_stats.queue, :queue_pct)}% full<br/>{fmt(qv(@master_stats.queue, :total_completed))} done · {fmt(qv(@master_stats.queue, :total_requeued))} retry</div>
        </div>
        <div class="flow-arrow"><span class="arrow-line">———→</span><span class="arrow-rate">{qv(@master_stats.queue, :drain_rate_per_min)}/m</span></div>
        <div class="stage">
          <div class="stage-name">Workers</div>
          <div class="stage-value">{length(@worker_stats)}</div>
          <div class="stage-sub">{qv(@master_stats.queue, :drain_rate_per_min)}/m drain<br/>{qv(@master_stats.queue, :inflight_batches)} in-flight</div>
        </div>
        <div class="flow-arrow"><span class="arrow-line">———→</span><span class="arrow-rate">{iv(@master_stats.inserter, :insert_rate_per_min)}/m</span></div>
        <div class="stage">
          <div class="stage-name">ClickHouse</div>
          <div class="stage-value">{iv(@master_stats.inserter, :insert_rate_per_min)}<span class="stage-unit">/m</span></div>
          <div class="stage-sub">buf {iv(@master_stats.inserter, :buffer_size)}<br/>err <span class={if(iv(@master_stats.inserter, :total_errors) > 0, do: "text-red", else: "")}>{iv(@master_stats.inserter, :total_errors)}</span></div>
        </div>
      </div>

      <%!-- REPUTATION DATA SOURCES --%>
      <div class="rep-bar">
        <div class="rep-chip">Tranco <b class="rep-ok">{fmt(rep_val(@master_stats, :tranco))}</b></div>
        <div class="rep-chip">Majestic <b class="rep-ok">{fmt(rep_val(@master_stats, :majestic))}</b></div>
        <div class="rep-chip">Blocklist <b class={if(rep_val(@master_stats, :blocklist) > 0, do: "rep-ok", else: "rep-warn")}>{fmt(rep_val(@master_stats, :blocklist))}</b></div>
        <div class="rep-chip">RDAP cache <b>{fmt(@master_stats.cache.rdap.entries)}</b> · {@master_stats.cache.rdap.memory_mb} MB</div>
      </div>

      <%!-- WORKER NODES --%>
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
                <%= if (ec = Map.get(ws, :error_count, 0)) > 0 do %> · <span class="text-red">{ec} err</span><% end %>
              </span>
            </div>
            <%= if stages = Map.get(ws, :last_stages) do %>
              <%!-- WORKER PIPELINE: DNS → fork[ HTTP | BGP | RDAP ] → Merge+Rep → Output --%>
              <div class="wp">
                <div class="wp-row">
                  <%!-- INPUT --%>
                  <div class="wp-box" style="flex: 0 0 60px;">
                    <div class="wp-box-name">Input</div>
                    <div class="wp-box-val">{Map.get(stages.dns, :input, 0)}</div>
                  </div>
                  <div class="wp-arr">→</div>

                  <%!-- DNS (sequential) --%>
                  <div class="wp-box" style="flex: 0 0 90px;">
                    <div class="wp-box-name">DNS</div>
                    <div class="wp-box-val">{Map.get(stages.dns, :output, 0)}</div>
                    <div class="wp-box-time">{fdur(Map.get(stages.dns, :ms, 0))}</div>
                    <div class={"wp-box-detail dns-rate " <> dns_rate_class(stages.dns)}>{dns_pct(stages.dns)}% resolved</div>
                    <button class="peek-btn" phx-click="peek" phx-value-worker={node_name} phx-value-stage="dns">peek</button>
                  </div>
                  <div class="wp-arr">→</div>

                  <%!-- PARALLEL: HTTP + BGP + RDAP --%>
                  <div class="wp-parallel">
                    <div class="wp-bracket wp-bracket-left"></div>
                    <div class="wp-parallel-stack">
                      <div class="wp-parallel-label">parallel</div>
                      <div class="wp-box">
                        <div class="wp-box-name">HTTP</div>
                        <div class="wp-box-val">{Map.get(stages.http, :output, 0)}</div>
                        <div class="wp-box-time">{fdur(Map.get(stages.http, :ms, 0))}</div>
                        <div class="wp-box-detail">{Map.get(stages.http, :input, 0)} in · {Map.get(stages.http, :filtered, 0)} skip</div>
                        <button class="peek-btn" phx-click="peek" phx-value-worker={node_name} phx-value-stage="http">peek</button>
                      </div>
                      <div class="wp-box">
                        <div class="wp-box-name">BGP</div>
                        <div class="wp-box-val">{Map.get(stages.bgp, :output, 0)}</div>
                        <div class="wp-box-time">{fdur(Map.get(stages.bgp, :ms, 0))}</div>
                        <div class="wp-box-detail">{Map.get(stages.bgp, :input, 0)} IPs</div>
                        <button class="peek-btn" phx-click="peek" phx-value-worker={node_name} phx-value-stage="bgp">peek</button>
                      </div>
                      <div class="wp-box">
                        <div class="wp-box-name">RDAP</div>
                        <div class="wp-box-val">{get_in(stages, [:rdap, :output]) || 0}</div>
                        <div class="wp-box-time">{fdur(get_in(stages, [:rdap, :ms]) || 0)}</div>
                        <div class="wp-box-detail">{get_in(stages, [:rdap, :input]) || 0} in · {get_in(stages, [:rdap, :rate_limited]) || 0} rl</div>
                        <button class="peek-btn" phx-click="peek" phx-value-worker={node_name} phx-value-stage="rdap">peek</button>
                      </div>
                    </div>
                    <div class="wp-bracket wp-bracket-right"></div>
                  </div>
                  <div class="wp-arr">→</div>

                  <%!-- MERGE + REPUTATION --%>
                  <div class="wp-box" style="flex: 0 0 90px;">
                    <div class="wp-box-name">Merge</div>
                    <div class="wp-box-val">{stages.total}</div>
                    <div class="wp-box-detail">+ reputation</div>
                  </div>
                  <div class="wp-arr">→</div>

                  <%!-- OUTPUT --%>
                  <div class="wp-box" style="flex: 0 0 60px;">
                    <div class="wp-box-name">Output</div>
                    <div class="wp-box-val">{stages.total}</div>
                    <div class="wp-box-detail">rows</div>
                    <button class="peek-btn" phx-click="peek" phx-value-worker={node_name} phx-value-stage="merged">peek</button>
                  </div>
                </div>
              </div>
            <% else %>
              <div style="padding: 12px; color: #374151; font-family: 'JetBrains Mono', monospace; font-size: 11px;">Waiting for first batch...</div>
            <% end %>
          </div>
        <% end %>
      <% end %>

      <%!-- PEEK PANEL --%>
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

  # ==========================================================================
  # DATA COLLECTION
  # ==========================================================================

  defp collect_master_stats do
    queue = sc(LS.Cluster.WorkQueue, :stats)
    inserter = sc(LS.Cluster.Inserter, :stats)
    poller = sc(LS.CTL.Poller, :stats)
    cache = try do LS.Cache.stats() rescue _ -> dc() catch :exit, _ -> dc() end
    tranco = sc(LS.Reputation.Tranco, :stats)
    majestic = sc(LS.Reputation.Majestic, :stats)
    blocklist = sc(LS.Reputation.Blocklist, :stats)
    %{queue: queue, inserter: inserter, poller: poller, cache: cache,
      tranco: tranco, majestic: majestic, blocklist: blocklist}
  end

  defp collect_worker_stats do
    Node.list()
    |> Enum.map(fn node ->
      raw = try do
        GenServer.call({LS.Cluster.WorkerAgent, node}, :detailed_stats, 5_000)
      catch
        :exit, _ ->
          try do GenServer.call({LS.Cluster.WorkerAgent, node}, :stats, 5_000)
          catch :exit, _ -> %{status: :unreachable} end
      end
      stats = case raw do
        %{stats: s} -> Map.merge(s, Map.take(raw, [:samples, :errors, :last_stages]))
        other -> other
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

  # ==========================================================================
  # HELPERS
  # ==========================================================================

  defp sc(mod, msg), do: (try do GenServer.call(mod, msg, 5_000) rescue _ -> nil catch :exit, _ -> nil end)
  defp dc, do: %{ctl: %{entries: 0, memory_mb: 0, usage_pct: 0}, http: %{entries: 0, memory_mb: 0}, bgp: %{entries: 0, memory_mb: 0}, rdap: %{entries: 0, memory_mb: 0}}

  defp qv(nil, _), do: 0
  defp qv(q, k), do: Map.get(q, k, 0)
  defp iv(nil, _), do: 0
  defp iv(i, k), do: Map.get(i, k, 0)
  defp pr(nil), do: "0"
  defp pr(p), do: "#{Map.get(p, :domains_per_sec, 0)}"
  defp plc(nil), do: 0
  defp plc(p), do: Map.get(p, :active_logs, 0)

  defp rep_val(ms, :tranco), do: get_in(ms, [:tranco, :domains_loaded]) || 0
  defp rep_val(ms, :majestic), do: get_in(ms, [:majestic, :domains_loaded]) || 0
  defp rep_val(ms, :blocklist), do: get_in(ms, [:blocklist, :total]) || 0

  defp pipeline_health(ms) do
    inflow = case ms.poller do nil -> 0; p -> Map.get(p, :domains_per_sec, 0) end
    drain = qv(ms.queue, :drain_rate_per_min) / 60.0
    wc = length(Node.list())
    cond do
      inflow == 0 -> {"health-green", "No CTL inflow", 0}
      drain == 0 and wc == 0 -> {"health-red", "No workers — queue growing", 1}
      drain == 0 -> {"health-red", "Workers not draining", max(wc, 1)}
      true ->
        ratio = drain / inflow
        per_w = if wc > 0, do: drain / wc, else: drain
        needed = if per_w > 0, do: ceil(inflow / per_w), else: 99
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
  defp pcols("http"), do: ~w(domain status tech http_apps title error)
  defp pcols("bgp"), do: ~w(domain ip asn org country)
  defp pcols("rdap"), do: ~w(domain registrar domain_created_at nameservers status rdap_age_scoring rdap_registrar_scoring)
  defp pcols("merged"), do: ~w(domain tld http_title http_tech bgp_asn_org tranco_rank majestic_ref_subnets dns_web http_status)
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
  defp ppre(r, "tranco_rank"), do: Map.get(r, :tranco_rank)
  defp ppre(r, "majestic_ref_subnets"), do: Map.get(r, :majestic_ref_subnets)
  defp ppre(r, "registrar"), do: Map.get(r, :registrar) || Map.get(r, :rdap_registrar)
  defp ppre(r, "domain_created_at"), do: Map.get(r, :domain_created_at) || Map.get(r, :rdap_domain_created_at)
  defp ppre(r, "nameservers"), do: Map.get(r, :nameservers) || Map.get(r, :rdap_nameservers)
  defp ppre(r, "rdap_age_scoring"), do: Map.get(r, :rdap_age_scoring)
  defp ppre(r, "rdap_registrar_scoring"), do: Map.get(r, :rdap_registrar_scoring)
  defp ppre(_, _), do: nil
end
