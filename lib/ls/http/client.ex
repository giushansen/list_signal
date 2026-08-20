defmodule LS.HTTP.Client do
  @moduledoc """
  Simple HTTP client with IP-based rate limiting.

  CRITICAL: Does NOT sleep in worker threads - returns {:error, :rate_limited} immediately
  to avoid thundering herd problem with shared hosting IPs.
  """

  require Logger
  alias LS.HTTP.{IPRateLimiter, PerformanceTracker}

  @max_body_bytes 512_000
  @connect_timeout 10_000
  @receive_timeout 20_000
  @max_redirects 3

  @user_agents [
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Safari/605.1.15",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:121.0) Gecko/20100101 Firefox/121.0",
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:121.0) Gecko/20100101 Firefox/121.0"
  ]

  @accept_headers [
    "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8",
    "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
    "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
  ]

  @doc """
  Fetch domain using provided IP for rate limiting.
  Returns {:error, :rate_limited} immediately if IP is rate-limited.
  """
  def fetch(domain, ip), do: fetch(domain, ip, [])

  @doc """
  Fetch an absolute URL on a **third-party host** (ATS job boards, etc).

  Resolves the host, then goes through the ordinary `fetch/3` path so the
  per-IP politeness limiter still applies — API hosts like
  `boards-api.greenhouse.io` serve thousands of our targets from a handful of
  IPs, so they are exactly the case that must not be hammered.
  """
  @spec fetch_url(String.t(), keyword()) :: {:ok, map()} | {:error, term()} | {:error, term(), term()}
  def fetch_url(url, opts \\ []) when is_binary(url) do
    uri = URI.parse(url)
    path = [uri.path || "/", if(uri.query, do: "?" <> uri.query, else: "")] |> Enum.join()

    case uri.host && LS.DNS.Resolver.lookup(uri.host) do
      {:ok, %{a: [ip | _]}} -> fetch(uri.host, ip, Keyword.put(opts, :path, path))
      _ -> {:error, :no_ip}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Fetch a specific `path` on `domain` (default "/"), reusing the SAME per-IP rate
  limiter, TLS connection logic, and `@max_body_bytes` cap. Options:

    * `:path`      — request path, defaults to "/"
    * `:timeout`   — receive timeout in ms, defaults to `@receive_timeout`
    * `:max_bytes` — body cap, defaults to `@max_body_bytes` (512 KB).

  Raise `:max_bytes` only for structured endpoints we chose deliberately
  (e.g. Shopify `/products.json`): the default guards against multi-megabyte
  HTML, but silently truncating a JSON document makes it undecodable, which
  looks like "no data" rather than an error.

  Used for best-effort secondary-page (login/pricing) tech detection. The rate
  limiter is ALWAYS consulted so secondary fetches stay polite.
  """
  # No IP, no fetch. The per-IP rate limiter keys on the resolved address, so
  # without one there is no way to stay polite — and politeness is what keeps
  # our source IPs off blocklists. We refuse rather than bypass the limiter.
  #
  # This clause also stops a silent failure: `IPRateLimiter.check_and_update/2`
  # is guarded by `is_binary(ip)`, so a nil IP used to raise FunctionClauseError.
  # Callers that wrap fetches in a `rescue` (LS.Enrichment.Shopify) turned that
  # crash into "this store has no catalog", losing data with no error logged.
  def fetch(_domain, nil, opts) when is_list(opts), do: {:error, "no_ip", :no_ip}

  def fetch(domain, ip, opts) when is_list(opts) do
    path = Keyword.get(opts, :path, "/")
    recv_timeout = Keyword.get(opts, :timeout, @receive_timeout)
    max_bytes = Keyword.get(opts, :max_bytes, @max_body_bytes)
    retries = Keyword.get(opts, :politeness_retries, 1)

    attempt_fetch(domain, ip, path, recv_timeout, max_bytes, retries)
  end

  # We used to sleep the full politeness interval and then give up WITHOUT
  # sending the request — paying the entire latency cost for no data. Enriching
  # one business hits the same IP several times (products.json ×2,
  # collections.json, /contact, /pricing, /careers), so with 1s spacing most of
  # those calls returned :rate_limited and the child tables came out far
  # emptier than the crawl suggested.
  #
  # Waiting and then proceeding is strictly MORE polite than before: the full
  # interval still elapses between attempts, we just stop wasting it. The
  # retry count is BOUNDED (`:politeness_retries`, default 1) so heavy
  # contention can never turn into an unbounded wait loop. The enrichment lane
  # passes 3: on a node that also runs discovery, CDN IPs (Cloudflare et al.)
  # are so contended that a single retry lost most secondary pages — measured
  # on prod 2026-07-29: only 65 of 299 contact-page domains yielded contacts.
  # Discovery keeps the default 1; it is throughput-bound and disposable.
  defp attempt_fetch(domain, ip, path, recv_timeout, max_bytes, retries_left) do
    case IPRateLimiter.check_and_update(ip, 1000) do
      :ok ->
        fetch_with_redirects(domain, ip, 0, path, recv_timeout, max_bytes)

      {:wait, wait_ms} when retries_left > 0 ->
        Process.sleep(wait_ms)
        attempt_fetch(domain, ip, path, recv_timeout, max_bytes, retries_left - 1)

      {:wait, _} ->
        {:error, "rate_limited", :rate_limited}
    end
  end

  defp fetch_with_redirects(_domain, _ip, redirect_count, _path, _recv_timeout, _max_bytes)
       when redirect_count > @max_redirects do
    {:error, "too_many_redirects", :too_many_redirects}
  end

  defp fetch_with_redirects(domain, _ip, redirect_count, path, recv_timeout, max_bytes) do
    start_time = System.monotonic_time(:millisecond)

    # Mint connection options
    opts = [
      timeout: @connect_timeout,
      protocols: [:http1],
      transport_opts: [
        inet6: false,
        nodelay: true,
        keepalive: false,
        verify: :verify_none,
        versions: [:"tlsv1.3", :"tlsv1.2"],
        reuse_sessions: false,
        session_tickets: :disabled
      ]
    ]

    case Mint.HTTP.connect(:https, domain, 443, opts) do
      {:ok, conn} ->
        perform_request(conn, domain, start_time, redirect_count, path, recv_timeout, max_bytes)

      {:error, error} ->
        reason = format_error(error)
        track_error(reason)
        {:error, reason, error}
    end
  rescue
    error ->
      reason = "crash:#{Exception.message(error)}"
      track_error(reason)
      {:error, reason, error}
  end

  defp perform_request(conn, domain, start_time, redirect_count, path, recv_timeout, max_bytes) do
    headers = build_headers(domain)

    case Mint.HTTP.request(conn, "GET", path, headers, nil) do
      {:ok, conn, request_ref} ->
        receive_response(conn, request_ref, start_time, redirect_count, path, recv_timeout, max_bytes)

      {:error, _conn, error} ->
        reason = format_error(error)
        track_error(reason)
        {:error, reason, error}
    end
  rescue
    error ->
      Mint.HTTP.close(conn)
      reason = "request_crash:#{Exception.message(error)}"
      track_error(reason)
      {:error, reason, error}
  end

  defp receive_response(conn, request_ref, start_time, redirect_count, path, recv_timeout, max_bytes) do
    # Start receive timeout
    receive_deadline = System.monotonic_time(:millisecond) + recv_timeout

    result = do_receive_response(conn, request_ref, %{
      status: nil,
      headers: [],
      body: <<>>,
      size: 0,
      elapsed_ms: 0
    }, receive_deadline, max_bytes)

    # Close the conn RETURNED by the receive loop, not the pre-request one:
    # Mint conns are immutable snapshots, and closing a stale snapshot after
    # the loop has advanced the socket state is what let a capped fetch leave
    # its socket half-open. Always close before parsing begins.
    result =
      case result do
        {:ok, final_conn, response} ->
          Mint.HTTP.close(final_conn)
          {:ok, response}

        {:error, final_conn, reason} ->
          Mint.HTTP.close(final_conn)
          {:error, reason}
      end

    case result do
      {:ok, response} ->
        elapsed_ms = System.monotonic_time(:millisecond) - start_time
        track_success(elapsed_ms)

        # Handle redirects
        if response.status in [301, 302, 303, 307, 308] do
          case get_redirect_location(response.headers) do
            {:ok, location} when is_binary(location) ->
              # Follow redirect
              case URI.parse(location) do
                %URI{host: new_host} when is_binary(new_host) and new_host != "" ->
                  fetch_with_redirects(new_host, "0.0.0.0", redirect_count + 1, path, recv_timeout, max_bytes)
                _ ->
                  {:ok, %{response | elapsed_ms: elapsed_ms}}
              end
            _ ->
              {:ok, %{response | elapsed_ms: elapsed_ms}}
          end
        else
          {:ok, %{response | elapsed_ms: elapsed_ms}}
        end

      {:error, reason} ->
        track_error(reason)
        {:error, reason, :receive_error}
    end
  rescue
    error ->
      Mint.HTTP.close(conn)
      reason = "receive_crash:#{Exception.message(error)}"
      track_error(reason)
      {:error, reason, error}
  end

  defp do_receive_response(conn, request_ref, acc, deadline, max_bytes) do
    # Check timeout
    now = System.monotonic_time(:millisecond)
    if now >= deadline do
      {:error, conn, "receive_timeout"}
    else
      timeout_ms = deadline - now

      receive do
        message ->
          case Mint.HTTP.stream(conn, message) do
            {:ok, conn, responses} ->
              case process_responses(responses, request_ref, acc, max_bytes) do
                {:done, response} ->
                  {:ok, conn, response}

                {:continue, new_acc} ->
                  if new_acc.size >= max_bytes do
                    # Hitting the cap ABANDONS the stream — the conn must go
                    # back to the caller to be closed. This used to return
                    # without it, leaving an active-mode socket spraying the
                    # rest of the page into the mailbox as messages while the
                    # extractors ran regexes: the 2026-08-19 incident process
                    # had 79,768 queued socket messages (~a still-streaming
                    # 110MB page) and pinned a core mid-:re.grun.
                    {:ok, conn, new_acc}
                  else
                    do_receive_response(conn, request_ref, new_acc, deadline, max_bytes)
                  end

                {:error, reason} ->
                  {:error, conn, reason}
              end

            {:error, conn, error, _responses} ->
              {:error, conn, format_error(error)}

            :unknown ->
              do_receive_response(conn, request_ref, acc, deadline, max_bytes)
          end
      after
        timeout_ms -> {:error, conn, "receive_timeout"}
      end
    end
  end

  defp process_responses([], _request_ref, acc, _max_bytes), do: {:continue, acc}
  defp process_responses([response | rest], request_ref, acc, max_bytes) do
    case response do
      {:status, ^request_ref, status} ->
        process_responses(rest, request_ref, %{acc | status: status}, max_bytes)

      {:headers, ^request_ref, headers} ->
        all_headers = acc.headers ++ headers
        process_responses(rest, request_ref, %{acc | headers: all_headers}, max_bytes)

      {:data, ^request_ref, chunk} ->
        new_body = acc.body <> chunk
        new_size = acc.size + byte_size(chunk)

        if new_size >= max_bytes do
          {:done, %{acc | body: new_body, size: new_size}}
        else
          process_responses(rest, request_ref, %{acc | body: new_body, size: new_size}, max_bytes)
        end

      {:done, ^request_ref} ->
        {:done, acc}

      {:error, ^request_ref, reason} ->
        {:error, format_error(reason)}

      _other ->
        process_responses(rest, request_ref, acc, max_bytes)
    end
  end

  defp build_headers(domain) do
    [
      {"host", domain},
      {"user-agent", Enum.random(@user_agents)},
      {"accept", Enum.random(@accept_headers)},
      # Force English so sites that localize by Accept-Language/IP serve English
      # (otherwise e.g. facebook.com is detected as French).
      {"accept-language", "en-US,en;q=0.9"},
      {"accept-encoding", "identity"},
      {"connection", "close"},
      {"upgrade-insecure-requests", "1"},
      {"sec-fetch-dest", "document"},
      {"sec-fetch-mode", "navigate"},
      {"sec-fetch-site", "none"}
    ]
  end

  defp get_redirect_location(headers) do
    case List.keyfind(headers, "location", 0) do
      {"location", location} -> {:ok, location}
      _ -> {:error, :no_location}
    end
  end

  defp format_error(%Mint.TransportError{reason: reason}), do: "transport:#{inspect(reason)}"
  defp format_error(%Mint.HTTPError{reason: reason}), do: "http:#{inspect(reason)}"
  defp format_error(error) when is_atom(error), do: Atom.to_string(error)
  defp format_error(error), do: inspect(error)

  defp track_success(elapsed_ms) do
    PerformanceTracker.record_success(elapsed_ms)
  catch
    _, _ -> :ok
  end

  defp track_error(reason) when is_binary(reason) do
    PerformanceTracker.record_error(reason)
  catch
    _, _ -> :ok
  end
  defp track_error(_), do: :ok
end
