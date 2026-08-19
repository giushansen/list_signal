defmodule LSWeb.Plugs.OverloadGuard do
  @moduledoc """
  Sheds load instead of letting the VM die.

  Bounds **requests in flight**, which is what actually consumes heap. Socket
  limits do not: a connection costs almost nothing until it becomes a request
  that assembles a page.

  On 2026-08-19 a 300-concurrent burst drove the BEAM from 0.8G to 6.3G, past
  its cgroup limit; with swap forbidden the kernel stalled the whole VM and
  the watchdog restarted it. Every request in flight was lost. Rejecting the
  excess with a 503 and `retry-after` costs a few visitors a retry; accepting
  it costs everyone the site.

  Static assets and health probes bypass the guard — they are cheap, and a
  probe that gets shed would make the watchdog restart a merely-busy app.
  """
  import Plug.Conn
  require Logger

  @counter :ls_inflight_requests

  # Comfortably above real demand: cached pages serve ~120/s and finish in
  # milliseconds, so 150 simultaneously in flight already implies something
  # pathological. Each in-flight page assembly can hold ~10-20MB, so this
  # bounds request memory near 2-3G — inside the 8G soft limit with room for
  # ETS and the reference tables.
  @max_inflight 150

  def init(opts), do: Keyword.get(opts, :max_inflight, @max_inflight)

  def call(conn, max) do
    if bypass?(conn) do
      conn
    else
      guard(conn, max)
    end
  end

  defp guard(conn, max) do
    current = :counters.get(counter(), 1)

    if current >= max do
      Logger.warning("[OVERLOAD] shed #{conn.request_path} — #{current} in flight (max #{max})")

      conn
      |> put_resp_header("retry-after", "2")
      |> put_resp_content_type("text/plain")
      |> send_resp(503, "Busy — please retry in a moment.")
      |> halt()
    else
      :counters.add(counter(), 1, 1)
      register_before_send(conn, fn c -> :counters.sub(counter(), 1, 1); c end)
    end
  end

  # Cheap paths that must never be shed.
  defp bypass?(%{request_path: "/health"}), do: true
  defp bypass?(%{request_path: "/pricing"}), do: false
  defp bypass?(%{request_path: path}), do: String.starts_with?(path, "/assets/")

  @doc "Requests currently in flight — for the admin dashboard."
  def in_flight, do: :counters.get(counter(), 1)

  @doc "Configured ceiling."
  def max_in_flight, do: @max_inflight

  defp counter do
    case :persistent_term.get(@counter, nil) do
      nil ->
        ref = :counters.new(1, [:write_concurrency])
        :persistent_term.put(@counter, ref)
        ref

      ref ->
        ref
    end
  end
end
