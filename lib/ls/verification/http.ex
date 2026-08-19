defmodule LS.Verification.HTTP do
  @moduledoc """
  The one HTTP door for pipeline 3: bulk downloads to disk and small JSON
  GET/POSTs, always with our identifying User-Agent, always sequential per
  host with a minimum gap between requests.

  These are official endpoints (sec.gov, data.gouv.fr, query.wikidata.org…).
  Nothing here is stealthy on purpose: against an authority, IP-spreading looks
  like ban evasion, and one polite client is what their fair-use policies ask
  for. Published limits we obey: SEC ≤ 10 req/s (we do ≪ 1), WDQS one query
  at a time with a real UA, Algolia/YC public search key as their site uses it.
  Rate limiting is per host in ETS so concurrent sources never gang up on one.
  """

  require Logger

  @table :verification_http_last
  @default_gap_ms 1_000
  @retries 3

  @doc false
  def init do
    if :ets.whereis(@table) == :undefined,
      do: :ets.new(@table, [:set, :public, :named_table])

    :ok
  end

  @doc """
  Download `url` to `path` (atomically via `path.part`), streaming, so a
  1.5 GB SEC zip never touches the heap. Returns `{:ok, bytes}`.
  """
  @spec download(String.t(), Path.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def download(url, path, opts \\ []) do
    File.mkdir_p!(Path.dirname(path))
    part = path <> ".part"
    throttle(url, opts)

    result =
      with_retries(fn ->
        file = File.open!(part, [:write, :binary])

        try do
          Req.get(url,
            headers: headers(opts),
            finch: LS.Finch.Bulk,
            receive_timeout: Keyword.get(opts, :timeout, 3_600_000),
            retry: false,
            decode_body: false,
            into: fn {:data, chunk}, {req, resp} ->
              IO.binwrite(file, chunk)
              {:cont, {req, resp}}
            end
          )
        after
          File.close(file)
        end
      end)

    case result do
      {:ok, %{status: 200}} ->
        File.rename!(part, path)
        {:ok, File.stat!(path).size}

      {:ok, %{status: s}} ->
        File.rm(part)
        {:error, {:http, s}}

      {:error, reason} ->
        File.rm(part)
        {:error, reason}
    end
  end

  @doc "GET `url` and decode JSON. `params` go on the query string."
  @spec get_json(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def get_json(url, opts \\ []) do
    throttle(url, opts)

    with_retries(fn ->
      Req.get(url,
        params: Keyword.get(opts, :params, []),
        headers: headers(opts),
        finch: LS.Finch.Bulk,
        receive_timeout: Keyword.get(opts, :timeout, 120_000),
        retry: false
      )
    end)
    |> json_result()
  end

  @doc "POST a JSON body and decode the JSON reply."
  @spec post_json(String.t(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def post_json(url, body, opts \\ []) do
    throttle(url, opts)

    with_retries(fn ->
      Req.post(url,
        json: body,
        headers: headers(opts),
        finch: LS.Finch.Bulk,
        receive_timeout: Keyword.get(opts, :timeout, 120_000),
        retry: false
      )
    end)
    |> json_result()
  end

  @doc "GET `url` and return the raw body (small pages only)."
  def get_body(url, opts \\ []) do
    throttle(url, opts)

    case with_retries(fn ->
           Req.get(url, headers: headers(opts), finch: LS.Finch.Bulk, retry: false,
             receive_timeout: Keyword.get(opts, :timeout, 60_000))
         end) do
      {:ok, %{status: 200, body: b}} when is_binary(b) -> {:ok, b}
      {:ok, %{status: s}} -> {:error, {:http, s}}
      err -> err
    end
  end

  defp json_result({:ok, %{status: 200, body: body}}) when is_map(body) or is_list(body), do: {:ok, body}

  defp json_result({:ok, %{status: 200, body: body}}) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, v} -> {:ok, v}
      {:error, e} -> {:error, {:json, Exception.message(e)}}
    end
  end

  defp json_result({:ok, %{status: s, body: b}}), do: {:error, {:http, s, String.slice(to_string(inspect(b)), 0, 200)}}
  defp json_result(err), do: err

  defp headers(opts) do
    [{"user-agent", LS.Verification.user_agent()}, {"accept-encoding", "gzip"}] ++
      Keyword.get(opts, :headers, [])
  end

  # Retry only on transport errors and 5xx/429 — a 404 is an answer.
  defp with_retries(fun, attempt \\ 1) do
    case fun.() do
      {:ok, %{status: s}} = ok when s < 500 and s != 429 -> ok
      {:ok, %{status: s}} = res ->
        if attempt < @retries do
          Logger.warning("[VERIFY] HTTP #{s}, retry #{attempt}/#{@retries}")
          Process.sleep(backoff(attempt))
          with_retries(fun, attempt + 1)
        else
          res
        end

      {:error, reason} = err ->
        if attempt < @retries do
          Logger.warning("[VERIFY] HTTP error #{inspect(reason)}, retry #{attempt}/#{@retries}")
          Process.sleep(backoff(attempt))
          with_retries(fun, attempt + 1)
        else
          err
        end
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp backoff(attempt), do: 5_000 * attempt * attempt

  # One request at a time per host, ≥ `gap_ms` apart. Sleeping is fine: every
  # caller is a background job with hours to spare.
  defp throttle(url, opts) do
    init()
    host = URI.parse(url).host || url
    gap = Keyword.get(opts, :gap_ms, @default_gap_ms)
    now = System.monotonic_time(:millisecond)

    last =
      case :ets.lookup(@table, host) do
        [{_, t}] -> t
        _ -> now - gap
      end

    wait = max(0, last + gap - now)
    :ets.insert(@table, {host, now + wait})
    if wait > 0, do: Process.sleep(wait)
    :ok
  end
end
