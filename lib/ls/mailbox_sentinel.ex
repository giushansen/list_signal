defmodule LS.MailboxSentinel do
  @moduledoc """
  Catches runaway process mailboxes: identifies them while they are still
  small, kills them before they take the node down.

  ## Why this exists

  2026-08-19: an unnamed process was found stuck in `:re.grun` with 79,768
  queued messages and 64MB of heap; VM memory rose to 6.2G and stayed there,
  the OverloadGuard shed all traffic, and only a restart recovered. Static
  analysis could not identify the process — by the time anyone looked, only
  the symptom remained. The sender's identity lives in the queued messages
  themselves, so the only reliable diagnosis is to CATCH the queue while it
  grows and log what is inside it.

  ## What it does, per sweep (every 5s)

    * mq > @peek_threshold: log full identification — initial call,
      ancestors, current stacktrace, and the first queued messages (which
      name the sender and protocol). Rate-limited per process.
    * mq > @kill_threshold: also kill the process. Every supervised process
      in this app restarts cleanly, and a clean restart with an empty
      mailbox beats an unbounded queue marching the VM into its memory
      limit. The kill is logged loudly with everything needed for the
      post-mortem.

  The endpoint, Repo and other kill-exempt processes are listed explicitly —
  killing the web server to save the web server would be self-parody.
  """
  use GenServer
  require Logger

  @sweep_ms 5_000
  @peek_threshold 2_000
  @kill_threshold 30_000
  # Never kill these even over threshold; their queues mean "busy", not "stuck".
  @kill_exempt [LSWeb.Endpoint, LS.Repo, LS.PubSub]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    # Inert under test unless explicitly enabled: a sweeper that kills busy
    # processes is a chaos monkey inside ExUnit — the first run of the full
    # suite with it active produced 22 unrelated failures.
    if Keyword.get(opts, :enabled, Application.get_env(:ls, :sentinel_enabled, true)) do
      schedule()
    end

    {:ok, %{reported: %{}}}
  end

  @impl true
  def handle_info(:sweep, state) do
    state = sweep(state)
    schedule()
    {:noreply, state}
  end

  defp sweep(state) do
    now = System.monotonic_time(:second)

    Process.list()
    |> Enum.reduce(state, fn pid, acc ->
      case Process.info(pid, :message_queue_len) do
        {:message_queue_len, mq} when mq > @peek_threshold ->
          handle_suspect(pid, mq, now, acc)

        _ ->
          acc
      end
    end)
  end

  defp handle_suspect(pid, mq, now, state) do
    # nil, not 0: monotonic time is NEGATIVE, so `now - 0 >= 60` was never
    # true and the sentinel silently reported nothing — caught by its own
    # test before it shipped inert.
    last = Map.get(state.reported, pid)

    state =
      if last == nil or now - last >= 60 do
        report(pid, mq)
        %{state | reported: Map.put(state.reported, pid, now)}
      else
        state
      end

    if mq > @kill_threshold and not exempt?(pid) do
      Logger.error("[SENTINEL] KILLING pid=#{inspect(pid)} mq=#{mq} — unbounded queue, see report above")
      Process.exit(pid, :kill)
    end

    state
  end

  defp report(pid, mq) do
    info =
      Process.info(pid, [
        :registered_name,
        :initial_call,
        :current_function,
        :current_stacktrace,
        :memory,
        :dictionary
      ]) || []

    # The first queued messages name the sender and protocol — the one thing
    # post-mortems of dead processes can never recover. Peeking copies the
    # whole mailbox, so only do it while the queue is still smallish.
    peek =
      if mq <= 10_000 do
        case Process.info(pid, :messages) do
          {:messages, [_ | _] = msgs} ->
            msgs |> Enum.take(3) |> Enum.map(&(inspect(&1, limit: 6) |> String.slice(0, 200)))

          _ ->
            []
        end
      else
        ["(queue too large to peek safely)"]
      end

    ancestors = get_in(info, [:dictionary, :"$ancestors"]) |> inspect() |> String.slice(0, 150)
    stack = (info[:current_stacktrace] || []) |> Enum.take(4) |> Enum.map(&inspect/1) |> Enum.join(" <- ")

    Logger.error("""
    [SENTINEL] runaway mailbox: pid=#{inspect(pid)} mq=#{mq} mem=#{div(info[:memory] || 0, 1_048_576)}MB
      name=#{inspect(info[:registered_name])} init=#{inspect(info[:initial_call])} now=#{inspect(info[:current_function])}
      ancestors=#{ancestors}
      stack=#{stack}
      queued=#{inspect(peek)}
    """)
  end

  defp exempt?(pid) do
    name =
      case Process.info(pid, :registered_name) do
        {:registered_name, n} when is_atom(n) -> n
        _ -> nil
      end

    name in @kill_exempt
  end

  defp schedule, do: Process.send_after(self(), :sweep, @sweep_ms)
end
