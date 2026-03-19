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

  @accept_languages [
    "en-US,en;q=0.9",
    "en-GB,en;q=0.9,en-US;q=0.8",
    "en-US,en;q=0.9,fr;q=0.8"
  ]

  @doc """
  Fetch domain using provided IP for rate limiting.
  Returns {:error, :rate_limited} immediately if IP is rate-limited.
  """
  def fetch(domain, ip) do
    # Check rate limiter FIRST - DON'T sleep, return error immediately
    case IPRateLimiter.check_and_update(ip, 1000) do
      :ok ->
        fetch_with_redirects(domain, ip, 0)

      {:wait, wait_ms} ->
        Process.sleep(wait_ms)
        {:error, "rate_limited", :rate_limited}
    end
  end

  defp fetch_with_redirects(_domain, _ip, redirect_count) when redirect_count > @max_redirects do
    {:error, "too_many_redirects", :too_many_redirects}
  end

  defp fetch_with_redirects(domain, _ip, redirect_count) do
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
        perform_request(conn, domain, start_time, redirect_count)

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

  defp perform_request(conn, domain, start_time, redirect_count) do
    headers = build_headers(domain)

    case Mint.HTTP.request(conn, "GET", "/", headers, nil) do
      {:ok, conn, request_ref} ->
        receive_response(conn, request_ref, start_time, redirect_count)

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

  defp receive_response(conn, request_ref, start_time, redirect_count) do
    # Start receive timeout
    receive_deadline = System.monotonic_time(:millisecond) + @receive_timeout

    result = do_receive_response(conn, request_ref, %{
      status: nil,
      headers: [],
      body: <<>>,
      size: 0,
      elapsed_ms: 0
    }, receive_deadline)

    Mint.HTTP.close(conn)

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
                  fetch_with_redirects(new_host, "0.0.0.0", redirect_count + 1)
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

  defp do_receive_response(conn, request_ref, acc, deadline) do
    # Check timeout
    now = System.monotonic_time(:millisecond)
    if now >= deadline do
      {:error, "receive_timeout"}
    else
      timeout_ms = deadline - now

      receive do
        message ->
          case Mint.HTTP.stream(conn, message) do
            {:ok, conn, responses} ->
              case process_responses(responses, request_ref, acc) do
                {:done, response} ->
                  {:ok, response}

                {:continue, new_acc} ->
                  if new_acc.size >= @max_body_bytes do
                    {:ok, new_acc}
                  else
                    do_receive_response(conn, request_ref, new_acc, deadline)
                  end

                {:error, reason} ->
                  {:error, reason}
              end

            {:error, _conn, error, _responses} ->
              {:error, format_error(error)}

            :unknown ->
              do_receive_response(conn, request_ref, acc, deadline)
          end
      after
        timeout_ms -> {:error, "receive_timeout"}
      end
    end
  end

  defp process_responses([], _request_ref, acc), do: {:continue, acc}
  defp process_responses([response | rest], request_ref, acc) do
    case response do
      {:status, ^request_ref, status} ->
        process_responses(rest, request_ref, %{acc | status: status})

      {:headers, ^request_ref, headers} ->
        all_headers = acc.headers ++ headers
        process_responses(rest, request_ref, %{acc | headers: all_headers})

      {:data, ^request_ref, chunk} ->
        new_body = acc.body <> chunk
        new_size = acc.size + byte_size(chunk)

        if new_size >= @max_body_bytes do
          {:done, %{acc | body: new_body, size: new_size}}
        else
          process_responses(rest, request_ref, %{acc | body: new_body, size: new_size})
        end

      {:done, ^request_ref} ->
        {:done, acc}

      {:error, ^request_ref, reason} ->
        {:error, format_error(reason)}

      _other ->
        process_responses(rest, request_ref, acc)
    end
  end

  defp build_headers(domain) do
    [
      {"host", domain},
      {"user-agent", Enum.random(@user_agents)},
      {"accept", Enum.random(@accept_headers)},
      {"accept-language", Enum.random(@accept_languages)},
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
