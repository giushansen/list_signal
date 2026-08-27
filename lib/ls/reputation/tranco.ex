defmodule LS.Reputation.Tranco do
  @moduledoc """
  Tranco domain ranking — aggregates CrUX, Cloudflare, Umbrella, Majestic, Farsight.

  Downloads daily, archives old files. Downloads the full ~7.5M list by
  default; set LS_TRANCO_FULL=false to use the top 1M only.

  ## Two storage modes (2026-08-27)

  * `:full` (master) keeps `{domain, rank}` in ETS, because the master answers
    the rank VALUE when it fills the `tranco_rank` column for rows arriving
    from workers (`LS.Reputation.fill/1`).
  * `:membership` (workers) keeps only a bloom filter, because a worker asks
    exactly one question: is this domain ranked at all?
    `LS.HTTP.DomainFilter` uses that to bypass the TLD/MX/SPF heuristics.

  The measured difference on a worker is **402 MB of ETS versus 4.9 MB**, on
  machines with 1,968 MB in total, and the membership test is also faster:
  0.09 us versus 3.16 us on a miss, which is the common case. See
  `LS.Reputation.Bloom` for why the false-positive direction is the safe one.

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

  @doc """
  Integer rank (1 = most popular) or nil.

  Always nil in `:membership` mode: a worker does not carry the ranks, and the
  master fills the column instead. Use `ranked?/1` for the crawl decision.
  """
  def lookup(domain) when is_binary(domain) do
    d = normalize(domain)

    case :ets.lookup(@rank_table, d) do
      [{^d, rank}] -> rank
      [] -> nil
    end
  rescue
    # :membership mode never creates the table.
    ArgumentError -> nil
  end

  @doc """
  Whether `domain` is Tranco-ranked. This is the crawl-decision question and
  the only one a worker needs.

  In `:membership` mode this consults the bloom filter, so it may return true
  for an unranked domain at roughly 1 in 100, and never false for a ranked one.
  """
  @spec ranked?(String.t()) :: boolean()
  def ranked?(domain) when is_binary(domain) do
    d = normalize(domain)

    case :persistent_term.get({__MODULE__, :bloom}, nil) do
      nil -> lookup(d) != nil
      bloom -> LS.Reputation.Bloom.member?(bloom, d)
    end
  end

  def ranked?(_), do: false

  defp normalize(domain), do: domain |> String.downcase() |> String.trim_leading("www.")

  @doc "The storage mode this node runs: :full keeps ranks, :membership keeps a bloom filter."
  def mode, do: Application.get_env(:ls, :tranco_mode, :full)

  def stats, do: GenServer.call(__MODULE__, :stats)

  @impl true
  def init(_opts) do
    if mode() == :full do
      :ets.new(@rank_table, [:set, :public, :named_table, read_concurrency: true])
    end

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
    # Loading streams millions of CSV lines through this heap; the live data
    # lives in ETS, so everything on the heap afterwards is garbage. Without
    # this, ~150-300MB of loading residue sat here until the NEXT load —
    # part of what pushed the master past its memory cap (5 SIGKILLs on
    # 2026-07-30).
    :erlang.garbage_collect()
    {:noreply, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply, Map.take(state, [:domains_loaded, :last_updated, :error, :memory_mb, :full]), state}
  end

  # Download — full list first, fall back to 1M zip
  defp download_and_load(true = _full) do
    case Req.get(@url_id, receive_timeout: 10_000, finch: LS.Finch.Bulk) do
      {:ok, %{status: 200, body: list_id}} when is_binary(list_id) ->
        list_id = String.trim(list_id)
        url = "https://tranco-list.eu/download/#{list_id}/full"
        case Req.get(url, receive_timeout: 300_000, max_retries: 2, finch: LS.Finch.Bulk) do
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
    case Req.get(url, receive_timeout: 120_000, max_retries: 2, finch: LS.Finch.Bulk) do
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
    lines = String.split(csv, "\n", trim: true)
    store = new_store(length(lines))
    date = Date.utc_today() |> Date.to_string()

    count =
      Enum.reduce(lines, 0, fn line, acc ->
        case parse_line(line) do
          {:ok, d, rank} -> put(store, d, rank) + acc
          :skip -> acc
        end
      end)

    commit(store)
    {:ok, count, date}
  end

  @doc false
  # Pure: one CSV line to {:ok, normalized_domain, rank} or :skip.
  def parse_line(line) do
    with [r, d] <- String.split(line, ",", parts: 2),
         {rank, _} <- Integer.parse(String.trim(r)),
         d when d != "" <- normalize(String.trim(d)) do
      {:ok, d, rank}
    else
      _ -> :skip
    end
  end

  # In :full mode rows go straight into the live ETS table (as before). In
  # :membership mode we build a NEW bloom off to the side and swap it in at the
  # end, so a refresh never leaves the filter half-populated: a partially built
  # filter would answer "not ranked" for real domains, which is the one answer
  # a bloom filter must never give.
  defp new_store(line_count) do
    case mode() do
      :full ->
        :ets.delete_all_objects(@rank_table)
        :ets

      :membership ->
        {:bloom, LS.Reputation.Bloom.new(max(line_count, 1_000), 0.01)}
    end
  end

  defp put(:ets, d, rank), do: (:ets.insert(@rank_table, {d, rank}); 1)
  defp put({:bloom, b}, d, _rank), do: (LS.Reputation.Bloom.put(b, d); 1)

  defp commit(:ets), do: :ok
  defp commit({:bloom, b}), do: :persistent_term.put({__MODULE__, :bloom}, b)

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

  defp ets_mb do
    case :persistent_term.get({__MODULE__, :bloom}, nil) do
      nil -> Float.round((:ets.info(@rank_table, :memory) || 0) * :erlang.system_info(:wordsize) / 1_048_576, 1)
      bloom -> LS.Reputation.Bloom.memory_mb(bloom)
    end
  rescue
    ArgumentError -> 0.0
  end
end
