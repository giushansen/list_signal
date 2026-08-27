defmodule LSWeb.Plugs.OverloadGuard do
  @moduledoc """
  Sheds load when the VM is actually running out of memory.

  ## Why memory and not a request counter

  The first version counted requests in flight and decremented in
  `register_before_send`. That decrement does not run when a request times out
  or its process dies, so on 2026-08-19 a burst of timeouts leaked the
  counter above its ceiling and the site returned 503 to **every** visitor
  until it was restarted. A guard that can fail closed permanently is worse
  than no guard: it converts a transient spike into an indefinite outage.

  Memory has no such failure mode. It is observed, not accounted: if usage
  falls, shedding stops by itself. There is no state to leak, nothing to
  reconcile, and a stuck sampler fails OPEN (see `over_threshold?/0`).

  ## What it protects against

  The BEAM growing past its cgroup limit. With swap forbidden, crossing that
  limit leaves the kernel only one lever, stall the whole VM, and the
  watchdog then restarts it, dropping every request in flight. Shedding the
  marginal request keeps the rest of the site serving.
  """
  import Plug.Conn
  require Logger

  @key {__MODULE__, :memory_state}

  # Shed above this fraction of the cgroup soft limit. 0.80 of 6G is ~4.9G,
  # comfortably above the ~2.2G steady state and below the 6.3G excursion that
  # caused the outage, so normal traffic never sees a 503.
  @shed_ratio 0.80

  def init(opts), do: opts

  def call(conn, _opts) do
    if bypass?(conn) or not over_threshold?() do
      conn
    else
      Logger.warning("[OVERLOAD] shed #{conn.request_path}, #{div(current_bytes(), 1_048_576)}MB in use")

      conn
      |> put_resp_header("retry-after", "2")
      |> put_resp_content_type("text/plain")
      |> send_resp(503, "Busy, please retry in a moment.")
      |> halt()
    end
  end

  @doc """
  True when the VM is above the shed threshold.

  Fails OPEN: if the sampler has not published a reading, or the reading is
  stale, requests are served. A monitoring failure must never take the site
  down, that is the mistake this module exists to correct.
  """
  def over_threshold? do
    case :persistent_term.get(@key, nil) do
      {bytes, limit, sampled_at} ->
        fresh? = System.monotonic_time(:second) - sampled_at < 10
        fresh? and limit > 0 and bytes > limit * @shed_ratio

      _ ->
        false
    end
  end

  @doc "Latest sampled usage in bytes (0 if never sampled)."
  def current_bytes do
    case :persistent_term.get(@key, nil) do
      {bytes, _limit, _at} -> bytes
      _ -> 0
    end
  end

  @doc "The limit shedding is measured against, in bytes."
  def limit_bytes do
    case :persistent_term.get(@key, nil) do
      {_bytes, limit, _at} -> limit
      _ -> 0
    end
  end

  @doc false
  def publish(bytes, limit) do
    :persistent_term.put(@key, {bytes, limit, System.monotonic_time(:second)})
  end

  @doc "Fraction of the limit currently used, for the admin dashboard."
  def utilisation do
    l = limit_bytes()
    if l > 0, do: current_bytes() / l, else: 0.0
  end

  def shed_ratio, do: @shed_ratio

  # Cheap paths that must never be shed: assets are nearly free, and shedding
  # the health probe would make the watchdog restart a merely-busy app.
  defp bypass?(%{request_path: "/health"}), do: true
  defp bypass?(%{request_path: path}), do: String.starts_with?(path, "/assets/")
end
