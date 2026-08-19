defmodule LS.Verification.Scheduler do
  @moduledoc """
  Master-only. Keeps every verification source fresh: on each tick it looks
  at `verification_runs` for the newest successful run per source and starts
  the first stale one (in `LS.Verification.sources/0` order — website-linked
  sources first), one at a time, in a supervised Task so a multi-hour Sirene
  pass never blocks this process or the app.

  Cadence is per source (`@every`): the crowd/curated sources weekly, the
  registries monthly (that is how often they publish). Set
  `LS_VERIFY_DISABLED=1` to keep the scheduler idle (runs stay available via
  `LS.Verification.run/1` over rpc).
  """

  use GenServer
  require Logger
  alias LS.Clickhouse
  alias LS.Verification

  @tick_ms 30 * 60_000
  @first_tick_ms 15 * 60_000
  @day 86_400
  @every %{wikidata: 7 * @day, yc: 7 * @day, sec_edgar: 30 * @day, companies_house: 30 * @day, sirene: 30 * @day}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "What is running, what ran last, and any error — for the dashboard."
  def stats, do: GenServer.call(__MODULE__, :stats)

  @doc "Force a source to run now (still one at a time)."
  def run_now(source), do: GenServer.call(__MODULE__, {:run_now, source})

  @impl true
  def init(_opts) do
    disabled = System.get_env("LS_VERIFY_DISABLED") in ["1", "true"]
    unless disabled, do: Process.send_after(self(), :tick, @first_tick_ms)
    Logger.info("🔎 Verification scheduler started#{if disabled, do: " (disabled)", else: ""}")
    {:ok, %{running: nil, task: nil, last: %{}, disabled: disabled}}
  end

  @impl true
  def handle_call(:stats, _from, s), do: {:reply, Map.take(s, [:running, :last, :disabled]), s}

  def handle_call({:run_now, source}, _from, %{running: nil} = s) when is_atom(source) do
    {:reply, :ok, start(source, s)}
  end

  def handle_call({:run_now, _}, _from, s), do: {:reply, {:error, {:busy, s.running}}, s}

  @impl true
  def handle_info(:tick, %{running: nil} = s) do
    Process.send_after(self(), :tick, @tick_ms)

    case stale_source() do
      nil -> {:noreply, s}
      source -> {:noreply, start(source, s)}
    end
  end

  def handle_info(:tick, s) do
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, s}
  end

  def handle_info({ref, result}, %{task: %{ref: ref}} = s) do
    Process.demonitor(ref, [:flush])
    Logger.info("[VERIFY] #{s.running} finished: #{inspect(result)}")
    {:noreply, %{s | running: nil, task: nil, last: Map.put(s.last, s.running, {NaiveDateTime.utc_now(), result})}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %{ref: ref}} = s) do
    Logger.error("[VERIFY] #{s.running} crashed: #{inspect(reason)}")
    {:noreply, %{s | running: nil, task: nil, last: Map.put(s.last, s.running, {NaiveDateTime.utc_now(), {:error, reason}})}}
  end

  def handle_info(_, s), do: {:noreply, s}

  defp start(source, s) do
    task = Task.Supervisor.async_nolink(LS.Verification.TaskSupervisor, fn -> Verification.run(source) end)
    %{s | running: source, task: task}
  end

  @doc false
  def stale_source do
    last_ok =
      case Clickhouse.query_raw("SELECT source, max(finished_at) FROM verification_runs WHERE status = 'ok' GROUP BY source") do
        {:ok, rows} -> Map.new(rows, fn [src, at] -> {src, at} end)
        _ -> %{}
      end

    now = NaiveDateTime.utc_now()

    Enum.find(Verification.sources(), fn source ->
      case last_ok[to_string(source)] do
        nil -> true
        at ->
          case NaiveDateTime.from_iso8601(String.replace(at, " ", "T")) do
            {:ok, t} -> NaiveDateTime.diff(now, t) > @every[source]
            _ -> true
          end
      end
    end)
  end
end
