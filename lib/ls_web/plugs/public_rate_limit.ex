defmodule LSWeb.Plugs.PublicRateLimit do
  @moduledoc """
  A per-client ceiling on the public pages, in requests per minute.

  Why (2026-10-04, 00:00 to 01:00 UTC): one client fetched /website and
  /shopify pages at 130 to 1,000 a minute. Each page is a point read of
  the 58-column `domains` table (77 MB of granules across 17 parts for one
  row), so ClickHouse ran at 350% CPU on a 4-core master, load reached 20,
  the compaction pass and the nightly backup dump both hit the server's
  memory ceiling, in-flight batches timed out and were requeued, and the
  depth lane stranded 400 items. Every one of those is a symptom; the
  cause was an unmetered public endpoint.

  Sixty a minute per address is far above a reader and below a scraper.
  Over the limit a client gets 429 with Retry-After, the standard signal
  search engines honour by slowing down. The address is Cloudflare's
  `cf-connecting-ip` (the origin only answers Cloudflare), else the first
  `x-forwarded-for` entry, else the socket. `LS_PUBLIC_RATE_PER_MIN`
  overrides the limit.

  Fixed one-minute windows in a public ETS table owned by a process that
  lives as long as the node (LS.HTTP.NodeBudget learnt that lesson). The
  table is swept of old windows on the way through, so it stays small.
  """
  import Plug.Conn
  require Logger

  @table :public_rate_limiter
  @default_per_min 60

  def init(opts), do: opts

  def call(conn, _opts) do
    ip = client_ip(conn)

    case if(local?(conn), do: :ok, else: hit(ip, per_min())) do
      :ok ->
        conn

      :over ->
        Logger.warning("[PUBLIC RATE] #{ip} over #{per_min()}/min on #{conn.request_path}")

        conn
        |> put_resp_header("retry-after", "60")
        |> put_resp_content_type("text/plain")
        |> send_resp(429, "Too many requests. Please keep it under #{per_min()} a minute.")
        |> halt()
    end
  end

  @doc "The ceiling, requests per minute per client."
  def per_min do
    case System.get_env("LS_PUBLIC_RATE_PER_MIN") do
      nil -> @default_per_min
      v -> (case Integer.parse(v) do {n, _} when n > 0 -> n; _ -> @default_per_min end)
    end
  end

  @doc """
  Pure given the window: count one request for `ip` in `window` (a minute
  number) and say whether it is within `limit`. A table that cannot be
  reached fails open: a limiter must never take the site down.
  """
  @spec hit(String.t(), pos_integer(), integer()) :: :ok | :over
  def hit(ip, limit, window \\ div(System.system_time(:second), 60)) do
    init_table()
    key = {ip, window}
    count = :ets.update_counter(@table, key, {2, 1}, {key, 0})
    if count == 1 and :erlang.phash2(ip, 32) == 0, do: sweep(window)
    if count <= limit, do: :ok, else: :over
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Pure: a request from the loopback interface that Cloudflare did not
  forward is the box itself (the web watchdog's probe every minute, the
  sentinel, the test suite), not the public. It is never counted.
  """
  @spec local?(Plug.Conn.t()) :: boolean()
  def local?(conn) do
    get_req_header(conn, "cf-connecting-ip") == [] and conn.remote_ip in [{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}]
  end

  @doc "The client address as the limiter sees it."
  @spec client_ip(Plug.Conn.t()) :: String.t()
  def client_ip(conn) do
    case get_req_header(conn, "cf-connecting-ip") do
      [ip | _] when ip != "" ->
        String.trim(ip)

      _ ->
        case get_req_header(conn, "x-forwarded-for") do
          [list | _] when list != "" -> list |> String.split(",") |> hd() |> String.trim()
          _ -> conn.remote_ip |> :inet.ntoa() |> to_string()
        end
    end
  end

  defp sweep(window) do
    :ets.select_delete(@table, [{{{:_, :"$1"}, :_}, [{:<, :"$1", window - 1}], [true]}])
  end

  defp init_table do
    if :ets.whereis(@table) == :undefined do
      parent = self()

      spawn(fn ->
        try do
          :ets.new(@table, [:set, :public, :named_table, write_concurrency: true])
          send(parent, {:public_rate_table, :created})
          Process.sleep(:infinity)
        rescue
          ArgumentError -> send(parent, {:public_rate_table, :exists})
        end
      end)

      receive do
        {:public_rate_table, _} -> :ok
      after
        2_000 -> :ok
      end
    end

    :ok
  end
end
