defmodule LS.Recrawl.LeanGate do
  @moduledoc """
  In lean mode (`LS.Crawl.Lean`), holds a certificate sighting for a few
  seconds and asks ClickHouse whether the site was read successfully in
  the last `LS.Crawl.Lean.reread_days/0`. If it was, the sighting is
  recorded and not queued; otherwise it is queued as before.

  The master's rings cannot answer this. They know compiled businesses
  and what the last crawl decided, but 2026-11-14 measured 39K rows a day
  going to sites read fine 40 to 75 days earlier that had no `businesses`
  row (read between 09-07 and 10-03, when only labelled sites got one),
  and 28K to junk, other-language and dead pages. `enrich_log` is sorted
  by domain, so a lookup of a few hundred names reads only their
  granules.

  Fails open, like every gate before the queue: no process, a refused
  query, a name that cannot be quoted or a full buffer all mean the
  sighting is queued unchecked. On shutdown the buffer is queued, because
  a new domain dropped here would wait for its next certificate.
  """

  use GenServer
  require Logger

  alias LS.Backfill.Ranges
  alias LS.Schema.Tables

  @flush_ms 15_000
  @page 500
  @buffer_max 20_000
  @log_every 40

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Pure: does this enqueue go through the gate? Only in lean mode, and
  never for the scheduler (`force`, `:recrawl`), the never-fetched backlog
  (`:backfill`), a business that just changed (`hot`) or an item the gate
  already checked.
  """
  @spec divert?(map(), keyword(), boolean(), boolean()) :: boolean()
  def divert?(item, opts, hot, lean_on) when is_map(item) and is_list(opts) do
    lean_on and not hot and not Keyword.get(opts, :force, false) and not Keyword.get(opts, :lean_checked, false) and
      item[:source] not in [:recrawl, :backfill]
  end

  def divert?(_, _, _, _), do: false

  @doc "True when the gate's process is up on this node."
  @spec running?() :: boolean()
  def running?, do: is_pid(Process.whereis(__MODULE__))

  @doc "Hand a sighting to the gate. Always `:ok`; the gate queues it or records it within `@flush_ms`."
  @spec hold(map()) :: :ok
  def hold(item) when is_map(item), do: GenServer.cast(__MODULE__, {:hold, item})

  @doc "Pure: the lookup for one page of names already filtered by `LS.Backfill.Ranges.safe_domains/1`."
  @spec lookup_sql([String.t()], pos_integer()) :: String.t()
  def lookup_sql(domains, days) when is_list(domains) and is_integer(days) and days > 0 do
    list = Enum.map_join(domains, ", ", &"'#{&1}'")

    """
    SELECT domain FROM #{Tables.enrich_log()}
    WHERE domain IN (#{list}) AND enriched_at >= now() - INTERVAL #{days} DAY AND http_status = 200
    GROUP BY domain
    SETTINGS max_threads = 2, max_execution_time = 15
    """
  end

  @doc """
  Pure: split buffered sightings by the lookup's answer into
  `{held, passed}`. Anything the answer does not name passes, so garbage
  from ClickHouse can only let a sighting through.
  """
  @spec split(%{String.t() => map()}, term()) :: {[map()], [map()]}
  def split(buffer, read) when is_map(buffer) do
    read = MapSet.new(Ranges.safe_domains(if(is_list(read), do: read, else: [])))
    {held, passed} = Enum.split_with(buffer, fn {domain, _} -> MapSet.member?(read, domain) end)
    {Enum.map(held, &elem(&1, 1)), Enum.map(passed, &elem(&1, 1))}
  end

  @doc "Counters since boot: sightings held back, passed on, lookups that failed, and the buffer now."
  def stats do
    GenServer.call(__MODULE__, :stats, 5_000)
  catch
    :exit, _ -> %{running: false}
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    Process.send_after(self(), :flush, @flush_ms)
    if LS.Crawl.Lean.on?(), do: Logger.info("[LEAN] lean crawl is ON: sites read in the last #{LS.Crawl.Lean.reread_days()} days are not re-read on a certificate, Shopify stores every #{LS.Crawl.Lean.shopify_days()} days")
    {:ok, %{buffer: %{}, held: 0, passed: 0, failed: 0, flushes: 0}}
  end

  @impl true
  def handle_cast({:hold, item}, s) do
    domain = item[:ctl_domain] || item[:domain]

    cond do
      not is_binary(domain) or Ranges.safe_domains([domain]) == [] or map_size(s.buffer) >= @buffer_max ->
        pass([item])
        {:noreply, %{s | passed: s.passed + 1}}

      true ->
        {:noreply, %{s | buffer: Map.put(s.buffer, domain, item)}}
    end
  end

  @impl true
  def handle_call(:stats, _from, s), do: {:reply, %{running: true, held: s.held, passed: s.passed, failed: s.failed, buffer: map_size(s.buffer), lean: LS.Crawl.Lean.on?()}, s}

  @impl true
  def handle_info(:flush, s) do
    Process.send_after(self(), :flush, @flush_ms)
    s = flush(s)
    s = %{s | flushes: s.flushes + 1}
    if rem(s.flushes, @log_every) == 0 and s.held + s.passed > 0, do: Logger.info("[LEAN] since boot: #{s.held} sightings held (read in the last #{LS.Crawl.Lean.reread_days()} days), #{s.passed} passed, #{s.failed} lookups failed")
    {:noreply, s}
  end

  def handle_info(_, s), do: {:noreply, s}

  @impl true
  def terminate(_reason, s) do
    pass(Map.values(s.buffer))
    :ok
  end

  defp flush(%{buffer: buffer} = s) when map_size(buffer) == 0, do: s

  defp flush(s) do
    s.buffer
    |> Enum.chunk_every(@page)
    |> Enum.reduce(%{s | buffer: %{}}, fn chunk, acc ->
      page = Map.new(chunk)

      case LS.Clickhouse.query_raw(lookup_sql(Map.keys(page), LS.Crawl.Lean.reread_days()), 20_000) do
        {:ok, rows} ->
          {held, passed} = split(page, rows)
          Enum.each(held, &LS.Cluster.CrawlDedup.record_sighting/1)
          pass(passed)
          %{acc | held: acc.held + length(held), passed: acc.passed + length(passed)}

        other ->
          Logger.warning("[LEAN] lookup failed, #{map_size(page)} sightings queued unchecked: #{inspect(other) |> String.slice(0, 200)}")
          pass(Map.values(page))
          %{acc | failed: acc.failed + 1, passed: acc.passed + map_size(page)}
      end
    end)
  catch
    kind, reason ->
      Logger.warning("[LEAN] flush crashed, buffer queued unchecked: #{inspect({kind, reason}) |> String.slice(0, 200)}")
      pass(Map.values(s.buffer))
      %{s | buffer: %{}, failed: s.failed + 1}
  end

  defp pass(items), do: Enum.each(items, &LS.Cluster.WorkQueue.enqueue(&1, lean_checked: true))
end
