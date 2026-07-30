defmodule LS.CTL.PlatformRegistry do
  @moduledoc """
  Persistent registry of **platforms** — infrastructure apexes that issue
  certificates for thousands of customer sites (myshopify.com, squarespace.com,
  netlify.app…).

  ## Why a table and not columns on `businesses`

  A platform is not a business. It is detected at the CT-poller stage from cert
  velocity and subdomain count, and filtered out *before* enrichment — so it
  never becomes a `businesses` row at all. Its useful attributes (cert rate,
  hosted-customer count) have no meaning for a company, and a company's
  attributes (revenue, industry) have none for it. Keeping them apart keeps
  `businesses` clean and makes the platform list a standalone, sellable
  market-share dataset in its own right.

  ## What it fixes

  Platform detection previously lived **only** in the in-memory CT dedup cache,
  which is capped at 5M entries and evicts. So the fleet re-learned "Shopify is
  a platform" every day and persisted nothing. With this registry the knowledge
  is permanent: known platforms are loaded at boot and skipped on sight, before
  the velocity heuristic even runs.

  ## Grace window

  A domain is only promoted after it sustains the threshold across
  `@min_detections` separate detection cycles. A real startup that briefly
  spikes a handful of subdomains will not qualify; a platform keeps climbing.
  This is what stops us mislabelling (and therefore never enriching) a
  fast-growing customer.

  Writes are buffered and flushed hourly — never one insert per certificate. The
  buffer survives between flushes, so a platform detected at 12:01 is written at
  the top of the next hour with its accumulated counts.
  """

  use GenServer
  require Logger

  @table :platform_registry
  @pending :platform_pending
  # Hourly, not per-minute. A platform is a permanent fact — once myshopify.com
  # is in the registry it stays — so there is nothing to gain from writing every
  # 60s, and the pending buffer coalesces repeat detections in the meantime.
  @flush_interval_ms 3_600_000
  @min_detections 2

  # Best-effort naming for the apexes we already know. Anything else is stored
  # with a blank name and can be labelled later without losing the row.
  @seed %{
    "myshopify.com" => {"Shopify", "ecommerce_platform"},
    "squarespace.com" => {"Squarespace", "website_builder"},
    "wixsite.com" => {"Wix", "website_builder"},
    "netlify.app" => {"Netlify", "hosting"},
    "vercel.app" => {"Vercel", "hosting"},
    "webflow.io" => {"Webflow", "website_builder"},
    "github.io" => {"GitHub Pages", "hosting"},
    "herokuapp.com" => {"Heroku", "hosting"},
    "pages.dev" => {"Cloudflare Pages", "hosting"},
    "wordpress.com" => {"WordPress.com", "website_builder"},
    "bigcartel.com" => {"Big Cartel", "ecommerce_platform"},
    "ecwid.com" => {"Ecwid", "ecommerce_platform"},
    "storenvy.com" => {"Storenvy", "ecommerce_platform"},
    "sentry.io" => {"Sentry", "other"},
    "cloudfront.net" => {"CloudFront", "cdn"},
    "azurewebsites.net" => {"Azure App Service", "hosting"},
    "firebaseapp.com" => {"Firebase", "hosting"}
  }

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Is this apex a known platform? O(1) ETS read — safe to call per certificate.

  Answers `true` only for domains already promoted to the registry, so the
  caller can skip them without running the velocity heuristic at all.
  """
  @spec known?(String.t()) :: boolean()
  def known?(domain) when is_binary(domain) do
    :ets.member(@table, domain)
  rescue
    ArgumentError -> false
  end

  def known?(_), do: false

  @doc """
  Record that the CT poller's heuristic flagged `domain` as a platform.

  Buffers the observation; the domain is only written to ClickHouse once it has
  been flagged `@min_detections` times (the grace window).
  """
  @spec observe(String.t(), map()) :: :ok
  def observe(domain, stats) when is_binary(domain) do
    count =
      case :ets.lookup(@pending, domain) do
        [{^domain, seen, _}] -> seen + 1
        [] -> 1
      end

    :ets.insert(@pending, {domain, count, stats})
    if count >= @min_detections and not known?(domain), do: :ets.insert(@table, {domain, true})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Registry size — how many platforms we know about."
  def count do
    :ets.info(@table, :size) || 0
  rescue
    ArgumentError -> 0
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    :ets.new(@pending, [:set, :public, :named_table, write_concurrency: true])

    loaded = load_known()
    Logger.info("🏗️  PlatformRegistry: #{loaded} known platforms loaded (skipped on sight)")
    Process.send_after(self(), :flush, @flush_interval_ms)
    {:ok, %{flushed: 0}}
  end

  @impl true
  def handle_info(:flush, state) do
    written = flush_pending()
    if written > 0, do: Logger.info("🏗️  PlatformRegistry: persisted #{written} platform(s)")
    Process.send_after(self(), :flush, @flush_interval_ms)
    {:noreply, %{state | flushed: state.flushed + written}}
  end

  # ── persistence ────────────────────────────────────────────────────────────

  defp load_known do
    case LS.Clickhouse.query_raw("SELECT domain FROM platforms", 15_000) do
      {:ok, rows} when is_list(rows) ->
        Enum.each(rows, fn [d] -> :ets.insert(@table, {d, true}) end)
        length(rows)

      _ ->
        0
    end
  end

  # Only domains past the grace window are written. ReplacingMergeTree(last_seen)
  # means a re-detection updates the row rather than duplicating it.
  defp flush_pending do
    rows =
      :ets.tab2list(@pending)
      |> Enum.filter(fn {_d, count, _s} -> count >= @min_detections end)

    if rows == [] do
      0
    else
      now = NaiveDateTime.utc_now() |> NaiveDateTime.to_string() |> String.slice(0, 19)

      tsv =
        Enum.map_join(rows, "\n", fn {domain, _count, s} ->
          {name, category} = Map.get(@seed, domain, {"", "other"})

          [
            domain, name, category,
            Map.get(s, :reason, "cert_rate"),
            Map.get(s, :cert_count, 0),
            Map.get(s, :cert_rate_per_hour, 0.0),
            Map.get(s, :max_subdomain_count, 0),
            Map.get(s, :estimated_hosted_domains, 0),
            Map.get(s, :first_detected, now),
            now,
            "auto"
          ]
          # CT logs occasionally emit garbage names with embedded whitespace;
          # one raw tab/newline breaks the whole TabSeparated batch, and the
          # retry buffer then re-sends the same poison row every flush.
          |> Enum.map_join("\t", fn v ->
            v |> to_string() |> String.replace(["\t", "\n", "\r"], " ")
          end)
        end)

      sql = """
      INSERT INTO platforms
        (domain, platform_name, category, detection_reason, cert_count,
         cert_rate_per_hour, max_subdomain_count, estimated_hosted_domains,
         first_detected, last_seen, source)
      FORMAT TabSeparated
      """

      case LS.Clickhouse.insert_raw(sql, tsv) do
        :ok ->
          Enum.each(rows, fn {d, _, _} -> :ets.delete(@pending, d) end)
          length(rows)

        {:error, reason} ->
          # Keep the buffer: the next flush retries rather than losing detections.
          Logger.error("[PLATFORMS] insert failed: #{inspect(reason)}")
          0
      end
    end
  end
end
