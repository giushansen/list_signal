defmodule LS.RDAP.Client do
  @moduledoc """
  RDAP domain lookup client.

  Downloads IANA bootstrap JSON at boot to map TLDs → RDAP server URLs.
  Rate-limited **per RDAP server host** — load fans out across hundreds of servers.

  ## Usage

      LS.RDAP.Client.lookup("stripe.com")
      #=> {:ok, %{domain_created_at: "2004-09-03T00:00:00Z", registrar: "MarkMonitor Inc.", ...}}
  """

  use GenServer
  require Logger

  @bootstrap_url "https://data.iana.org/rdap/dns.json"
  @bootstrap_table :rdap_bootstrap
  @rate_table :rdap_rates
  @req_timeout 10_000
  @default_rate_per_sec 1

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Lookup RDAP data for a domain. Returns {:ok, map} or {:error, reason}."
  def lookup(domain) when is_binary(domain) do
    tld = domain |> String.split(".") |> List.last() |> String.downcase()
    case find_server(tld) do
      nil -> {:error, :no_rdap_server}
      server_url -> query(server_url, domain)
    end
  end

  def stats, do: GenServer.call(__MODULE__, :stats)

  @impl true
  def init(_opts) do
    :ets.new(@bootstrap_table, [:set, :public, :named_table, read_concurrency: true])
    :ets.new(@rate_table, [:set, :public, :named_table, write_concurrency: true])
    rate = System.get_env("LS_RDAP_RATE", "#{@default_rate_per_sec}") |> String.to_integer()
    state = %{rate_per_sec: rate, total_queries: 0, total_hits: 0,
              total_errors: 0, total_rate_limited: 0,
              bootstrap_loaded: false, bootstrap_tlds: 0,
              start_time: System.monotonic_time(:second)}
    send(self(), :load_bootstrap)
    Logger.info("🔍 RDAP Client starting (rate: #{rate}/sec per server)")
    {:ok, state}
  end

  @impl true
  def handle_info(:load_bootstrap, state) do
    case load_bootstrap() do
      {:ok, count} ->
        Logger.info("✅ RDAP bootstrap: #{count} TLD mappings")
        {:noreply, %{state | bootstrap_loaded: true, bootstrap_tlds: count}}
      {:error, reason} ->
        Logger.warning("⚠️  RDAP bootstrap failed: #{inspect(reason)}, retry 60s")
        Process.send_after(self(), :load_bootstrap, 60_000)
        {:noreply, state}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply, Map.take(state, [:total_queries, :total_hits, :total_errors,
      :total_rate_limited, :bootstrap_loaded, :bootstrap_tlds, :rate_per_sec]), state}
  end

  @impl true
  def handle_cast({:record, :hit}, s), do: {:noreply, %{s | total_queries: s.total_queries + 1, total_hits: s.total_hits + 1}}
  def handle_cast({:record, :error}, s), do: {:noreply, %{s | total_queries: s.total_queries + 1, total_errors: s.total_errors + 1}}
  def handle_cast({:record, :rate_limited}, s), do: {:noreply, %{s | total_rate_limited: s.total_rate_limited + 1}}

  # Bootstrap
  defp load_bootstrap do
    case Req.get(@bootstrap_url, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: %{"services" => services}}} ->
        count = Enum.reduce(services, 0, fn [tlds, urls], acc ->
          url = List.first(urls)
          if url do
            url = if String.ends_with?(url, "/"), do: url, else: url <> "/"
            Enum.each(tlds, fn tld -> :ets.insert(@bootstrap_table, {String.downcase(tld), url}) end)
            acc + length(tlds)
          else acc end
        end)
        {:ok, count}
      {:ok, %{status: s}} -> {:error, {:http, s}}
      {:error, r} -> {:error, r}
    end
  rescue e -> {:error, Exception.message(e)}
  end

  defp find_server(tld) do
    case :ets.lookup(@bootstrap_table, tld) do
      [{^tld, url}] -> url
      [] -> nil
    end
  end

  # Query with per-server rate limiting
  defp query(server_url, domain) do
    host = URI.parse(server_url).host
    if rate_allowed?(host) do
      url = "#{server_url}domain/#{domain}"
      case Req.get(url, receive_timeout: @req_timeout, redirect: true, max_redirects: 3, retry: false, retry: false, retry_delay: fn _ -> 30_000 end,
                        headers: [{"accept", "application/rdap+json"}]) do
        {:ok, %{status: 200, body: body}} when is_map(body) ->
          GenServer.cast(__MODULE__, {:record, :hit})
          {:ok, parse_response(body)}
        {:ok, %{status: 404}} ->
          GenServer.cast(__MODULE__, {:record, :error})
          {:error, :not_found}
        {:ok, %{status: 429}} ->
          GenServer.cast(__MODULE__, {:record, :rate_limited})
          {:error, :rate_limited}
        {:ok, %{status: s}} ->
          GenServer.cast(__MODULE__, {:record, :error})
          {:error, {:http, s}}
        {:error, r} ->
          GenServer.cast(__MODULE__, {:record, :error})
          {:error, r}
      end
    else
      GenServer.cast(__MODULE__, {:record, :rate_limited})
      {:error, :rate_limited}
    end
  rescue e ->
    GenServer.cast(__MODULE__, {:record, :error})
    {:error, Exception.message(e)}
  end

  defp rate_allowed?(host) do
    now_ms = System.system_time(:millisecond)
    interval_ms = div(1000, @default_rate_per_sec)
    case :ets.lookup(@rate_table, host) do
      [{^host, last_ms}] when now_ms - last_ms < interval_ms -> false
      _ -> :ets.insert(@rate_table, {host, now_ms}); true
    end
  end

  # RFC 9083 response parsing
  defp parse_response(body) do
    events = Map.get(body, "events", [])
    entities = Map.get(body, "entities", [])
    nameservers = Map.get(body, "nameservers", [])
    status = Map.get(body, "status", [])
    secure_dns = Map.get(body, "secureDNS", %{})

    %{
      domain_created_at: find_event(events, "registration"),
      domain_expires_at: find_event(events, "expiration"),
      domain_updated_at: find_event(events, "last changed"),
      registrar: find_registrar_name(entities),
      registrar_iana_id: find_registrar_iana_id(entities),
      registrant_country: find_registrant_country(entities),
      nameservers: nameservers |> Enum.map(&get_in(&1, ["ldhName"])) |> Enum.reject(&is_nil/1) |> Enum.join("|"),
      status: Enum.join(status, "|"),
      dnssec: to_string(Map.get(secure_dns, "delegationSigned", false))
    }
  end

  defp find_event(events, action) do
    case Enum.find(events, fn e -> e["eventAction"] == action end) do
      %{"eventDate" => d} -> d
      _ -> nil
    end
  end

  defp find_registrar_name(entities) do
    case Enum.find(entities, fn e -> "registrar" in (Map.get(e, "roles", [])) end) do
      %{"vcardArray" => [_, fields]} -> extract_vcard_fn(fields)
      %{"handle" => h} -> h
      _ -> ""
    end
  end

  defp find_registrar_iana_id(entities) do
    case Enum.find(entities, fn e -> "registrar" in (Map.get(e, "roles", [])) end) do
      %{"publicIds" => ids} ->
        case Enum.find(ids, fn id -> id["type"] == "IANA Registrar ID" end) do
          %{"identifier" => id} -> id
          _ -> ""
        end
      _ -> ""
    end
  end

  defp extract_vcard_fn(fields) when is_list(fields) do
    case Enum.find(fields, fn f -> is_list(f) and List.first(f) == "fn" end) do
      [_, _, _, name] when is_binary(name) -> name
      _ -> ""
    end
  end
  defp extract_vcard_fn(_), do: ""

  # Extract registrant country from RDAP entities (RFC 9083 vCard "adr" field)
  # Many registrars redact this (GDPR), so it's often empty.
  defp find_registrant_country(entities) do
    registrant = Enum.find(entities, fn e ->
      roles = Map.get(e, "roles", [])
      "registrant" in roles
    end)

    case registrant do
      %{"vcardArray" => [_, fields]} -> extract_vcard_country(fields)
      _ -> ""
    end
  end

  # vCard "adr" field: ["adr", {params}, "text", [pobox, ext, street, city, region, postal, country]]
  defp extract_vcard_country(fields) when is_list(fields) do
    case Enum.find(fields, fn f -> is_list(f) and List.first(f) == "adr" end) do
      [_, _, _, addr] when is_list(addr) ->
        case List.last(addr) do
          country when is_binary(country) and country != "" -> String.upcase(String.slice(country, 0, 2))
          _ -> ""
        end
      _ -> ""
    end
  end
  defp extract_vcard_country(_), do: ""
end
