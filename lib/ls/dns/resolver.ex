defmodule LS.DNS.Resolver do
  @moduledoc """
  DNS resolver using local Unbound server.
  Simple, fast, no rate limiting.
  Includes CNAME record lookups.
  """

  use GenServer
  require Logger

  @dns_server {{127, 0, 0, 1}, 53}
  @dns_timeout 8000
  @max_retries 3

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def lookup(domain) do
    lookup_with_retry(domain, 0)
  end

  defp lookup_with_retry(domain, retry_count) when retry_count < @max_retries do
    case perform_lookup(domain) do
      {:ok, results} ->
        GenServer.cast(__MODULE__, :record_success)
        {:ok, results}

      {:error, _reason} ->
        if retry_count < @max_retries - 1 do
          Process.sleep(100)
          lookup_with_retry(domain, retry_count + 1)
        else
          GenServer.cast(__MODULE__, :record_failure)
          {:error, :dns_error}
        end
    end
  end

  defp lookup_with_retry(_domain, _retry_count) do
    GenServer.cast(__MODULE__, :record_failure)
    {:error, :max_retries}
  end

  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @impl true
  def init(_opts) do
    state = %{
      total_queries: 0,
      successful_queries: 0,
      failed_queries: 0,
      start_time: System.monotonic_time(:second)
    }

    Logger.info("🌐 DNS Resolver: Using local Unbound (127.0.0.1:53)")

    {:ok, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    uptime = System.monotonic_time(:second) - state.start_time

    stats = %{
      uptime_seconds: uptime,
      total_queries: state.total_queries,
      successful_queries: state.successful_queries,
      failed_queries: state.failed_queries,
      success_rate: if state.total_queries > 0 do
        Float.round(state.successful_queries / state.total_queries * 100, 1)
      else
        0.0
      end
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_cast(:record_success, state) do
    {:noreply, %{state |
      total_queries: state.total_queries + 1,
      successful_queries: state.successful_queries + 1
    }}
  end

  @impl true
  def handle_cast(:record_failure, state) do
    {:noreply, %{state |
      total_queries: state.total_queries + 1,
      failed_queries: state.failed_queries + 1
    }}
  end

  defp perform_lookup(domain) do
    char_domain = String.to_charlist(domain)

    results = %{
      a: lookup_record(char_domain, :a),
      aaaa: lookup_record(char_domain, :aaaa),
      mx: lookup_record(char_domain, :mx),
      txt: lookup_record(char_domain, :txt),
      cname: lookup_cname(char_domain)
    }

    {:ok, results}
  rescue
    _e -> {:error, :exception}
  end

  defp lookup_record(char_domain, type) do
    case :inet_res.lookup(char_domain, :in, type, nameservers: [@dns_server], timeout: @dns_timeout) do
      [] -> []
      results when is_list(results) -> format_results(type, results)
      _ -> []
    end
  rescue
    _ -> []
  end

  # CNAME lookup - returns the canonical name(s)
  defp lookup_cname(char_domain) do
    case :inet_res.lookup(char_domain, :in, :cname, nameservers: [@dns_server], timeout: @dns_timeout) do
      [] -> []
      results when is_list(results) ->
        Enum.map(results, fn cname ->
          cname |> to_string() |> String.trim_trailing(".")
        end)
      _ -> []
    end
  rescue
    _ -> []
  end

  defp format_results(:a, results), do: Enum.map(results, &format_ip/1)
  defp format_results(:aaaa, results), do: Enum.map(results, &format_ipv6/1)

  defp format_results(:mx, results) do
    results
    |> Enum.sort_by(fn {priority, _host} -> priority end)
    |> Enum.map(fn {priority, host} -> "#{priority}:#{to_string(host)}" end)
  end

  defp format_results(:txt, results) do
    Enum.map(results, fn record ->
      record |> List.flatten() |> to_string() |> String.replace(["\n", "\r", ","], " ")
    end)
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"

  defp format_ipv6({a, b, c, d, e, f, g, h}) do
    [a, b, c, d, e, f, g, h] |> Enum.map(&Integer.to_string(&1, 16)) |> Enum.join(":")
  end
end
