defmodule LS.Ops.Sentinel do
  @moduledoc """
  Master-only heartbeat that runs the ops alerts on a short interval and sends
  the weekly report at its slot. One GenServer, because both jobs read the same
  `LS.Metrics` and share the same `ls.ops_email_log` for cooldown/dedup — a
  separate scheduler each would be two things to reason about for no gain.

  * Every `@check_ms` (15 min): `LS.Alerts.run/0` — quiet unless something is
    wrong, cooldown-throttled so a standing problem is one email per 6h.
  * Weekly (`@weekly_dow` / `@weekly_hour` UTC): `LS.Report.Weekly.deliver/0`,
    deduped through `ops_email_log` so a restart in that hour can't double-send.

  Set `LS_ALERTS_DISABLED=1` to keep it idle (checks still callable by hand).
  Work runs in a supervised Task so a slow ClickHouse query never blocks the
  timer or piles ticks up.
  """

  use GenServer
  require Logger
  alias LS.Clickhouse

  @check_ms 15 * 60_000
  @first_ms 5 * 60_000
  @weekly_dow 1        # Monday
  @weekly_hour 8       # 08:xx UTC
  @weekly_min_gap_days 6

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Run the alert checks once now (returns the alerts sent)."
  def check_now, do: GenServer.call(__MODULE__, :check_now, 60_000)

  @doc "Send the weekly report now, regardless of schedule."
  def weekly_now, do: LS.Report.Weekly.deliver()

  @impl true
  def init(_opts) do
    disabled = System.get_env("LS_ALERTS_DISABLED") in ["1", "true"]
    unless disabled, do: Process.send_after(self(), :tick, @first_ms)
    Logger.info("🛎️  Ops sentinel started#{if disabled, do: " (disabled)", else: ""}")
    {:ok, %{disabled: disabled}}
  end

  @impl true
  def handle_call(:check_now, _from, s), do: {:reply, LS.Alerts.run(), s}

  @impl true
  def handle_info(:tick, s) do
    Process.send_after(self(), :tick, @check_ms)
    parent = self()

    Task.start(fn ->
      safe(&LS.Alerts.run/0, "alerts")
      if weekly_due?(), do: safe(fn -> send_weekly(parent) end, "weekly")
    end)

    {:noreply, s}
  end

  def handle_info(_, s), do: {:noreply, s}

  # ── weekly ──

  defp weekly_due? do
    now = DateTime.utc_now()
    Date.day_of_week(DateTime.to_date(now)) == @weekly_dow and now.hour == @weekly_hour and
      not sent_recently?("weekly_report", @weekly_min_gap_days)
  end

  defp send_weekly(_parent) do
    case LS.Report.Weekly.deliver() do
      :ok ->
        record("weekly_report", "ListSignal weekly")
        Logger.info("[SENTINEL] weekly report sent")

      other ->
        Logger.error("[SENTINEL] weekly report failed: #{inspect(other)}")
    end
  end

  defp sent_recently?(key, days) do
    case Clickhouse.query_raw("SELECT count() FROM ops_email_log WHERE key = '#{Clickhouse.escape_public(key)}' AND sent_at > now() - INTERVAL #{days} DAY", 5_000) do
      {:ok, [[n]]} -> to_i(n) > 0
      _ -> false   # never block a send on a read failure
    end
  end

  defp record(key, subject) do
    at = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_string()
    Clickhouse.insert_raw("INSERT INTO ops_email_log FORMAT JSONEachRow", Jason.encode!(%{key: key, sent_at: at, subject: subject}))
  end

  defp safe(fun, what) do
    fun.()
  rescue
    e -> Logger.error("[SENTINEL] #{what} crashed: #{Exception.message(e)}")
  catch
    :exit, r -> Logger.error("[SENTINEL] #{what} exited: #{inspect(r)}")
  end

  defp to_i(n) when is_integer(n), do: n
  defp to_i(n) when is_binary(n), do: (case Integer.parse(n) do
                                         {v, _} -> v
                                         :error -> 0
                                       end)
  defp to_i(_), do: 0
end
