defmodule LS.Reputation.Blocklist do
  @moduledoc """
  Unified domain blocklist: malware (URLhaus), phishing (Phishing Army),
  disposable email providers. All loaded into a single ETS table.

  Downloads all sources daily. If any source fails, keeps existing data.
  Domains flagged here can be skipped for expensive enrichment (HTTP/RDAP).

  ## Usage

      LS.Reputation.Blocklist.lookup("malware-site.com")  #=> :malware
      LS.Reputation.Blocklist.lookup("phish-bank.com")     #=> :phishing
      LS.Reputation.Blocklist.lookup("mailinator.com")     #=> :disposable
      LS.Reputation.Blocklist.lookup("stripe.com")         #=> nil
      LS.Reputation.Blocklist.blocked?("malware-site.com") #=> true
  """

  use GenServer
  require Logger

  @table :reputation_blocklist

  # Pre-processed domain-only lists — no auth needed, updated 2x/day
  @sources %{
    malware: "https://malware-filter.gitlab.io/malware-filter/urlhaus-filter-domains.txt",
    phishing: "https://malware-filter.gitlab.io/malware-filter/phishing-filter-domains.txt",
    disposable: "https://raw.githubusercontent.com/disposable-email-domains/disposable-email-domains/master/disposable_email_blocklist.conf"
  }

  @refresh_ms 12 * 3_600_000  # 12 hours

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Returns :malware, :phishing, :disposable, or nil."
  def lookup(domain) when is_binary(domain) do
    d = domain |> String.downcase() |> String.trim_leading("www.")
    case :ets.lookup(@table, d) do
      [{^d, type}] -> type
      [] -> nil
    end
  end

  @doc "Returns true if domain is on any blocklist."
  def blocked?(domain), do: lookup(domain) != nil

  def stats, do: GenServer.call(__MODULE__, :stats)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    state = %{
      malware: 0, phishing: 0, disposable: 0,
      last_updated: nil, errors: []
    }
    send(self(), :download)
    {:ok, state}
  end

  @impl true
  def handle_info(:download, state) do
    results = Enum.map(@sources, fn {type, url} ->
      case download_list(url) do
        {:ok, domains} ->
          count = load_domains(domains, type)
          Logger.info("✅ Blocklist #{type}: #{count} domains")
          {type, {:ok, count}}
        {:error, reason} ->
          Logger.warning("⚠️  Blocklist #{type} failed: #{inspect(reason)} — keeping existing")
          {type, {:error, reason}}
      end
    end)

    errors = for {type, {:error, r}} <- results, do: "#{type}: #{inspect(r)}"

    state = Enum.reduce(results, state, fn
      {type, {:ok, count}}, s -> Map.put(s, type, count)
      _, s -> s
    end)
    state = %{state | last_updated: DateTime.utc_now(), errors: errors}

    Process.send_after(self(), :download, @refresh_ms)
    {:noreply, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    total = state.malware + state.phishing + state.disposable
    mem = Float.round((:ets.info(@table, :memory) || 0) * :erlang.system_info(:wordsize) / 1_048_576, 1)
    {:reply, %{
      malware: state.malware, phishing: state.phishing, disposable: state.disposable,
      total: total, memory_mb: mem,
      last_updated: state.last_updated, errors: state.errors
    }, state}
  end

  defp download_list(url) do
    case Req.get(url, receive_timeout: 60_000, max_retries: 2) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        domains = body
        |> String.split("\n", trim: true)
        |> Enum.reject(fn line ->
          l = String.trim(line)
          l == "" or String.starts_with?(l, "#") or String.starts_with?(l, "!")
        end)
        |> Enum.map(fn line ->
          # Handle hostfile format (127.0.0.1 domain.com) and plain domain format
          line = String.trim(line)
          case String.split(line, ~r/\s+/, parts: 2) do
            [_, domain] -> domain |> String.trim() |> String.downcase()
            [domain] -> domain |> String.trim() |> String.downcase()
          end
        end)
        |> Enum.reject(&(&1 == "" or &1 == "localhost" or &1 == "0.0.0.0"))
        {:ok, domains}
      {:ok, %{status: s}} -> {:error, {:http, s}}
      {:error, r} -> {:error, r}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp load_domains(domains, type) do
    # Delete existing entries of this type before reloading
    :ets.tab2list(@table)
    |> Enum.filter(fn {_, t} -> t == type end)
    |> Enum.each(fn {d, _} -> :ets.delete(@table, d) end)

    Enum.each(domains, fn d ->
      # Don't overwrite a higher-severity classification
      # Priority: malware > phishing > disposable
      case :ets.lookup(@table, d) do
        [{^d, :malware}] -> :ok  # keep malware, it's highest
        [{^d, :phishing}] when type == :disposable -> :ok
        _ -> :ets.insert(@table, {d, type})
      end
    end)

    length(domains)
  end
end
