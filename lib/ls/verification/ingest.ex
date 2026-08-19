defmodule LS.Verification.Ingest do
  @moduledoc """
  The one shape every source run has: open a run row, stream records through
  the website tier in bounded chunks, persist, optionally run the name tier,
  close the run row with counts. Sources only produce records.
  """

  require Logger
  alias LS.Verification.Store

  @doc """
  `records` is any enumerable of record maps (see `LS.Verification.Store.record_row/2`
  for the fields). Options: `:url`, `:snapshot`, `:bytes`, `:name_tier` (boolean).
  """
  @spec ingest(atom(), Enumerable.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def ingest(source, records, opts) do
    started = Store.start_run(source, opts[:url] || "", opts[:snapshot] || "")
    chunk = Store.chunk_size()

    try do
      {n, w} =
        records
        |> Stream.chunk_every(chunk)
        |> Enum.reduce({0, 0}, fn recs, {n, w} ->
          recs = Store.match_website(recs)
          {rn, _facts} = Store.store_chunk(recs, started)
          matched = Enum.count(recs, &(&1[:match_method] == "website"))
          if rem(n + rn, 50_000) < rn, do: Logger.info("[VERIFY] #{source}: #{n + rn} records, #{w + matched} website matches")
          {n + rn, w + matched}
        end)

      nc =
        if opts[:name_tier] do
          Logger.info("[VERIFY] #{source}: name tier over #{n} records")
          Store.rebuild_domain_keys()
          Store.match_name_country(source, started)
        else
          0
        end

      stats = %{url: opts[:url], snapshot: opts[:snapshot], bytes: opts[:bytes] || 0,
                records: n, matched_website: w, matched_name_country: nc}
      Store.finish_run(source, started, :ok, stats)
      LS.Verification.prune_snapshots(source)
      {:ok, stats}
    rescue
      e ->
        msg = Exception.message(e)
        Store.finish_run(source, started, :error, %{url: opts[:url], snapshot: opts[:snapshot], error: msg})
        Logger.error("[VERIFY] #{source} failed: #{msg}")
        {:error, msg}
    end
  end
end
