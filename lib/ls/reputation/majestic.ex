defmodule LS.Reputation.Majestic do
  @moduledoc """
  Majestic Million — top 1M domains ranked by referring subnet diversity.

  RefSubNets = unique /24 IP subnets containing sites that link to this domain.
  Impossible to fake: real organic backlinks come from diverse networks.
  A domain with RefSubNets > 100 is almost certainly a real business.

  ## Usage

      LS.Reputation.Majestic.lookup("stripe.com")
      #=> %{rank: 2345, ref_subnets: 18432}

      LS.Reputation.Majestic.lookup("unknown.xyz")
      #=> nil
  """

  use GenServer
  require Logger

  @url "https://downloads.majestic.com/majestic_million.csv"
  @table :majestic_ranks
  @refresh_ms 24 * 3_600_000
  @archive_dir "priv/reputation/majestic"

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Returns %{rank: int, ref_subnets: int} or nil."
  def lookup(domain) when is_binary(domain) do
    d = domain |> String.downcase() |> String.trim_leading("www.")
    case :ets.lookup(@table, d) do
      [{^d, rank, ref_subnets}] -> %{rank: rank, ref_subnets: ref_subnets}
      [] -> nil
    end
  end

  def stats, do: GenServer.call(__MODULE__, :stats)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    File.mkdir_p!(@archive_dir)
    state = %{domains_loaded: 0, last_updated: nil, error: nil, memory_mb: 0.0}
    state = load_latest_archive(state)
    send(self(), :download)
    {:ok, state}
  end

  @impl true
  def handle_info(:download, state) do
    state = case download_and_load() do
      {:ok, count, date} ->
        archive_current(date)
        Logger.info("✅ Majestic loaded: #{count} domains (#{date})")
        %{state | domains_loaded: count, last_updated: DateTime.utc_now(),
          error: nil, memory_mb: ets_mb()}
      {:error, reason} ->
        Logger.warning("⚠️  Majestic download failed: #{inspect(reason)} — keeping #{state.domains_loaded} domains")
        %{state | error: inspect(reason)}
    end
    Process.send_after(self(), :download, @refresh_ms)
    {:noreply, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply, Map.take(state, [:domains_loaded, :last_updated, :error, :memory_mb]), state}
  end

  # Majestic CSV format:
  # GlobalRank,TldRank,Domain,TLD,RefSubNets,RefIPs,IDN_Domain,IDN_TLD,PrevGlobalRank,PrevTldRank,PrevRefSubNets,PrevRefIPs
  defp download_and_load do
    case Req.get(@url, receive_timeout: 120_000, max_retries: 2) do
      {:ok, %{status: 200, body: csv}} when is_binary(csv) -> load_csv(csv)
      {:ok, %{status: s}} -> {:error, {:http, s}}
      {:error, r} -> {:error, r}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp load_csv(csv) do
    :ets.delete_all_objects(@table)
    date = Date.utc_today() |> Date.to_string()

    lines = String.split(csv, "\n", trim: true)
    # Skip header line
    lines = case lines do
      ["GlobalRank" <> _ | rest] -> rest
      [h | rest] -> if String.starts_with?(h, "GlobalRank"), do: rest, else: lines
      _ -> lines
    end

    count = Enum.reduce(lines, 0, fn line, acc ->
      case String.split(line, ",") do
        [rank_s, _tld_rank, domain, _tld, ref_subnets_s | _rest] ->
          with {rank, _} <- Integer.parse(String.trim(rank_s)),
               {ref_sn, _} <- Integer.parse(String.trim(ref_subnets_s)) do
            d = domain |> String.trim() |> String.downcase() |> String.trim_leading("www.")
            if d != "" do
              :ets.insert(@table, {d, rank, ref_sn})
              acc + 1
            else
              acc
            end
          else
            _ -> acc
          end
        _ -> acc
      end
    end)

    {:ok, count, date}
  end

  defp archive_current(date) do
    path = Path.join(@archive_dir, "majestic_#{date}.gz")
    unless File.exists?(path) do
      data = :ets.tab2list(@table)
      |> Enum.sort_by(fn {_, r, _} -> r end)
      |> Enum.map(fn {d, r, s} -> "#{r},#{d},#{s}" end)
      |> Enum.join("\n")
      File.write!(path, :zlib.gzip(data))
      cleanup_archives()
    end
  rescue _ -> :ok
  end

  defp load_latest_archive(state) do
    case File.ls(@archive_dir) do
      {:ok, files} ->
        case files |> Enum.filter(&String.ends_with?(&1, ".gz")) |> Enum.sort() |> List.last() do
          nil -> state
          f ->
            case File.read(Path.join(@archive_dir, f)) do
              {:ok, gz} ->
                csv = :zlib.gunzip(gz)
                :ets.delete_all_objects(@table)
                count = csv |> String.split("\n", trim: true) |> Enum.reduce(0, fn line, acc ->
                  case String.split(line, ",") do
                    [r, d, s] ->
                      with {rank, _} <- Integer.parse(r), {sn, _} <- Integer.parse(s) do
                        :ets.insert(@table, {d, rank, sn}); acc + 1
                      else _ -> acc end
                    _ -> acc
                  end
                end)
                Logger.info("📦 Majestic archive #{f}: #{count} domains")
                %{state | domains_loaded: count, memory_mb: ets_mb()}
              _ -> state
            end
        end
      _ -> state
    end
  rescue _ -> state
  end

  defp cleanup_archives do
    cutoff = Date.utc_today() |> Date.add(-30) |> Date.to_string()
    case File.ls(@archive_dir) do
      {:ok, fs} -> Enum.filter(fs, &(&1 < "majestic_#{cutoff}")) |> Enum.each(&File.rm(Path.join(@archive_dir, &1)))
      _ -> :ok
    end
  end

  defp ets_mb, do: Float.round((:ets.info(@table, :memory) || 0) * :erlang.system_info(:wordsize) / 1_048_576, 1)
end
