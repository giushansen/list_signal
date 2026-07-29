defmodule LS.Enrichment.Agent do
  @moduledoc """
  Worker for the **enrichment lane** (pipeline 2): depth, not breadth.

  Discovery (`LS.Cluster.WorkerAgent`) answers *"does this domain exist and
  what is it?"* across millions of domains. This agent answers *"what is this
  business actually worth to a customer?"* for the few million we already know
  are real — by visiting the specific pages discovery recorded in
  `http_pages`.

  ## Per domain

      1. Shopify catalog     — /products.json (no browser, cheap)
      2. Careers + jobs      — ATS JSON API when detectable, else the page
      3. Contact / pricing   — one visit each, paths from PageExtractor
      4. SEO audit + perf    — scored from the homepage HTML
      5. Write               — biz_* child rows + a summary row for businesses

  ## Politeness

  Every fetch goes through `LS.HTTP.Client`, so the per-IP rate limiter and
  the politeness caches apply exactly as in discovery — that is deliberate and
  must stay: our source IPs are the business's most fragile asset. Browser
  work is additionally capped at `@browser_concurrency` per node.

  Nothing here writes to `domains_history`/`domains_current`; this lane owns
  only the `biz_*` tables, so it structurally cannot blank discovery's data.
  """

  use GenServer
  require Logger

  alias LS.Enrichment.{Shopify, Jobs, SEO, About, Browser}
  alias LS.HTTP.{Client, PageExtractor}

  # A browser page costs ~5-15s and a lot of RAM; three at a time is what a
  # 16-core node sustains without the render queue thrashing.
  @browser_concurrency 3
  @page_timeout 10_000
  @idle_wait_ms 30_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Throughput and last-batch stats for the enrichment lane."
  @spec stats() :: map()
  def stats, do: GenServer.call(__MODULE__, :stats)

  @doc """
  Enrich one domain end-to-end. Pure function of its inputs (no queue), so it
  is directly callable for testing and one-off inspection:

      LS.Enrichment.Agent.enrich(%{domain: "glossier.com", http_pages: "/contact|/pricing",
                                   http_tech: "Shopify", ip: "1.2.3.4"})
  """
  @spec enrich(map()) :: map()
  def enrich(%{domain: domain} = item) do
    ip = item[:ip] || resolve(domain)
    pages = PageExtractor.pages_to_visit(item[:http_pages])

    # The homepage is ALWAYS browser-rendered when a sidecar is available.
    # LCP, CLS and TTFB exist only inside a real browser — plain HTTP cannot
    # measure them at any cost — and the SEO score is meant to reflect the
    # rendered DOM, not the raw server response. Previously the browser was
    # used only as a *fallback* when HTTP failed, so for every business whose
    # HTTP fetch succeeded (i.e. essentially all of them) camoufox never ran:
    # 6,411 enriched rows carried render_engine="http" and zero perf metrics.
    #
    # Secondary pages stay on HTTP. They are read for text (contacts, prices,
    # jobs), never measured, so rendering them would multiply browser cost by
    # ~4 for no data. One render per business keeps us inside the 3-concurrent
    # per-node budget that protects our IPs.
    home = fetch_home(domain, ip)
    visited = Enum.map(pages, fn {kind, path} -> {kind, fetch_page(domain, ip, path)} end)

    careers_html = html_of(visited, :career)

    shopify =
      if Shopify.shopify?(item[:http_tech]),
        do: Shopify.analyze(domain, ip),
        else: %{summary: %{}, products: [], collections: []}
    {jobs_summary, jobs} = Jobs.analyze(domain, careers_html, ip)
    about = About.analyze(domain, careers_html, jobs, ip)
    # SEO always runs on the homepage; perf is only populated when camoufox
    # rendered it (plain HTTP cannot measure LCP/CLS).
    seo = SEO.audit(home[:html], home[:perf] || %{})

    %{
      domain: domain,
      enriched_at: now(),
      contacts: contacts(visited, domain),
      jobs: Enum.map(jobs, &Map.put(&1, :domain, domain)),
      pricing: pricing(visited, domain),
      products: shopify.products,
      collections: shopify.collections,
      summary:
        # render_engine records what actually fetched the homepage, not what we
        # intended to use. It used to be derived from the *decision* to allow a
        # browser, so a row could claim "camoufox" with no perf metrics on it.
        %{domain: domain, enriched_at: now(), render_engine: home[:source]}
        |> Map.merge(shopify.summary)
        |> Map.merge(jobs_summary)
        |> Map.merge(about)
        |> Map.merge(seo)
    }
  rescue
    e ->
      Logger.warning("[ENRICH] #{item[:domain]} failed: #{Exception.message(e)}")
      %{domain: item[:domain], contacts: [], jobs: [], pricing: [],
        products: [], collections: [], summary: %{}}
  end

  # ── page fetching ──────────────────────────────────────────────────────────

  # The homepage: browser first, HTTP as the fallback — the opposite order to
  # every other page. Only the browser yields perf metrics, so trying HTTP
  # first and stopping on success is what silently zeroed the perf columns.
  #
  # If the sidecar is down or the render fails we still fall back to HTTP, so a
  # business is never lost — it just arrives with SEO but no perf, which
  # `render_engine` records honestly.
  defp fetch_home(domain, ip) do
    with true <- Browser.available?(),
         {:ok, %{html: html, perf: perf}} when is_binary(html) <- Browser.render(domain, "/") do
      %{html: html, perf: perf, source: "camoufox"}
    else
      _ -> fetch_page(domain, ip, "/")
    end
  end

  # Secondary pages are read for text only, never measured — so they are always
  # plain HTTP. No browser fallback: these pages are optional extras, and
  # spending a scarce browser slot on one would starve a homepage render.
  defp fetch_page(domain, ip, path) do
    case Client.fetch(domain, ip, path: path, timeout: @page_timeout) do
      {:ok, %{status: s, body: body}} when s in 200..399 and byte_size(body) > 500 ->
        %{html: body, perf: %{}, source: "http"}

      _ ->
        %{html: nil, perf: %{}, source: "failed"}
    end
  end

  defp html_of(visited, kind) do
    case List.keyfind(visited, kind, 0) do
      {^kind, %{html: html}} -> html
      _ -> nil
    end
  end

  # ── extraction into child-table rows ───────────────────────────────────────

  # Contact page first (that is where addresses live); fall back to the
  # homepage so a business is never left with no contact at all.
  defp contacts(visited, domain) do
    [html_of(visited, :contact), html_of(visited, :pricing)]
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(fn html ->
      case PageExtractor.extract_all(html, domain) do
        {_pages, emails} when is_binary(emails) and emails != "" -> String.split(emails, "|", trim: true)
        _ -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.take(20)
    |> Enum.map(&%{domain: domain, email: &1, source_page: "contact", seen_at: now()})
  end

  # Every currency amount printed on the pricing page, deduped and sorted.
  #
  # These are *observed price points*, not verified plan tiers. We do not name
  # them: plan naming is wildly inconsistent across SaaS, and a scraped page
  # gives no reliable way to bind a number to the tier it belongs to. An earlier
  # version emitted `plan_1..plan_N` — that label was purely the sort index and
  # carried no information, which made the column look meaningful when it wasn't.
  #
  # The numbers themselves are comparable and useful: the lowest is an entry
  # price, the spread indicates whether a vendor sells self-serve or enterprise.
  # Treat any single value as indicative — the regex cannot tell a plan price
  # from "save $10" in the same page.
  defp pricing(visited, domain) do
    case html_of(visited, :pricing) do
      nil -> []
      html -> price_points(html, domain)
    end
  end

  @doc """
  Extract the observed price points from a pricing page's HTML.

  Returns rows of `%{domain, price, currency, seen_at}`, ascending, deduped by
  `{currency, price}` and capped at 12. Pure — exposed for testing and for
  re-running extraction over stored HTML without touching the network.
  """
  @spec price_points(String.t(), String.t()) :: [map()]
  def price_points(html, domain) when is_binary(html) do
    # Two things here are load-bearing.
    #
    # /u — € and £ are multi-byte in UTF-8; without it a character class matches
    # single bytes, so `€25` captured the continuation byte <<172>>, not the symbol.
    #
    # The number grammar accepts either a separator-grouped amount (1,234.56) or
    # a plain run of digits (1500), and the trailing (?!\d) forbids a partial
    # match. The previous `\d{1,3}(?:[.,]\d{3})*` had neither: on `$250000` it
    # matched just `250` and recorded a $250 price that appeared nowhere on the
    # page. Now it reads 250000 in full and the plausibility filter drops it.
    #
    # Known ambiguity: `$1.234` is read as 1.234, not 1234 — a bare dot is far
    # more often a decimal point than European thousands separator.
    ~r/([\$€£])\s?((?:\d{1,3}(?:[.,]\d{3})+|\d{1,6})(?:[.,]\d{1,2})?)(?!\d)/u
    |> Regex.scan(visible_text(html), capture: :all_but_first)
    |> Enum.flat_map(fn [symbol, n] ->
      case n |> String.replace(",", "") |> Float.parse() do
        {price, _} when price > 0 and price < 100_000 -> [{currency(symbol), price}]
        _ -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.take(12)
    |> Enum.map(fn {currency, price} ->
      %{domain: domain, price: price, currency: currency, seen_at: now()}
    end)
  end

  defp currency("$"), do: "USD"
  defp currency("€"), do: "EUR"
  defp currency("£"), do: "GBP"

  # Scan only what a human sees. Analytics configs, product feeds and JSON-LD
  # blobs live inside <script> and are full of bare numbers next to currency
  # symbols; including them produced price ladders like "1|2|6|8|20|21|22" for
  # vendors that publish no self-serve pricing at all.
  @script_or_style ~r/<(script|style)\b[^>]*>.*?<\/\1>/is
  defp visible_text(html), do: String.replace(html, @script_or_style, " ")

  defp resolve(domain) do
    case LS.DNS.Resolver.lookup(domain) do
      {:ok, %{a: [ip | _]}} -> ip
      _ -> nil
    end
  end

  defp now, do: NaiveDateTime.utc_now() |> NaiveDateTime.to_string() |> String.slice(0, 19)

  # ── GenServer: pull from the enrichment lane ───────────────────────────────

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    state = %{total: 0, batches: 0, last_ms: nil, start_time: System.monotonic_time(:second)}
    send(self(), :pull)
    Logger.info("🔬 Enrichment agent started (browser: #{Browser.available?()}, max #{@browser_concurrency} concurrent)")
    {:ok, state}
  end

  @impl true
  def handle_call(:stats, _from, s) do
    up = System.monotonic_time(:second) - s.start_time
    {:reply, Map.merge(s, %{uptime_seconds: up, browser: Browser.available?()}), s}
  end

  @impl true
  def handle_info(:pull, s) do
    master = System.get_env("LS_MASTER", "master@10.0.0.1") |> String.to_atom()
    parent = self()

    # Do the batch OUTSIDE the GenServer. Enriching six domains takes tens of
    # seconds (browser renders, politeness waits), and running it inline blocked
    # this process's mailbox for the whole batch — so the dashboard's
    # `:stats` call timed out and the node was reported as "no enrichment lane
    # running" while it was in fact working. Same pattern as
    # `LS.Cluster.WorkerAgent`: spawn_link, message the result back.
    spawn_link(fn ->
      case safe_dequeue({LS.Cluster.EnrichmentQueue, master}) do
        {:ok, batch_id, items} when items != [] ->
          t0 = System.monotonic_time(:millisecond)

          results =
            items
            |> Task.async_stream(&enrich/1,
              max_concurrency: @browser_concurrency, timeout: 120_000, on_timeout: :kill_task)
            |> Enum.flat_map(fn
              {:ok, r} -> [r]
              _ -> []
            end)

          GenServer.cast({LS.Cluster.EnrichmentQueue, master}, {:complete_enrichment, batch_id, results})
          send(parent, {:batch_done, length(results), System.monotonic_time(:millisecond) - t0})

        _ ->
          send(parent, :batch_empty)
      end
    end)

    {:noreply, s}
  end

  @impl true
  def handle_info({:batch_done, count, ms}, s) do
    send(self(), :pull)
    {:noreply, %{s | total: s.total + count, batches: s.batches + 1, last_ms: ms}}
  end

  @impl true
  def handle_info(:batch_empty, s) do
    Process.send_after(self(), :pull, @idle_wait_ms)
    {:noreply, s}
  end

  # A crashing batch process must not take the agent down with it.
  @impl true
  def handle_info({:EXIT, _pid, reason}, s) do
    if reason != :normal do
      Logger.warning("[ENRICH] batch process exited: #{inspect(reason)}")
      Process.send_after(self(), :pull, 5_000)
    end

    {:noreply, s}
  end

  defp safe_dequeue(queue) do
    GenServer.call(queue, {:dequeue_lane, :enrichment, @browser_concurrency * 2}, 15_000)
  catch
    :exit, _ -> :empty
  end
end
