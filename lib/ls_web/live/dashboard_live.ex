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
    # Mount assigns only what is LOCAL and fast (master processes + one CH
    # query). Everything that talks to other nodes is gathered by an async
    # task (see :refresh): the per-node GenServer.calls carry 2-5s timeouts
    # each, and doing them inline kept this LiveView process busy for
    # seconds per cycle — clicks sat in the mailbox and the tabs felt dead.
    if connected?(socket), do: send(self(), :refresh)

    {:ok,
     assign(socket,
       role: System.get_env("LS_ROLE", "standalone"),
       master_stats: collect_master_stats(),
       worker_stats: [],
       trend: %{status: :insufficient_data},
       worker_health: [],
       worker_caches: [],
       all_errors: [],
       tab: "discovery",
       enrichment_stats: %{queue: nil, compactor: nil, agents: [], output: %{}},
       verification_stats: nil,
       table_counts: collect_table_counts(),
       node_resources: [],
       peek: nil, peek_data: nil, show_errors: false
     )}
  end

  @impl true
  def handle_info(:refresh, socket) do
    parent = self()
    show_errors = socket.assigns.show_errors

    # The gather runs OFF the LiveView process so events stay instant. The
    # next cycle is scheduled from :refresh_result, never here — a slow
    # gather therefore stretches the interval instead of piling up.
    Task.start(fn ->
      stats =
        try do
          [
            master_stats: collect_master_stats(),
            worker_stats: collect_worker_stats(),
            trend: LS.Cluster.QueueTrend.analysis(length(Node.list())),
            worker_health: collect_worker_health(),
            worker_caches: collect_worker_caches(),
            enrichment_stats: collect_enrichment_stats(),
            verification_stats: collect_verification_stats(),
            table_counts: collect_table_counts(),
            node_resources: collect_node_resources()
          ] ++ if(show_errors, do: [all_errors: collect_all_errors()], else: [])
        rescue
          _ -> []
        catch
          :exit, _ -> []
        end

      send(parent, {:refresh_result, stats})
    end)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:refresh_result, stats}, socket) do
    Process.send_after(self(), :refresh, @refresh_interval)
    {:noreply, assign(socket, stats)}
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
  def handle_event("tab", %{"tab" => tab}, socket) when tab in ["discovery", "enrichment", "verification"] do
    {:noreply, assign(socket, tab: tab)}
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
      .tabs { display: flex; gap: 4px; margin-left: 20px; }
      .tab { font-family: 'JetBrains Mono', monospace; font-size: 11px; font-weight: 500; color: #64748b;
             background: transparent; border: 1px solid #1e293b; border-radius: 4px; padding: 4px 14px;
             cursor: pointer; text-transform: uppercase; letter-spacing: 1px; transition: all 0.15s; }
      .tab:hover { border-color: #334155; color: #94a3b8; }
      .tab.on { color: #38bdf8; border-color: rgba(56,189,248,0.4); background: rgba(56,189,248,0.08); }
      .res { display: flex; gap: 14px; flex-wrap: wrap; margin-bottom: 18px; }
      .res-node { font-family: 'JetBrains Mono', monospace; font-size: 11px; color: #94a3b8;
                  border: 1px solid #1a2235; border-radius: 4px; padding: 6px 12px; background: #0d1320; }
      .res-node b { color: #e8edf4; font-weight: 600; }
      .res-node .hot { color: #f59e0b; }
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
      .stage-input { border: 1px solid #10b981 !important; box-shadow: 0 0 0 1px #10b981, 0 0 14px rgba(16,185,129,0.25); background: rgba(16,185,129,0.06) !important; }
      .hm-dim { opacity: 0.5; }
      .hm-ok { color: #34d399; }
      .worker-cache { font-family: 'JetBrains Mono', monospace; font-size: 10.5px; color: #64748b; margin: 2px 0 8px 0; }
      .worker-cache b { color: #94a3b8; font-weight: 600; }
      .worker-card { background: #111827; border: 1px solid #1e293b; border-radius: 8px; padding: 16px; margin-bottom: 12px; }
      .worker-card-danger { border: 2px solid #dc2626; background: #1c0f12; box-shadow: 0 0 0 1px #dc2626, 0 0 18px rgba(220,38,38,.35); }
      .worker-card-warn { border: 2px solid #d97706; background: #1a1408; }
      .health-banner { font-family: 'JetBrains Mono', monospace; font-size: 12px; font-weight: 700; padding: 8px 12px; border-radius: 6px; margin-bottom: 12px; }
      .health-banner-danger { background: #dc2626; color: #fff; }
      .health-banner-warn { background: #d97706; color: #fff; }
      .health-chip { font-family: 'JetBrains Mono', monospace; font-size: 10px; padding: 2px 8px; border-radius: 9999px; font-weight: 700; }
      .health-chip-ok { background: #052e16; color: #4ade80; }
      .health-chip-warn { background: #451a03; color: #fbbf24; }
      .health-chip-danger { background: #dc2626; color: #fff; animation: pulse-red 1.2s infinite; }
      @keyframes pulse-red { 0%,100% { opacity: 1; } 50% { opacity: .55; } }
      .alert-danger { background: #dc2626; color: #fff; font-family: 'JetBrains Mono', monospace; font-size: 13px; font-weight: 700; padding: 10px 14px; border-radius: 8px; margin-bottom: 12px; }
      .worker-header { display: flex; align-items: center; gap: 10px; margin-bottom: 14px; }
      .worker-name { font-family: 'JetBrains Mono', monospace; font-size: 13px; font-weight: 600; color: #e2e8f0; }
      .badge { font-family: 'JetBrains Mono', monospace; font-size: 10px; font-weight: 500; padding: 2px 8px; border-radius: 3px; text-transform: uppercase; letter-spacing: 0.5px; }
      .badge-green { color: #4ade80; background: rgba(74,222,128,0.08); border: 1px solid rgba(74,222,128,0.2); }
      .badge-yellow { color: #fbbf24; background: rgba(251,191,36,0.08); border: 1px solid rgba(251,191,36,0.2); }
      .badge-red { color: #f87171; background: rgba(248,113,113,0.08); border: 1px solid rgba(248,113,113,0.2); }
      .worker-batch-info { font-family: 'JetBrains Mono', monospace; font-size: 11px; color: #4a5568; margin-left: auto; }

      /* Worker pipeline, parallel fork/join layout */
      .wp { font-family: 'JetBrains Mono', monospace; }
      .wp-row { display: flex; align-items: stretch; gap: 0; }
      .wp-box { background: #0d1320; border: 1px solid #1a2235; border-radius: 6px; padding: 8px 10px; text-align: center; min-width: 0; }
      .wp-box-name { font-size: 9px; font-weight: 600; color: #4a5568; text-transform: uppercase; letter-spacing: 1.5px; margin-bottom: 3px; }
      .wp-box-val { font-size: 16px; font-weight: 700; color: #e2e8f0; }
      .wp-box-time { font-size: 9px; color: #64748b; margin-top: 1px; }
      .wp-box-detail { font-size: 8px; color: #374151; margin-top: 1px; }
      .wp-arr { display: flex; align-items: center; justify-content: center; padding: 0 3px; min-width: 20px; font-size: 12px; color: #1e293b; }

      /* Parallel group, vertical stack with bracket */
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
        <div class="tabs">
          <button class={"tab" <> if(@tab == "discovery", do: " on", else: "")}
                  phx-click="tab" phx-value-tab="discovery">1 · Discovery</button>
          <button class={"tab" <> if(@tab == "enrichment", do: " on", else: "")}
                  phx-click="tab" phx-value-tab="enrichment">2 · Enrichment</button>
          <button class={"tab" <> if(@tab == "verification", do: " on", else: "")}
                  phx-click="tab" phx-value-tab="verification">3 · Verification</button>
        </div>
        <button class={"err-toggle" <> if(length(@all_errors) > 0, do: " has-errors", else: "")} phx-click="toggle_errors">
          <%= if @show_errors do %>✕ hide errors<% else %>{length(@all_errors)} errors<% end %>
        </button>
      </div>

      <%!-- END-TABLE TOTALS, the two numbers that say how big the product is --%>
      <% tc = @table_counts %>
      <div class="res">
        <div class="res-node" title="Rows in domains_current: one row per domain discovered by pipeline 1.">
          <b>domains</b>&nbsp; {fmt(Map.get(tc, :domains, 0))}
          <span style="color:#4a5568">· {fmt(Map.get(tc, :domain_rows, 0))} crawl rows</span>
        </div>
        <div class="res-node" title="Rows in businesses: the compiled product table, one row per real business.">
          <b>businesses</b>&nbsp; {fmt(Map.get(tc, :businesses, 0))}
          <span style="color:#4a5568">· {fmt(Map.get(tc, :businesses_enriched, 0))} deep-enriched</span>
        </div>
      </div>

      <%!-- NODE RESOURCES, live, from /proc on each node (sar is for history) --%>
      <div class="res">
        <%= for {node, r} <- @node_resources do %>
          <div class="res-node">
            <b>{short_node(node)}</b>
            &nbsp;cpu <span class={load_class(r)}>{fmt_load(r)}</span>/{r.cores}c
            <%= if r.mem.used_pct do %>
              &nbsp;· ram <span class={mem_class(r)}>{r.mem.used_pct}%</span>
              ({r.mem.avail_mb}MB free)
            <% end %>
            &nbsp;· beam {r.beam_mb}MB
          </div>
        <% end %>
      </div>

      <%= if @tab == "discovery" do %>
      <%= if @master_stats.queue && @master_stats.queue.queue_pct >= 80.0 do %>
        <div class="alert-warn">⚠ Queue at {@master_stats.queue.queue_pct}%, add workers</div>
      <% end %>
      <% quarantined = Enum.filter(@worker_health, fn {_, h} -> h.quarantined end) %>
      <% missing = missing_workers(@worker_health, @worker_stats) %>
      <%= if quarantined != [] do %>
        <div class="alert-danger">⛔ {length(quarantined)} WORKER(S) QUARANTINED, hollow rows being dropped: {Enum.map_join(quarantined, ", ", &elem(&1, 0))}. Fix the node, then Inserter.release_worker/1.</div>
      <% end %>
      <%= if missing != [] do %>
        <div class="alert-danger">⛔ {length(missing)} WORKER(S) DISAPPEARED from the cluster: {Enum.map_join(missing, ", ", &elem(&1, 0))}</div>
      <% end %>

      <%!-- HEALTH SUMMARY --%>
      <% {health_color, health_msg} = pipeline_health(@master_stats, @trend) %>
      <div class="health-bar">
        <span class={"health-dot " <> health_color}></span>
        <span class="health-label">{health_msg}</span>
        <div class="health-metrics">
          <span class="hm hm-dim">CTL {ctl_per_min(@master_stats)}/m</span>
          <span class="hm">input <b>{rate(@master_stats.queue, :enqueue_rate_per_min)}/m</b></span>
          <span class="hm">drain <b>{rate(@master_stats.queue, :drain_rate_per_min)}/m</b></span>
          <span class="hm">workers <b>{length(@worker_stats)}</b></span>
          <span class="hm">CH err <b class={if(iv(@master_stats.inserter, :total_errors) > 0, do: "hm-warn", else: "")}>{iv(@master_stats.inserter, :total_errors)}</b></span>
          <span class={"hm " <> staffing_class(@trend)}>{staffing_label(@trend)}</span>
        </div>
      </div>

      <%!-- STAFFING: measured over an hour, not one bursty sample. --%>
      <div class="health-bar health-sub">
        <span class="health-label">Staffing ({trend_window(@trend)})</span>
        <div class="health-metrics">
          <span class="hm">demand <b>{trend_v(@trend, :demand_per_min)}/m</b></span>
          <span class="hm">drain <b>{trend_v(@trend, :drain_per_min)}/m</b></span>
          <span class="hm">fleet capacity <b>{trend_v(@trend, :capacity_per_min)}/m</b></span>
          <span class="hm hm-dim">per worker <b>{trend_v(@trend, :per_worker_per_min)}/m</b></span>
          <span class="hm">backlog <b>{trend_v(@trend, :depth)}</b> ({trend_slope(@trend)})</span>
          <span class="hm">buffer <b>{runway_label(@trend)}</b></span>
        </div>
      </div>

      <%!-- ERRORS --%>
      <%= if @show_errors do %>
        <div class="error-panel">
          <div class="section-label" style="margin: 0 0 8px 0;">Recent Errors (all nodes)</div>
          <%= if @all_errors == [] do %>
            <div class="error-empty">No errors, pipeline running clean</div>
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
          <div class="stage-value">{ctl_per_min(@master_stats)}<span class="stage-unit">/m</span></div>
          <div class="stage-sub">{plc(@master_stats.poller)} logs active<br/>passes filter · incl. duplicate certs</div>
        </div>
        <div class="flow-arrow"><span class="arrow-line">---&gt;</span><span class="arrow-rate">dedup</span></div>
        <div class="stage stage-input">
          <div class="stage-name">Enqueued ★ real input</div>
          <div class="stage-value">{rate(@master_stats.queue, :enqueue_rate_per_min)}<span class="stage-unit">/m</span></div>
          <div class="stage-sub">new domains only<br/>queue {fmt(qv(@master_stats.queue, :queue_depth))} · {qv(@master_stats.queue, :queue_pct)}% full</div>
        </div>
        <div class="flow-arrow"><span class="arrow-line">---&gt;</span><span class="arrow-rate">{rate(@master_stats.queue, :drain_rate_per_min)}/m</span></div>
        <div class="stage">
          <div class="stage-name">Workers</div>
          <div class="stage-value">{rate(@master_stats.queue, :drain_rate_per_min)}<span class="stage-unit">/m</span></div>
          <div class="stage-sub">{length(@worker_stats)} nodes · {qv(@master_stats.queue, :inflight_batches)} in-flight<br/>{fmt(qv(@master_stats.queue, :total_completed))} done · {fmt(qv(@master_stats.queue, :total_requeued))} retry</div>
        </div>
        <div class="flow-arrow"><span class="arrow-line">---&gt;</span><span class="arrow-rate">{iv(@master_stats.inserter, :insert_rate_per_min)}/m</span></div>
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
      </div>

      <%!-- WORKER NODES --%>
      <div class="section-label">Worker Nodes</div>
      <%= for {name, h} <- missing_workers(@worker_health, @worker_stats) do %>
        <div class="worker-card worker-card-danger">
          <div class="health-banner health-banner-danger">⛔ NOT CONNECTED, {name} produced rows this session (quality {if h.ratio, do: Float.round(h.ratio * 100, 1)}%) but has left the cluster. Check the node: systemctl status listsignal@worker.</div>
        </div>
      <% end %>
      <%= if @worker_stats == [] do %>
        <div class="no-workers">No workers connected</div>
      <% else %>
        <%= for {node_name, ws} <- @worker_stats do %>
          <% wh = health_for(@worker_health, node_name) %>
          <% conn_bad = Map.get(ws, :status) == :unreachable or Map.get(ws, :connected) == false %>
          <% sev = if conn_bad, do: :danger, else: health_severity(wh) %>
          <div class={health_card_class(sev)}>
            <%= if conn_bad do %>
              <div class="health-banner health-banner-danger">⛔ NOT PRODUCING, agent is {if Map.get(ws, :status) == :unreachable, do: "unreachable", else: "stuck reconnecting"}. If this persists, the WorkerAgent is likely crash-looping (a stage overrunning its budget): journalctl -u listsignal@worker on the node.</div>
            <% end %>
            <%= if sev == :danger and not conn_bad do %>
              <div class="health-banner health-banner-danger">⛔ QUARANTINED, this node's rows are being DROPPED ({wh.dropped} so far). Enrichment-beyond-DNS ratio {if wh.ratio, do: Float.round(wh.ratio * 100, 1)}% (min 90%). Fix the node, then LS.Cluster.Inserter.release_worker("{node_name}").</div>
            <% end %>
            <%= if sev == :warn do %>
              <div class="health-banner health-banner-warn">⚠ AT RISK, enrichment-beyond-DNS ratio {if wh.ratio, do: Float.round(wh.ratio * 100, 1)}% (quarantine trips below 90%)</div>
            <% end %>
            <div class="worker-header">
              <span class="worker-name">{node_name}</span>
              <span class={badge_class(ws)}>{badge_text(ws)}</span>
              <%= case sev do %>
                <% :danger -> %><span class="health-chip health-chip-danger">DATA QUALITY FAIL</span>
                <% :warn -> %><span class="health-chip health-chip-warn" title="% of this node's DNS-resolved domains that ALSO got HTTP/BGP/RDAP data. Below 90% the node is quarantined (it is producing hollow rows). 100% = every resolvable domain fully enriched.">enriched {if wh && wh.ratio, do: Float.round(wh.ratio * 100, 1)}%</span>
                <% :ok -> %><%= if wh && wh.ratio do %><span class="health-chip health-chip-ok" title="% of this node's DNS-resolved domains that ALSO got HTTP/BGP/RDAP data. Below 90% the node is quarantined (it is producing hollow rows). 100% = every resolvable domain fully enriched.">enriched {Float.round(wh.ratio * 100, 1)}%</span><% end %>
              <% end %>
              <span class="worker-batch-info">
                {Map.get(ws, :total_batches, 0)} batches · {fmt(Map.get(ws, :total_enriched, 0))} enriched · {Map.get(ws, :domains_per_sec, 0)}/s
                <%= if (ec = Map.get(ws, :error_count, 0)) > 0 do %> · <span class="text-red">{ec} err</span><% end %>
              </span>
            </div>
            <% wc = worker_cache(@worker_caches, node_name) %>
            <%= if wc do %>
              <div class="worker-cache" title="Per-node ETS cache: hit-rate · #entries. 'empty' = cold after a restart; a rising hit-rate means we reuse lookups instead of re-fetching. BGP caches inside its resolver; DNS is cached by Unbound.">
                cache&nbsp; RDAP <b>{cache_cell(wc, :rdap)}</b> · HTTP <b>{cache_cell(wc, :http)}</b>
              </div>
            <% end %>
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
      <% end %>

      <%!-- ══════════════ PIPELINE 2 · ENRICHMENT ══════════════ --%>
      <%= if @tab == "enrichment" do %>
        <% o = @enrichment_stats.output %>
        <% eq = @enrichment_stats.queue %>
        <% ec = @enrichment_stats.compactor %>
        <% agents = @enrichment_stats.agents %>

        <%= if agents == [] do %>
          <div class="alert-danger">⛔ No enrichment lane running, start one with <b>make dev-enrichment</b> (or LS_LANES=enrichment on a node)</div>
        <% end %>

        <%!-- HEALTH SUMMARY --%>
        <% epm = Map.get(o, :per_min, 0) %>
        <div class="health-bar">
          <span class={"health-dot " <> cond do
            agents == [] -> "health-red"
            epm > 0 -> "health-green"
            true -> "health-amber"
          end}></span>
          <span class="health-label">
            <%= cond do %>
              <% agents == [] -> %>No enrichment agent connected
              <% epm > 0 -> %>Enriching {epm} domains/min across {length(agents)} node(s)
              <% true -> %>Agent connected but idle, queue {(eq && eq.queue_depth) || 0}
            <% end %>
          </span>
          <div class="health-metrics">
            <span class="hm hm-dim">{fmt(Map.get(o, :last_hour, 0))}/hr</span>
            <span class="hm hm-dim">{fmt(Map.get(o, :enriched, 0))} enriched</span>
            <span class="hm hm-dim">{fmt(Map.get(o, :businesses_enriched, 0))}/{fmt(Map.get(o, :businesses, 0))} businesses</span>
          </div>
        </div>

        <%!-- PIPELINE FLOW: businesses → queue → agents → biz_* → businesses --%>
        <div class="section-label" style="margin-top: 0;">Pipeline Flow</div>
        <div class="pipeline">
          <div class="stage">
            <div class="stage-name">Source</div>
            <div class="stage-value">{fmt(Map.get(o, :businesses, 0))}</div>
            <div class="stage-sub">businesses table<br/>{fmt(Map.get(o, :businesses_enriched, 0))} already deep-enriched</div>
          </div>
          <div class="flow-arrow"><span class="arrow-line">---&gt;</span><span class="arrow-rate">stale&gt;30d</span></div>
          <div class="stage stage-input">
            <div class="stage-name">Queue ★ real input</div>
            <div class="stage-value">{fmt((eq && eq.queue_depth) || 0)}</div>
            <div class="stage-sub">{(eq && eq.refills) || 0} refills · {(eq && eq.inflight_batches) || 0} in-flight<br/>best Tranco first</div>
          </div>
          <div class="flow-arrow"><span class="arrow-line">---&gt;</span><span class="arrow-rate">{epm}/m</span></div>
          <div class="stage">
            <div class="stage-name">Agents</div>
            <div class="stage-value">{epm}<span class="stage-unit">/m</span></div>
            <div class="stage-sub">{length(agents)} node(s) · max 3 browsers<br/>{fmt((eq && eq.completed) || 0)} completed</div>
          </div>
          <div class="flow-arrow"><span class="arrow-line">---&gt;</span><span class="arrow-rate">biz_*</span></div>
          <div class="stage">
            <div class="stage-name">Compactor</div>
            <div class="stage-value">{(ec && ec.passes) || 0}<span class="stage-unit"> passes</span></div>
            <div class="stage-sub">{fmt((ec && ec.domains) || 0)} folded<br/>last {(ec && ec.last_ms && "#{ec.last_ms}ms") || "-"} · every 5m</div>
          </div>
        </div>

        <%!-- WHAT IT PRODUCED --%>
        <div class="rep-bar">
          <div class="rep-chip">Contacts <b class={if(Map.get(o, :contacts, 0) > 0, do: "rep-ok", else: "rep-warn")}>{fmt(Map.get(o, :contacts, 0))}</b></div>
          <div class="rep-chip">Pricing <b class={if(Map.get(o, :pricing, 0) > 0, do: "rep-ok", else: "rep-warn")}>{fmt(Map.get(o, :pricing, 0))}</b></div>
          <div class="rep-chip">Jobs <b class={if(Map.get(o, :jobs, 0) > 0, do: "rep-ok", else: "rep-warn")}>{fmt(Map.get(o, :jobs, 0))}</b></div>
          <div class="rep-chip">News <b class={if(Map.get(o, :news, 0) > 0, do: "rep-ok", else: "rep-warn")}>{fmt(Map.get(o, :news, 0))}</b></div>
          <div class="rep-chip">SEO scored <b class="rep-ok">{fmt(Map.get(o, :with_seo, 0))}</b></div>
          <div class="rep-chip">Catalogs <b class="rep-ok">{fmt(Map.get(o, :with_catalog, 0))}</b></div>
          <div class="rep-chip">Via browser <b class={if(Map.get(o, :via_browser, 0) > 0, do: "rep-ok", else: "rep-warn")}>{fmt(Map.get(o, :via_browser, 0))}</b></div>
        </div>

        <%!-- ENRICHMENT NODES, same card as discovery --%>
        <div class="section-label">Enrichment Nodes</div>
        <%= if agents == [] do %>
          <div class="no-workers">No enrichment lane connected</div>
        <% else %>
          <%= for {node, a} <- agents do %>
            <div class="worker-card">
              <div class="worker-header">
                <span class="worker-name">{node}</span>
                <span class={if a.browser, do: "badge badge-green", else: "badge badge-yellow"}>
                  {if a.browser, do: "browser ready", else: "http only"}
                </span>
                <%= if a.browser do %>
                  <span class="health-chip health-chip-ok" title="camoufox/nodriver sidecar reachable, blocked and JS-only pages can be rendered. Capped at 3 concurrent renders per node.">camoufox · max 3</span>
                <% else %>
                  <span class="health-chip health-chip-warn" title="No LS_BROWSER_URL, WAF-blocked and JS-only pages will be skipped on this node.">no sidecar</span>
                <% end %>
                <span class="worker-batch-info">
                  {a.batches} batches · {fmt(a.total)} enriched
                  <%= if a.last_ms do %> · last {a.last_ms}ms<% end %>
                </span>
              </div>
              <div class="worker-cache" title="What this lane fetches per domain: catalog JSON, ATS job boards, contact/pricing pages, then an SEO audit of the homepage.">
                stages&nbsp; <b>shopify</b> · <b>jobs</b> · <b>contact</b> · <b>pricing</b> · <b>seo+perf</b> · <b>about</b>
              </div>
            </div>
          <% end %>
        <% end %>
      <% end %>

      <%!-- ══════════════ PIPELINE 3 · VERIFICATION ══════════════ --%>
      <%= if @tab == "verification" do %>
        <%= if @verification_stats == nil do %>
          <div class="alert-danger">⛔ Verification tables not reachable (pipeline 3 not deployed here, or ClickHouse down)</div>
        <% else %>
          <% vs = @verification_stats %>
          <% sch = vs.scheduler %>
          <% cov = vs.coverage %>
          <% running = is_map(sch) && Map.get(sch, :running) %>

          <%!-- HEALTH SUMMARY --%>
          <div class="health-bar">
            <span class={"health-dot " <> cond do
              is_map(sch) && Map.get(sch, :disabled) -> "health-amber"
              running && running != false -> "health-green"
              true -> "health-green"
            end}></span>
            <span class="health-label">
              <%= cond do %>
                <% is_map(sch) && Map.get(sch, :disabled) -> %>Scheduler paused (LS_VERIFY_DISABLED), run by hand with LS.Verification.run/1
                <% running && running != false -> %>Ingesting <b>{running}</b> now
                <% true -> %>Idle, next stale source runs automatically
              <% end %>
            </span>
            <div class="health-metrics">
              <span class="hm hm-dim">{fmt(cov.any)} businesses verified</span>
              <span class="hm hm-dim">{fmt(cov.revenue)} revenue</span>
              <span class="hm hm-dim">{fmt(cov.employees)} employees</span>
            </div>
          </div>

          <%!-- PER-SOURCE PIPELINE: fetch → match → facts, with timing --%>
          <div class="section-label" style="margin-top: 0;">Sources, last run</div>
          <table class="peek-table" style="min-width:0;width:100%">
            <thead><tr>
              <th>source</th><th>status</th><th>snapshot</th><th style="text-align:right">records</th>
              <th style="text-align:right">website</th><th style="text-align:right">name+country</th>
              <th style="text-align:right">facts</th><th style="text-align:right">last run</th><th style="text-align:right">took</th>
            </tr></thead>
            <tbody>
              <%= for src <- vs.sources do %>
                <tr>
                  <td><b style="color:#e2e8f0">{src.source}</b><%= if running == String.to_atom(src.source) do %> <span class="badge badge-green">running</span><% end %></td>
                  <td>
                    <span class={cond do
                      src.status == "ok" -> "rep-ok"
                      src.status == "error" -> "rep-warn"
                      true -> ""
                    end}>{src.status}</span>
                  </td>
                  <td style="color:#64748b">{src.snapshot}</td>
                  <td style="text-align:right">{fmt(src.records)}</td>
                  <td style="text-align:right">{if src.matched_website > 0, do: fmt(src.matched_website), else: "-"}</td>
                  <td style="text-align:right">{if src.matched_name_country > 0, do: fmt(src.matched_name_country), else: "-"}</td>
                  <td style="text-align:right">{fmt(Map.get(vs.facts_by_source, src.source, 0))}</td>
                  <td style="text-align:right;color:#64748b">{fmt_ts(src.finished_at)}</td>
                  <td style="text-align:right">{fmt_dur(src.duration_s)}</td>
                </tr>
                <%= if src.status == "error" and src.error not in [nil, ""] do %>
                  <tr><td colspan="9" style="color:#f87171;font-size:10px">↳ {String.slice(src.error, 0, 140)}</td></tr>
                <% end %>
              <% end %>
              <%= if vs.sources == [] do %>
                <tr><td colspan="9" style="color:#64748b">No runs yet, the scheduler starts the first source ~15 min after boot.</td></tr>
              <% end %>
            </tbody>
          </table>

          <%!-- COMPANIES HOUSE STAGING (its heaviest, multi-month step) --%>
          <% acc = vs.accounts %>
          <div class="section-label">Companies House · accounts staging (per-month iXBRL)</div>
          <div class="rep-bar">
            <div class="rep-chip">Months staged <b class={if(acc.months_ok > 0, do: "rep-ok", else: "rep-warn")}>{acc.months_ok}/12</b></div>
            <%= if acc.months_err > 0 do %><div class="rep-chip">Failed months <b class="rep-warn">{acc.months_err}</b></div><% end %>
            <div class="rep-chip">Filings staged <b class="rep-ok">{fmt(acc.staged_rows)}</b></div>
            <%= if acc.running_month not in [nil, ""] do %><div class="rep-chip">Now <b class="rep-ok">{acc.running_month}</b></div><% end %>
          </div>

          <%!-- WHAT IT PRODUCED --%>
          <div class="section-label">Verified facts in the product table</div>
          <div class="rep-bar">
            <div class="rep-chip">Any verified <b class="rep-ok">{fmt(cov.any)}</b></div>
            <div class="rep-chip">Revenue <b class={if(cov.revenue > 0, do: "rep-ok", else: "rep-warn")}>{fmt(cov.revenue)}</b></div>
            <div class="rep-chip">Employees <b class={if(cov.employees > 0, do: "rep-ok", else: "rep-warn")}>{fmt(cov.employees)}</b></div>
            <div class="rep-chip">Mission <b class={if(cov.mission > 0, do: "rep-ok", else: "rep-warn")}>{fmt(cov.mission)}</b></div>
          </div>
        <% end %>
      <% end %>

      <%= if @peek do %>
        <div class="peek-panel">
          <div class="peek-header">
            <span class="peek-title">{@peek.stage} samples, {@peek.worker}</span>
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



  # ── view helpers for the resources bar ─────────────────────────────────────

  defp short_node(node) do
    node |> to_string() |> String.split("@") |> List.first() |> String.replace("worker_", "")
  end

  defp fmt_load(%{cpu_load: [l | _]}) when is_number(l), do: :erlang.float_to_binary(l * 1.0, decimals: 2)
  defp fmt_load(_), do: "-"

  # Load is per-core: >1.0x cores means tasks are queueing for CPU.
  defp load_class(%{cpu_load: [l | _], cores: c}) when is_number(l) and is_integer(c) and c > 0 do
    if l / c > 1.0, do: "hot", else: ""
  end
  defp load_class(_), do: ""

  defp mem_class(%{mem: %{used_pct: p}}) when is_integer(p) and p >= 85, do: "hot"
  defp mem_class(_), do: ""

  # ── Pipeline 2 (enrichment) ────────────────────────────────────────────────

  # Mirrors collect_master_stats/0 but for the depth pipeline: where the work
  # comes from (queue), who is doing it (agents on each node), and what it has
  # produced (biz_* row counts + rate).
  # Row counts of the two end tables. Deliberately its own small query: the
  # dashboard refreshes every 3s and these are the numbers you check first.
  defp collect_table_counts do
    sql = """
    SELECT
      (SELECT count() FROM domains_current)                   AS domains,
      (SELECT count() FROM domains_history)                   AS domain_rows,
      (SELECT count() FROM businesses FINAL)                  AS businesses,
      (SELECT countIf(depth_enriched_at IS NOT NULL) FROM businesses FINAL) AS businesses_enriched
    """

    case LS.Clickhouse.query_raw(sql, 5_000) do
      {:ok, [row]} ->
        [:domains, :domain_rows, :businesses, :businesses_enriched]
        |> Enum.zip(Enum.map(row, &to_int/1))
        |> Map.new()

      _ ->
        %{}
    end
  end

  # Pipeline 3 (verification). All numbers come from one module call
  # (LS.Verification.dashboard_stats/0) with dashboard-safe CH timeouts; nil
  # when the tables/scheduler are absent so the tab degrades to "not deployed".
  defp collect_verification_stats do
    try do
      LS.Verification.dashboard_stats()
    rescue
      _ -> nil
    catch
      :exit, _ -> nil
    end
  end

  defp collect_enrichment_stats do
    queue = sc(LS.Cluster.EnrichmentQueue, :stats)
    compactor = sc(LS.Cluster.Compactor, :stats)

    agents =
      [Node.self() | Node.list()]
      |> Enum.map(fn n ->
        stats = try do
          GenServer.call({LS.Enrichment.Agent, n}, :stats, 2_000)
        catch
          :exit, _ -> nil
        end
        {n, stats}
      end)
      |> Enum.reject(fn {_, s} -> is_nil(s) end)

    %{queue: queue, compactor: compactor, agents: agents, output: enrichment_output()}
  end

  # One round-trip for every counter the tab shows, so the 3s refresh stays cheap.
  defp enrichment_output do
    sql = """
    SELECT
      (SELECT count() FROM biz_enrichment) AS enriched,
      (SELECT count() FROM biz_enrichment WHERE enriched_at >= now() - INTERVAL 1 MINUTE) AS per_min,
      (SELECT count() FROM biz_enrichment WHERE enriched_at >= now() - INTERVAL 1 HOUR) AS last_hour,
      (SELECT count() FROM biz_contact) AS contacts,
      (SELECT count() FROM biz_career) AS jobs,
      (SELECT count() FROM biz_pricing) AS pricing,
      (SELECT count() FROM biz_news) AS news,
      (SELECT countIf(seo_score IS NOT NULL) FROM biz_enrichment) AS with_seo,
      (SELECT countIf(product_count IS NOT NULL) FROM biz_enrichment) AS with_catalog,
      (SELECT countIf(render_engine = 'camoufox') FROM biz_enrichment) AS via_browser,
      (SELECT uniq(domain) FROM businesses) AS businesses,
      -- uniq over biz_enrichment, NOT depth_enriched_at on businesses: that
      -- column only the newer depth pass sets, so it is NULL for the ~2-3M
      -- businesses enriched before it existed. It made the admin read
      -- "11M/14.3M", a phantom 3M backlog, while real coverage was 98%
      -- (owner chased it on 2026-08-25). uniq() is approximate (~1% error)
      -- which is fine for a dashboard pair; the data-contract suite holds
      -- this metric to the truth within 5%.
      (SELECT uniq(domain) FROM biz_enrichment) AS businesses_enriched
    """

    case LS.Clickhouse.query_raw(sql, 5_000) do
      {:ok, [row]} ->
        ~w(enriched per_min last_hour contacts jobs pricing news with_seo
           with_catalog via_browser businesses businesses_enriched)a
        |> Enum.zip(Enum.map(row, &to_int/1))
        |> Map.new()

      _ ->
        %{}
    end
  end

  defp to_int(v) when is_integer(v), do: v
  defp to_int(v) when is_binary(v), do: String.to_integer(v)
  defp to_int(_), do: 0

  # ── Node resources (sysstat / /proc) ───────────────────────────────────────

  # Read straight from the BEAM and /proc rather than shelling out to `sar`:
  # the dashboard refreshes every 3s and needs *current* load, which is what
  # /proc/loadavg and /proc/meminfo give for free. `sar` remains the tool for
  # historical questions ("what happened last Tuesday"), not live ones.
  defp collect_node_resources do
    [Node.self() | Node.list()]
    |> Enum.map(fn n ->
      res = try do
        :erpc.call(n, __MODULE__, :local_resources, [], 2_000)
      catch
        _, _ -> nil
      end
      {n, res}
    end)
    |> Enum.reject(fn {_, r} -> is_nil(r) end)
  end

  @doc false
  # Public because :erpc calls it on remote nodes.
  def local_resources do
    %{
      cpu_load: read_loadavg(),
      cores: System.schedulers_online(),
      mem: read_meminfo(),
      beam_mb: div(:erlang.memory(:total), 1_048_576)
    }
  end

  # Linux nodes expose /proc; dev Macs do not. Support both rather than showing
  # "-" on the machine the developer is actually looking at.
  defp read_loadavg do
    case File.read("/proc/loadavg") do
      {:ok, c} ->
        c |> String.split() |> Enum.take(3) |> Enum.map(&parse_float/1)

      _ ->
        # macOS: sysctl -n vm.loadavg  ->  "{ 3.25 3.59 3.75 }"
        case System.cmd("sysctl", ["-n", "vm.loadavg"], stderr_to_stdout: true) do
          {out, 0} ->
            out
            |> String.replace(["{", "}"], "")
            |> String.split()
            |> Enum.take(3)
            |> Enum.map(&parse_float/1)

          _ ->
            [nil, nil, nil]
        end
    end
  rescue
    _ -> [nil, nil, nil]
  end

  defp read_meminfo do
    case File.read("/proc/meminfo") do
      {:ok, c} -> linux_meminfo(c)
      _ -> darwin_meminfo()
    end
  rescue
    _ -> %{total_mb: nil, avail_mb: nil, used_pct: nil}
  end

  defp linux_meminfo(contents) do
    vals =
      contents
      |> String.split("\n")
      |> Enum.reduce(%{}, fn line, acc ->
        case String.split(line, ~r/:\s+/) do
          [k, v] -> Map.put(acc, k, v |> String.replace(" kB", "") |> parse_int())
          _ -> acc
        end
      end)

    mb(Map.get(vals, "MemTotal", 0) * 1024, Map.get(vals, "MemAvailable", 0) * 1024)
  end

  # macOS: total from sysctl, free from vm_stat's page counters. "Available" is
  # free + inactive + speculative, which is what the OS can hand out on demand.
  defp darwin_meminfo do
    with {total_s, 0} <- System.cmd("sysctl", ["-n", "hw.memsize"], stderr_to_stdout: true),
         {vm, 0} <- System.cmd("vm_stat", [], stderr_to_stdout: true) do
      total = parse_int(total_s)
      page = Regex.run(~r/page size of (\d+)/, vm) |> pick_int(4096)

      pages = fn name ->
        case Regex.run(~r/#{name}:\s+(\d+)/, vm) do
          [_, n] -> parse_int(n)
          _ -> 0
        end
      end

      avail = (pages.("Pages free") + pages.("Pages inactive") + pages.("Pages speculative")) * page
      mb(total, avail)
    else
      _ -> %{total_mb: nil, avail_mb: nil, used_pct: nil}
    end
  end

  defp pick_int([_, n], _default), do: parse_int(n)
  defp pick_int(_, default), do: default

  defp mb(total_bytes, avail_bytes) when total_bytes > 0 do
    %{total_mb: div(total_bytes, 1_048_576), avail_mb: div(avail_bytes, 1_048_576),
      used_pct: round((total_bytes - avail_bytes) / total_bytes * 100)}
  end

  defp mb(_, _), do: %{total_mb: nil, avail_mb: nil, used_pct: nil}

  defp parse_float(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> nil
    end
  end
  defp parse_int(s) do
    case Integer.parse(String.trim(s)) do
      {i, _} -> i
      :error -> 0
    end
  end

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

  # ── Worker data-quality health (Inserter guard) ─────────────────────────────
  # %{"worker_..." => %{ratio:, quarantined:, dropped:}} — empty map off-master.
  defp collect_worker_health do
    LS.Cluster.Inserter.worker_health()
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  # Fleet cache stats — RDAP/BGP/HTTP caches live on the WORKERS (the master
  # never crawls, so its caches are empty). Pull each worker's LS.Cache and
  # aggregate a true fleet hit-ratio: "are we reusing lookups or re-fetching?".
  # A node reports its own lanes; if it is too old to answer, assume discovery
  # (that was the only lane before pipeline 2 existed).
  defp runs_lane?(node, lane) do
    case :erpc.call(node, LS.Application, :worker_lanes, [], 2_000) do
      lanes when is_list(lanes) -> lane in lanes
      _ -> lane == "discovery"
    end
  catch
    _, _ -> lane == "discovery"
  end

  defp collect_worker_caches do
    Node.list()
    |> Enum.reduce(%{}, fn node, acc ->
      case :rpc.call(node, LS.Cache, :stats, [], 3_000) do
        %{} = st -> Map.put(acc, Atom.to_string(node), st)
        _ -> acc
      end
    end)
  end

  # This worker's cache snapshot (or nil if it didn't answer / off-master).
  defp worker_cache(caches, node_name), do: Map.get(caches, to_string(node_name))

  # Render one cache cell: hit% + entry count, or "empty" (ETS cold after restart),
  # or "N idle" (warm but no reads since boot).
  def cache_cell(cache, key) do
    sub = Map.get(cache, key, %{})
    e = Map.get(sub, :entries, 0)
    reads = Map.get(sub, :hits, 0) + Map.get(sub, :misses, 0)
    cond do
      e == 0 -> "empty"
      reads == 0 -> "#{fmt(e)} idle"
      true -> "#{round(Map.get(sub, :hits, 0) / reads * 100)}% · #{fmt(e)}"
    end
  end

  # Fleet hit-ratio for a cache key (:http | :bgp | :rdap), or nil if no traffic yet.
  def fleet_hit_ratio(caches, key) do
    caches = if is_map(caches), do: Map.values(caches), else: caches
    {h, m} =
      Enum.reduce(caches, {0, 0}, fn c, {ah, am} ->
        sub = Map.get(c, key, %{})
        {ah + Map.get(sub, :hits, 0), am + Map.get(sub, :misses, 0)}
      end)

    if h + m > 0, do: Float.round(h / (h + m) * 100, 1), else: nil
  end

  # Health entry for a connected worker card.
  defp health_for(health, node_name), do: Map.get(health, to_string(node_name))

  # Workers the Inserter has seen rows from that are NOT currently connected.
  defp missing_workers(health, worker_stats) do
    connected = MapSet.new(worker_stats, fn {n, _} -> to_string(n) end)
    health |> Enum.reject(fn {n, _} -> MapSet.member?(connected, n) end)
  end

  # Card severity: :danger (quarantined) | :warn (ratio near the trip wire) | :ok
  defp health_severity(nil), do: :ok
  defp health_severity(%{quarantined: true}), do: :danger
  defp health_severity(%{ratio: r}) when is_number(r) and r < 0.95, do: :warn
  defp health_severity(_), do: :ok

  defp health_card_class(:danger), do: "worker-card worker-card-danger"
  defp health_card_class(:warn), do: "worker-card worker-card-warn"
  defp health_card_class(:ok), do: "worker-card"

  defp collect_worker_stats do
    Node.list()
    |> Enum.filter(&runs_lane?(&1, "discovery"))
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

  # Rates arrive as floats and LiveView prints 12000.0 as "1.2e4" — render
  # them as plain comma-grouped integers.
  defp rate(q, k), do: q |> qv(k) |> round() |> format_int()
  defp iv(nil, _), do: 0
  defp iv(i, k), do: Map.get(i, k, 0)
  defp plc(nil), do: 0
  defp plc(p), do: Map.get(p, :active_logs, 0)

  defp rep_val(ms, :tranco), do: get_in(ms, [:tranco, :domains_loaded]) || 0
  defp rep_val(ms, :majestic), do: get_in(ms, [:majestic, :domains_loaded]) || 0
  defp rep_val(ms, :blocklist), do: get_in(ms, [:blocklist, :total]) || 0

  # Staffing is answered by LS.Cluster.QueueTrend over an hour of history.
  # It is NOT derived from the instantaneous enqueue rate: three consecutive
  # prod samples read 38,613 / 3,348 / 7,803 per minute, so a per-sample figure
  # flapped between "need 1" and "need 21" while the queue sat comfortable.
  defp pipeline_health(ms, trend) do
    qpct = qv(ms.queue, :queue_pct)
    wc = length(Node.list())
    growing = (trend[:depth_slope_per_min] || 0) > 0

    cond do
      wc == 0 -> {"health-red", "No workers connected"}
      qpct >= 90 -> {"health-red", "Queue nearly full, add workers"}
      trend[:status] == :insufficient_data -> {"health-green", "Measuring throughput..."}
      short_staffed?(trend) and growing -> {"health-amber", "Backlog growing, short of workers"}
      growing and qpct >= 50 -> {"health-amber", "Backlog growing, buffer half used"}
      growing -> {"health-green", "Absorbing a burst in the queue"}
      true -> {"health-green", "Workers keeping up"}
    end
  end

  defp short_staffed?(%{workers_needed: n, workers: w}) when is_integer(n), do: n > w
  defp short_staffed?(_), do: false

  # ── staffing display helpers ──

  defp trend_v(trend, key) do
    case trend[key] do
      nil -> "-"
      v when is_integer(v) -> format_int(v)
      v -> to_string(v)
    end
  end

  defp trend_window(%{status: :insufficient_data}), do: "warming up"
  defp trend_window(%{window_minutes: m}) when is_integer(m) and m > 0, do: "#{m} min"
  defp trend_window(_), do: "warming up"

  defp trend_slope(trend) do
    case trend[:depth_slope_per_min] do
      nil -> "-"
      s when s > 0 -> "+#{format_int(s)}/m"
      s when s < 0 -> "#{format_int(s)}/m"
      _ -> "flat"
    end
  end

  # The buffer only has a runway while the backlog is actually growing.
  defp runway_label(trend) do
    case trend[:runway_minutes] do
      :infinity -> "not filling"
      m when is_integer(m) and m >= 1440 -> "#{div(m, 1440)}d"
      m when is_integer(m) and m >= 60 -> "#{div(m, 60)}h"
      m when is_integer(m) -> "#{m} min"
      _ -> "-"
    end
  end

  defp staffing_label(%{status: :insufficient_data}), do: "measuring..."
  defp staffing_label(%{workers_needed: nil}), do: "capacity unproven"

  defp staffing_label(%{workers_needed: n, workers: w}) do
    cond do
      n > w -> "need #{n} (#{n - w} short)"
      w - n > 0 -> "surplus #{w - n}"
      true -> "at capacity"
    end
  end

  defp staffing_label(_), do: "-"

  defp staffing_class(%{workers_needed: n, workers: w}) when is_integer(n) and n > w, do: "hm-warn"
  defp staffing_class(%{workers_needed: n, workers: w}) when is_integer(n) and w > n, do: "hm-ok"
  defp staffing_class(_), do: "hm-dim"

  @doc false
  # Public for the regression test: queue rates are floats and LiveView
  # renders 12000.0 as "1.2e4" (seen on the discovery tab 2026-08-25).
  def format_int(n) when is_integer(n) and n < 0, do: "-" <> format_int(-n)

  def format_int(n) when is_integer(n) do
    n |> Integer.to_charlist() |> Enum.reverse() |> Enum.chunk_every(3) |> Enum.join(",") |> String.reverse()
  end

  # per-minute rate helpers (one unit across the whole pipeline)
  defp ctl_per_min(ms), do: round((case ms.poller do nil -> 0.0; p -> Map.get(p, :domains_per_sec, 0.0) end) * 60)


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

  # "2026-08-20 15:09:49" -> "08-20 15:09"; the zero DateTime CH uses for
  # "not finished" renders as a dash.
  defp fmt_ts(ts) when is_binary(ts) do
    cond do
      ts in ["", "1970-01-01 00:00:00", "0000-00-00 00:00:00"] -> "-"
      String.length(ts) >= 16 -> String.slice(ts, 5, 11)
      true -> ts
    end
  end

  defp fmt_ts(_), do: "-"

  defp fmt_dur(s) when is_integer(s) and s > 0 do
    cond do
      s >= 3600 -> "#{Float.round(s / 3600, 1)}h"
      s >= 60 -> "#{div(s, 60)}m#{rem(s, 60)}s"
      true -> "#{s}s"
    end
  end

  defp fmt_dur(_), do: "-"

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
