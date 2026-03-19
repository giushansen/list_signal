defmodule LSWeb.DashboardLive do
  use LSWeb, :live_view

  @refresh_interval 3_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh_interval)
    {:ok, assign(socket, stats: collect_stats(), role: System.get_env("LS_ROLE", "standalone"))}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_interval)
    {:noreply, assign(socket, stats: collect_stats())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1>ListSignal</h1>
    <p class="subtitle">Domain Intelligence — {@role} node</p>

    <%= if @stats.queue && @stats.queue.queue_pct >= 80.0 do %>
      <div class="alert alert-warn">
        ⚠️ Queue at {@stats.queue.queue_pct}% capacity — consider adding workers
      </div>
    <% end %>

    <div class="grid">
      <div class="card">
        <h3>Queue Depth</h3>
        <div class="value">{format_num(@stats.queue && @stats.queue.queue_depth || 0)}</div>
        <div class="sub">{@stats.queue && @stats.queue.queue_pct || 0}% of 5M max</div>
      </div>

      <div class="card">
        <h3>Inflow</h3>
        <div class="value">{@stats.queue && @stats.queue.enqueue_rate_per_min || 0}/min</div>
        <div class="sub">From CTL poller</div>
      </div>

      <div class="card">
        <h3>Drain Rate</h3>
        <div class="value">{@stats.queue && @stats.queue.drain_rate_per_min || 0}/min</div>
        <div class="sub">Workers enriching</div>
      </div>

      <div class="card">
        <h3>CH Inserts</h3>
        <div class="value">{@stats.inserter && @stats.inserter.insert_rate_per_min || 0}/min</div>
        <div class="sub">
          Buffer: {@stats.inserter && @stats.inserter.buffer_size || 0} |
          Errors: {@stats.inserter && @stats.inserter.total_errors || 0}
        </div>
      </div>

      <div class="card">
        <h3>Workers</h3>
        <div class="value">{@stats.worker_count}</div>
        <div class="sub">
          Inflight: {@stats.queue && @stats.queue.inflight_batches || 0} batches
        </div>
      </div>

      <div class="card">
        <h3>Total Enriched</h3>
        <div class="value">{format_num(@stats.queue && @stats.queue.total_completed || 0)}</div>
        <div class="sub">
          Requeued: {format_num(@stats.queue && @stats.queue.total_requeued || 0)} |
          Dropped: {format_num(@stats.queue && @stats.queue.total_dropped || 0)}
        </div>
      </div>

      <div class="card">
        <h3>CTL Cache</h3>
        <div class="value">{format_num(@stats.cache.ctl.entries)}</div>
        <div class="sub">{@stats.cache.ctl.memory_mb} MB | {@stats.cache.ctl.usage_pct}% of 5M</div>
      </div>

      <div class="card">
        <h3>HTTP Cache</h3>
        <div class="value">{format_num(@stats.cache.http.entries)}</div>
        <div class="sub">{@stats.cache.http.memory_mb} MB (politeness)</div>
      </div>
    </div>

    <div class="workers">
      <h2 style="color: #94a3b8; font-size: 14px; text-transform: uppercase; letter-spacing: 1px;">
        Connected Workers
      </h2>
      <table>
        <thead>
          <tr><th>Node</th><th>Status</th></tr>
        </thead>
        <tbody>
          <%= if @stats.workers == [] do %>
            <tr><td colspan="2" style="color: #64748b;">No workers connected</td></tr>
          <% else %>
            <%= for w <- @stats.workers do %>
              <tr>
                <td>{w}</td>
                <td><span class="badge badge-green">connected</span></td>
              </tr>
            <% end %>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  defp collect_stats do
    queue = try do LS.Cluster.WorkQueue.stats() rescue _ -> nil catch :exit, _ -> nil end
    inserter = try do LS.Cluster.Inserter.stats() rescue _ -> nil catch :exit, _ -> nil end
    cache = try do
      LS.Cache.stats()
    rescue
      _ -> %{ctl: %{entries: 0, memory_mb: 0, usage_pct: 0}, http: %{entries: 0, memory_mb: 0}, bgp: %{entries: 0, memory_mb: 0}}
    catch
      :exit, _ -> %{ctl: %{entries: 0, memory_mb: 0, usage_pct: 0}, http: %{entries: 0, memory_mb: 0}, bgp: %{entries: 0, memory_mb: 0}}
    end
    workers = Node.list() |> Enum.map(&Atom.to_string/1)

    %{queue: queue, inserter: inserter, cache: cache, workers: workers, worker_count: length(workers)}
  end

  defp format_num(n) when is_integer(n) and n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_num(n) when is_integer(n) and n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_num(n) when is_number(n), do: "#{n}"
  defp format_num(_), do: "0"
end
