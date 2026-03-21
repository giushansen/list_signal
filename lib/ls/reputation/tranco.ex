defmodule LS.Reputation.Tranco do
  @moduledoc """
  Tranco domain ranking — aggregates CrUX, Cloudflare, Umbrella, Majestic, Farsight.

  Downloads daily, loads into ETS for O(1) lookup. Archives old files.
  Downloads the full ~7.5M list by default. Set LS_TRANCO_FULL=false to use top 1M only.

  ## Usage

      LS.Reputation.Tranco.lookup("google.com")    #=> 1
      LS.Reputation.Tranco.lookup("stripe.com")     #=> 4521
      LS.Reputation.Tranco.lookup("unknown.xyz")    #=> nil
      LS.Reputation.Tranco.stats()
  """

  use GenServer
  require Logger

  @url_1m "https://tranco-list.eu/download/top-1m.csv.zip"
  @url_id "https://tranco-list.eu/top-1m-id"
  @rank_table :tranco_ranks
  @refresh_ms 24 * 3_600_000
  @archive_dir "priv/reputation/tranco"

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Returns integer rank (1 = most popular) or nil."
  def lookup(domain) when is_binary(domain) do
    d = domain |> String.downcase() |> String.trim_leading("www.")
    case :ets.lookup(@rank_table, d) do
      [{^d, rank}] -> rank
      [] -> nil
    end
  end

  def stats, do: GenServer.call(__MODULE__, :stats)

  @impl true
  def init(_opts) do
    :ets.new(@rank_table, [:set, :public, :named_table, read_concurrency: true])
    File.mkdir_p!(@archive_dir)
    state = %{domains_loaded: 0, last_updated: nil, error: nil, memory_mb: 0.0,
              full: System.get_env("LS_TRANCO_FULL", "true") == "true"}
    state = load_latest_archive(state)
    send(self(), :download)
    {:ok, state}
  end

  @impl true
  def handle_info(:download, state) do
    state = case download_and_load(state.full) do
      {:ok, count, date} ->
        archive_current(date)
        Logger.info("✅ Tranco loaded: #{count} domains (#{date})")
        %{state | domains_loaded: count, last_updated: DateTime.utc_now(),
          error: nil, memory_mb: ets_mb()}
      {:error, reason} ->
        Logger.warning("⚠️  Tranco download failed: #{inspect(reason)} — keeping #{state.domains_loaded} domains")
        %{state | error: inspect(reason)}
    end
    Process.send_after(self(), :download, @refresh_ms)
    {:noreply, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply, Map.take(state, [:domains_loaded, :last_updated, :error, :memory_mb, :full]), state}
  end

  # Download — full list first, fall back to 1M zip
  defp download_and_load(true = _full) do
    case Req.get(@url_id, receive_timeout: 10_000) do
      {:ok, %{status: 200, body: list_id}} when is_binary(list_id) ->
        list_id = String.trim(list_id)
        url = "https://tranco-list.eu/download/#{list_id}/full"
        case Req.get(url, receive_timeout: 300_000, max_retries: 2) do
          {:ok, %{status: 200, body: csv}} when is_binary(csv) ->
            load_csv(csv)
          _ -> download_and_load(false)
        end
      _ -> download_and_load(false)
    end
  rescue
    _ -> download_and_load(false)
  end
  defp download_and_load(false) do
    case download_csv_zip(@url_1m) do
      {:ok, csv} -> load_csv(csv)
      {:error, reason} -> {:error, reason}
    end
  end

  defp download_csv_zip(url) do
    case Req.get(url, receive_timeout: 120_000, max_retries: 2) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        case :zip.unzip(body, [:memory]) do
          {:ok, [{_, csv}]} -> {:ok, csv}
          {:ok, files} ->
            case Enum.find(files, fn {n, _} -> String.ends_with?(to_string(n), ".csv") end) do
              {_, csv} -> {:ok, csv}
              nil -> {:error, :no_csv_in_zip}
            end
          {:error, r} -> {:error, {:unzip, r}}
        end
      {:ok, %{status: s}} -> {:error, {:http, s}}
      {:error, r} -> {:error, r}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp load_csv(csv) do
    :ets.delete_all_objects(@rank_table)
    date = Date.utc_today() |> Date.to_string()
    count = csv
    |> String.split("\n", trim: true)
    |> Enum.reduce(0, fn line, acc ->
      case String.split(line, ",", parts: 2) do
        [r, d] ->
          case Integer.parse(String.trim(r)) do
            {rank, _} ->
              d = d |> String.trim() |> String.downcase() |> String.trim_leading("www.")
              if d != "", do: (:ets.insert(@rank_table, {d, rank}); acc + 1), else: acc
            :error -> acc
          end
        _ -> acc
      end
    end)
    {:ok, count, date}
  end

  defp archive_current(date) do
    path = Path.join(@archive_dir, "tranco_#{date}.csv.gz")
    unless File.exists?(path) do
      data = :ets.tab2list(@rank_table)
      |> Enum.sort_by(fn {_, r} -> r end) |> Enum.take(1_000_000)  # archive top 1M only
      |> Enum.map(fn {d, r} -> "#{r},#{d}" end) |> Enum.join("\n")
      File.write!(path, :zlib.gzip(data))
      cleanup_archives()
    end
  rescue _ -> :ok
  end

  defp load_latest_archive(state) do
    case File.ls(@archive_dir) do
      {:ok, files} ->
        case files |> Enum.filter(&String.ends_with?(&1, ".csv.gz")) |> Enum.sort() |> List.last() do
          nil -> state
          f ->
            case File.read(Path.join(@archive_dir, f)) do
              {:ok, gz} ->
                case load_csv(:zlib.gunzip(gz)) do
                  {:ok, c, _} ->
                    Logger.info("📦 Tranco archive #{f}: #{c} domains")
                    %{state | domains_loaded: c, memory_mb: ets_mb()}
                  _ -> state
                end
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
      {:ok, fs} -> Enum.filter(fs, &(&1 < "tranco_#{cutoff}")) |> Enum.each(&File.rm(Path.join(@archive_dir, &1)))
      _ -> :ok
    end
  end

  defp ets_mb, do: Float.round((:ets.info(@rank_table, :memory) || 0) * :erlang.system_info(:wordsize) / 1_048_576, 1)
end
