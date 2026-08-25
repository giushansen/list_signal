defmodule LS.CTL.Sources do
  @moduledoc """
  Decides WHICH certificate-transparency logs ListSignal ingests, from
  Chrome's authoritative log list — replacing a hand-maintained module
  attribute that went stale twice in two days (2026-08-24: four frozen 2026h1
  shards polled for zero rows; 2026-08-25: Sectigo Mammoth/Sabre found
  retired under us while every Let's Encrypt log was invisible because only
  RFC-6962 was supported).

  `desired/2` is pure (Chrome JSON + today → source list) so the selection
  rules are pinned by tests; `LS.CTL.Poller` applies it on a schedule via
  `reconcile/2` and emails what changed. `fallback/0` is a snapshot of the
  live answer, baked in so a gstatic outage can never leave a booting poller
  with nothing to poll.
  """

  @list_url "https://www.gstatic.com/ct/log_list/v3/all_logs_list.json"

  # Logs in these states accept (usable) or are about to accept (qualified)
  # new certificates. `readonly`/`retired`/`rejected` logs receive nothing
  # new, so polling them cannot discover anything.
  @ingestible_states ~w(usable qualified)

  @type source :: %{
          name: String.t(),
          url: String.t(),
          protocol: :rfc6962 | :static_ct,
          batch_size: pos_integer(),
          avg_entries: pos_integer(),
          min_workers: pos_integer(),
          max_workers: pos_integer(),
          target_lag: pos_integer()
        }

  @doc "Fetch Chrome's list and compute the desired sources. `{:error, _}` on any fetch/parse trouble — never a partial answer."
  def fetch_desired(today \\ Date.utc_today()) do
    case LS.Verification.HTTP.get_json(@list_url, timeout: 30_000, gap_ms: 0) do
      {:ok, json} ->
        case desired(json, today) do
          [] -> {:error, :empty_list}
          sources -> {:ok, sources}
        end

      err ->
        err
    end
  end

  @doc """
  Pure selection: every ingestible log whose temporal shard covers `today`,
  across BOTH publication protocols. RFC-6962 logs get their `/ct/v1` API
  base; tiled logs get their monitoring URL (read side — the submission URL
  only accepts certificates).
  """
  @spec desired(map() | nil, Date.t()) :: [source()]
  def desired(%{"operators" => operators}, today) when is_list(operators) do
    for op <- operators,
        {kind, protocol} <- [{"logs", :rfc6962}, {"tiled_logs", :static_ct}],
        log <- List.wrap(op[kind]),
        is_map(log),
        ingestible?(log),
        covers?(log, today),
        url = source_url(log, protocol),
        is_binary(url) do
      Map.merge(
        %{name: log["description"] || url, url: url, protocol: protocol},
        tuning(url, protocol)
      )
    end
  end

  def desired(_, _), do: []

  @doc """
  What to change to make `running` match `desired`, keyed by URL.

  An empty `desired` stops NOTHING: a failed or empty fetch must never
  dismantle ingestion — losing the CT firehose to a parse hiccup would be a
  self-inflicted outage on the product's most upstream data.
  """
  @spec reconcile([map()], [map()]) :: %{start: [map()], stop: [String.t()]}
  def reconcile(_running, []), do: %{start: [], stop: []}

  def reconcile(running, desired) do
    have = MapSet.new(running, & &1.url)
    want = MapSet.new(desired, & &1.url)

    %{
      start: Enum.reject(desired, &MapSet.member?(have, &1.url)),
      stop: running |> Enum.reject(&MapSet.member?(want, &1.url)) |> Enum.map(& &1.name)
    }
  end

  @doc """
  The desired list as of 2026-08-25, baked in as the boot fallback. Refreshed
  whenever a reconcile run logs a change (the live fetch overrides this at
  runtime; staleness here only matters for the first minutes after a boot
  during a gstatic outage).
  """
  @spec fallback() :: [source()]
  def fallback do
    rfc = fn name, url -> Map.merge(%{name: name, url: url <> "/ct/v1", protocol: :rfc6962}, tuning(url, :rfc6962)) end
    tile = fn name, url -> Map.merge(%{name: name, url: url, protocol: :static_ct}, tuning(url, :static_ct)) end

    [
      rfc.("Google 'Argon2026h2' log", "https://ct.googleapis.com/logs/us1/argon2026h2"),
      rfc.("Google 'Xenon2026h2' log", "https://ct.googleapis.com/logs/eu1/xenon2026h2"),
      rfc.("Cloudflare 'Nimbus2026'", "https://ct.cloudflare.com/logs/nimbus2026"),
      rfc.("DigiCert 'Wyvern2026h2'", "https://wyvern.ct.digicert.com/2026h2"),
      rfc.("DigiCert 'Sphinx2026h2'", "https://sphinx.ct.digicert.com/2026h2"),
      rfc.("Sectigo 'Elephant2026h2'", "https://elephant2026h2.ct.sectigo.com"),
      rfc.("Sectigo 'Tiger2026h2'", "https://tiger2026h2.ct.sectigo.com"),
      rfc.("TrustAsia 'log2026a'", "https://ct2026-a.trustasia.com/log2026a"),
      rfc.("TrustAsia 'log2026b'", "https://ct2026-b.trustasia.com/log2026b"),
      tile.("Let's Encrypt 'Sycamore2026h2'", "https://mon.sycamore.ct.letsencrypt.org/2026h2"),
      tile.("Let's Encrypt 'Willow2026h2'", "https://mon.willow.ct.letsencrypt.org/2026h2"),
      tile.("Google 'ParcelYard2026h2' log", "https://storage.googleapis.com/parcelyard2026h2.prod.certificate.transparency.goog"),
      tile.("Google 'PlumbersArms2026h2' log", "https://storage.googleapis.com/plumbersarms2026h2.prod.certificate.transparency.goog"),
      tile.("Geomys 'Tuscolo2026h2'", "https://tuscolo2026h2.skylight.geomys.org"),
      tile.("IPng Networks 'Halloumi2026h2a'", "https://halloumi2026h2a.mon.ct.ipng.ch"),
      tile.("IPng Networks 'Gouda2026h2'", "https://gouda2026h2.mon.ct.ipng.ch")
    ]
  end

  # ── selection internals ────────────────────────────────────────────────

  defp ingestible?(%{"state" => state}) when is_map(state),
    do: Enum.any?(Map.keys(state), &(&1 in @ingestible_states))

  defp ingestible?(_), do: false

  # A log only holds certs expiring inside its temporal shard; a shard whose
  # window has passed is dead even while its state still reads "usable" — the
  # 2026-08-24 zero-inflow bug.
  defp covers?(log, today) do
    case log["temporal_interval"] do
      %{"start_inclusive" => s, "end_exclusive" => e} ->
        with {:ok, sd, _} <- DateTime.from_iso8601(s),
             {:ok, ed, _} <- DateTime.from_iso8601(e) do
          Date.compare(today, DateTime.to_date(sd)) != :lt and
            Date.compare(today, DateTime.to_date(ed)) == :lt
        else
          _ -> true
        end

      _ ->
        true
    end
  end

  defp source_url(log, :rfc6962) do
    case log["url"] do
      url when is_binary(url) -> String.trim_trailing(url, "/") <> "/ct/v1"
      _ -> nil
    end
  end

  defp source_url(log, :static_ct) do
    case log["monitoring_url"] do
      url when is_binary(url) -> String.trim_trailing(url, "/")
      _ -> nil
    end
  end

  # Operator-measured tuning. Google caps RFC-6962 batches at 32; Cloudflare
  # serves 512; tiles are fixed 256-entry objects on a CDN.
  defp tuning(url, :rfc6962) do
    cond do
      url =~ "googleapis" ->
        %{batch_size: 32, avg_entries: 26, min_workers: 2, max_workers: 30, target_lag: 10_000}

      url =~ "cloudflare" ->
        %{batch_size: 512, avg_entries: 512, min_workers: 1, max_workers: 5, target_lag: 50_000}

      true ->
        %{batch_size: 128, avg_entries: 116, min_workers: 1, max_workers: 5, target_lag: 50_000}
    end
  end

  defp tuning(_url, :static_ct),
    do: %{batch_size: 256, avg_entries: 256, min_workers: 1, max_workers: 4, target_lag: 50_000}
end
