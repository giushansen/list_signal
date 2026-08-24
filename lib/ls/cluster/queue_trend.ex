defmodule LS.Cluster.QueueTrend do
  @moduledoc """
  Answers "do we need more workers?" from an hour of history instead of one
  noisy sample.

  ## Why the old number was wrong (2026-08-24)

  The dashboard divided `enqueue_rate_per_min` by a hard-coded
  `@per_worker_per_min 500`. Both halves were unsound:

  * **The rate is a short window over a bursty source.** Three consecutive
    prod samples read 38,613 / 3,348 / 7,803 domains per minute — an 11x swing
    in two minutes, because CT logs deliver in bursts and a restart makes the
    poller catch up all at once. Any figure divided by one such sample flaps
    between "need 1" and "need 21".
  * **500/worker was a guess.** Worker-reported throughput is a *lifetime*
    average, so it measures how much work there was, not how much a worker can
    do. Whenever the queue is empty every worker looks slow, which understates
    capacity exactly when it matters least and overstates need.

  So this module measures both sides properly:

  * **Demand** comes from the monotonic `total_enqueued` counter over the whole
    window. A counter delta over an hour is immune to burstiness — it is the
    real arrival rate by construction.
  * **Capacity** is the *best* drain ever observed while the queue was deep
    enough that workers could not have been idle. That is a measurement of what
    the fleet can do, not of what it happened to be asked for.

  ## The queue is a buffer, and that is the real answer

  Sustained demand below capacity means a burst is not a staffing problem — it
  is what the queue is for. `runway_minutes` says how long the buffer absorbs
  the *current* trend, so a growing backlog can be told apart from one that is
  merely large.
  """
  use GenServer

  @interval_ms :timer.minutes(1)
  @window 60
  # Below this depth a worker may have gone hungry between polls, so a drain
  # measured across it is a floor on capacity, not a reading of it.
  @saturated_depth 5_000

  defstruct samples: []

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Trend over the retained window. See `analyze/2` for the shape."
  def analysis(worker_count) do
    GenServer.call(__MODULE__, {:analysis, worker_count}, 5_000)
  catch
    :exit, _ -> analyze([], worker_count)
  end

  @impl true
  def init(_opts) do
    send(self(), :sample)
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_info(:sample, state) do
    Process.send_after(self(), :sample, @interval_ms)
    {:noreply, %{state | samples: Enum.take([sample() | state.samples], @window)}}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def handle_call({:analysis, wc}, _from, state) do
    {:reply, analyze(Enum.reverse(state.samples), wc), state}
  end

  defp sample do
    s = LS.Cluster.WorkQueue.stats()

    %{
      ts: System.system_time(:millisecond),
      depth: s.queue_depth,
      max: s[:queue_max] || 0,
      enqueued: s.total_enqueued,
      completed: s.total_completed
    }
  end

  @doc """
  Pure trend maths over oldest-first `samples`.

  Returns `:insufficient_data` in `status` until there are two samples far
  enough apart to divide by — never a fabricated number. `workers_needed` is
  `nil` whenever capacity could not be measured (the queue never got deep
  enough to prove what the fleet can do), because a guess is what this module
  exists to remove.
  """
  @spec analyze([map()], non_neg_integer()) :: map()
  def analyze(samples, worker_count)

  def analyze(samples, wc) when length(samples) < 2 do
    base(wc) |> Map.put(:status, :insufficient_data)
  end

  def analyze(samples, wc) do
    first = List.first(samples)
    last = List.last(samples)
    mins = (last.ts - first.ts) / 60_000

    if mins < 1 do
      base(wc) |> Map.put(:status, :insufficient_data)
    else
      compute(samples, first, last, mins, wc)
    end
  end

  defp compute(samples, first, last, mins, wc) do
    demand = (last.enqueued - first.enqueued) / mins
    drain = (last.completed - first.completed) / mins
    slope = (last.depth - first.depth) / mins
    capacity = observed_capacity(samples)
    per_worker = if capacity && wc > 0, do: capacity / wc, else: nil

    %{
      status: :ok,
      window_minutes: round(mins),
      workers: wc,
      demand_per_min: round(demand),
      drain_per_min: round(drain),
      depth: last.depth,
      depth_slope_per_min: round(slope),
      capacity_per_min: capacity && round(capacity),
      per_worker_per_min: per_worker && round(per_worker),
      workers_needed: workers_needed(demand, per_worker),
      surplus: surplus(demand, per_worker, wc),
      runway_minutes: runway(last, slope)
    }
  end

  defp base(wc) do
    %{
      status: :ok,
      window_minutes: 0,
      workers: wc,
      demand_per_min: 0,
      drain_per_min: 0,
      depth: 0,
      depth_slope_per_min: 0,
      capacity_per_min: nil,
      per_worker_per_min: nil,
      workers_needed: nil,
      surplus: nil,
      runway_minutes: :infinity
    }
  end

  # Best sustained drain across any adjacent pair where the queue stayed deep,
  # i.e. where every worker demonstrably had work available throughout.
  defp observed_capacity(samples) do
    samples
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [a, b] ->
      mins = (b.ts - a.ts) / 60_000

      if mins > 0 and min(a.depth, b.depth) >= @saturated_depth do
        [(b.completed - a.completed) / mins]
      else
        []
      end
    end)
    |> case do
      [] -> nil
      rates -> Enum.max(rates)
    end
  end

  defp workers_needed(_demand, nil), do: nil
  defp workers_needed(demand, pw) when pw > 0, do: max(1, ceil(demand / pw))
  defp workers_needed(_, _), do: nil

  defp surplus(demand, pw, wc) do
    case workers_needed(demand, pw) do
      nil -> nil
      needed -> wc - needed
    end
  end

  # How long the buffer absorbs the current trend. Only meaningful while the
  # backlog is actually growing.
  defp runway(%{max: max, depth: depth}, slope) when slope > 0 and max > depth,
    do: round((max - depth) / slope)

  defp runway(_, _), do: :infinity
end
