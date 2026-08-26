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
  alias LS.HTTP.{Client, IPRateLimiter, PageExtractor}

  # A browser page costs ~5-15s and a lot of RAM; three at a time is what a
  # 16-core node sustains without the render queue thrashing. This caps
  # RENDERS (the sidecar's own semaphore queues the excess), not the batch.
  @browser_concurrency 3
  # Concurrent enrichments per node — set per box with LS_ENRICH_CONCURRENCY.
  # 88% of eligible businesses are plainly HTTP-crawlable and never touch the
  # browser, so the batch runs wider than the render cap; per-target-IP
  # politeness is enforced by IPRateLimiter regardless of width. Defaults to
  # 12; the 16-core NUC takes ~28, the thrashing 2-core VPS boxes go DOWN to
  # 10 (load 15 on 2 cores costs more in latency than the extra lane returns).
  defp enrich_concurrency do
    case Integer.parse(System.get_env("LS_ENRICH_CONCURRENCY", "12")) do
      {n, _} when n > 0 -> n
      _ -> 12
    end
  end

  # Residential nodes (LS_RESIDENTIAL=true — home IPs) announce themselves to
  # the queue and get WAF-blocked items first: a residential fingerprint is
  # what actually gets past Cloudflare-class walls.
  defp node_class do
    if System.get_env("LS_RESIDENTIAL") in ["true", "1"], do: :residential, else: :datacenter
  end
  @page_timeout 10_000
  @idle_wait_ms 30_000
  # Between page visits on the SAME site: a human does not open /contact,
  # /pricing and /careers in the same 50ms. The per-IP limiter already spaces
  # requests 1s apart; the jitter varies the rhythm so it does not look like a
  # metronome.
  @page_jitter_base_ms 400
  @page_jitter_rand_ms 1200

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

    # LIGHT tier (unranked, no emails, weak classification — computed by the
    # refill query from columns discovery already filled): homepage + contact
    # page only, no browser fallback. Roughly a third of the cost of a full
    # pass; the row records what it is via the ordinary column emptiness, and
    # the 30-day recrawl upgrades any business whose signals improve.
    light? = item[:tier] == "light"

    # 2026-08-26: :legal and :about joined the visit list. In the EU the
    # statutory imprint (/impressum, /mentions-legales) is where the contact
    # address legally has to be, and it outyields /kontakt 60% to 22% on
    # German business domains. Both tiers get :legal — it is the single
    # highest-yield page in the set — but only the full tier pays for :about.
    pages =
      if light?,
        do: PageExtractor.pages_to_visit(item[:http_pages], [:contact, :legal]),
        else: PageExtractor.pages_to_visit(item[:http_pages])

    # Homepage routing (2026-07-30): the browser is reserved for businesses
    # that NEED it — WAF-blocked or 401/403/429 at discovery (~12% of the
    # eligible set). The other 88% proved plainly crawlable in pipeline 1, so
    # they are fetched by HTTP first and only fall back to camoufox when that
    # fetch fails. Renders are the scarce resource (3 per node); HTTP is not.
    # Cost of the trade: HTTP-enriched rows carry an ESTIMATED perf_lcp_ms
    # derived from the measured fetch time and no CLS — render_engine says
    # which kind every row is.
    #
    # Secondary pages stay on HTTP. They are read for text (contacts, prices,
    # jobs), never measured, so rendering them would multiply browser cost by
    # ~4 for no data.
    home =
      case home_strategy(item) do
        :browser_first -> render_home(domain, ip)
        :http_only -> fetch_page(domain, ip, "/") |> estimate_perf()
        :http_then_browser -> fetch_home(domain, ip, item)
      end

    visited =
      Enum.map(pages, fn {kind, path} ->
        Process.sleep(@page_jitter_base_ms + :rand.uniform(@page_jitter_rand_ms))
        {kind, fetch_page(domain, ip, path) |> Map.put(:path, path)}
      end)

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
      page_fetches: page_fetches(home, visited, domain),
      # seen_at = crawl time, exactly like contacts. posted_at is NOT a
      # substitute: HTML-scraped jobs have no posted date, and an empty string
      # in the DateTime column killed the whole biz_career insert batch.
      jobs: Enum.map(jobs, &(&1 |> Map.put(:domain, domain) |> Map.put(:seen_at, now()))),
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
        products: [], collections: [], page_fetches: [], summary: %{}}
  end

  # ── page fetching ──────────────────────────────────────────────────────────

  # Blocked at discovery = plain HTTP already failed there; going browser-first
  # for these is the whole reason camoufox exists.
  defp needs_browser?(item),
    do: item[:http_blocked] not in [nil, ""] or item[:last_http_status] in [401, 403]

  @doc """
  How the homepage should be fetched for `item`. Pure — the routing rule alone,
  with no network — because getting this order wrong is expensive and silent.

    * `:browser_first`     WAF-walled (blocked / 401 / 403). Plain HTTP is
      exactly what got refused at discovery, so an HTTP-only attempt is a
      GUARANTEED failure that still burns a fetch, a queue slot and a 30-day
      cooldown. This wins over the tier: on 2026-07-31 the light tier was
      checked first and ~8K of ~10K failures in four hours were blocked
      domains steered away from camoufox.
    * `:http_only`         light tier, reachable: no browser fallback — a render
      slot spent on the tail is one a ranked or blocked business did not get.
    * `:http_then_browser` full tier, reachable: cheap path first, camoufox
      only if it fails.
  """
  @spec home_strategy(map()) :: :browser_first | :http_only | :http_then_browser
  def home_strategy(item) do
    cond do
      needs_browser?(item) -> :browser_first
      item[:tier] == "light" -> :http_only
      true -> :http_then_browser
    end
  end

  defp fetch_home(domain, ip, item) do
    if needs_browser?(item) do
      render_home(domain, ip)
    else
      case fetch_page(domain, ip, "/") do
        %{source: "http"} = page -> estimate_perf(page)
        _failed -> render_home(domain, ip)
      end
    end
  end

  # One render, behind the SAME per-IP limiter as every HTTP fetch on this
  # node — the browser is not a side-channel around politeness. If the slot
  # stays contended (or the render fails) we fall back to HTTP, which waits
  # politely on its own.
  defp render_home(domain, ip) do
    with true <- Browser.available?(),
         :ok <- polite_render_slot(ip),
         {:ok, %{html: html, perf: perf}} when is_binary(html) <- Browser.render(domain, "/") do
      %{html: html, perf: perf, source: "camoufox"}
    else
      _ -> fetch_page(domain, ip, "/")
    end
  end

  defp polite_render_slot(nil), do: :ok
  defp polite_render_slot(ip), do: polite_render_slot(ip, 3)
  defp polite_render_slot(_ip, 0), do: :contended

  defp polite_render_slot(ip, retries) do
    case IPRateLimiter.check_and_update(ip, 1000) do
      :ok -> :ok
      {:wait, ms} -> Process.sleep(ms) && polite_render_slot(ip, retries - 1)
    end
  end

  # LCP and CLS exist only inside a browser. For HTTP-enriched rows we derive
  # an ESTIMATE of LCP from the measured full-page fetch time (headers + HTML
  # body): rendering adds roughly 60% on top for a typical page. It is
  # deliberately coarse; render_engine="http" marks every row it applies to,
  # and CLS stays NULL rather than pretending we watched a layout settle.
  defp estimate_perf(%{elapsed_ms: ms} = page) when is_integer(ms) and ms > 0,
    do: %{page | perf: %{lcp_ms: round(ms * 1.6), cls: nil, ttfb_ms: nil}}

  defp estimate_perf(page), do: page

  # Secondary pages are read for text only, never measured — so they are always
  # plain HTTP. No browser fallback: these pages are optional extras, and
  # spending a scarce browser slot on one would starve a homepage render.
  # Every failure used to collapse into `%{html: nil, source: "failed"}` — no
  # status, no error, nothing recorded anywhere. "How often does a contact-page
  # fetch actually work?" was then unanswerable without re-crawling a sample by
  # hand, which is the only reason the redirect bug (68% of secondary-page
  # failures) was ever found. The outcome now rides along on the page map and
  # is written to biz_page_fetch, so the next one is a query instead of a probe.
  defp fetch_page(domain, ip, path) do
    case Client.fetch(domain, ip,
           path: path, timeout: @page_timeout, politeness_retries: 3) do
      {:ok, %{status: s, body: body} = resp} when s in 200..399 and byte_size(body) > 500 ->
        %{html: body, perf: %{}, source: "http", elapsed_ms: resp[:elapsed_ms],
          outcome: "ok", status: s}

      {:ok, %{status: s} = resp} when s in 200..399 ->
        # 2xx/3xx with a body too small to be a page: usually an unfollowed
        # redirect or an empty shell, NOT content. Distinguished from a real
        # error so the two can be counted apart.
        %{html: nil, perf: %{}, source: "failed", outcome: "thin", status: s,
          elapsed_ms: resp[:elapsed_ms]}

      {:ok, %{status: s} = resp} ->
        %{html: nil, perf: %{}, source: "failed", outcome: "http_error", status: s,
          elapsed_ms: resp[:elapsed_ms]}

      other ->
        %{html: nil, perf: %{}, source: "failed", outcome: error_outcome(other), status: 0}
    end
  end

  defp error_outcome({:error, _msg, :rate_limited}), do: "rate_limited"
  defp error_outcome({:error, _msg, :too_many_redirects}), do: "redirect_loop"
  defp error_outcome({:error, "rate_limited", _}), do: "rate_limited"
  defp error_outcome({:error, "too_many_redirects", _}), do: "redirect_loop"
  defp error_outcome({:error, msg}) when is_binary(msg), do: classify_error(msg)
  defp error_outcome({:error, msg, _}) when is_binary(msg), do: classify_error(msg)
  defp error_outcome(_), do: "error"

  defp classify_error(msg) do
    cond do
      msg =~ "timeout" -> "timeout"
      msg =~ "rate_limited" -> "rate_limited"
      msg =~ "redirect" -> "redirect_loop"
      true -> "error"
    end
  end

  # One row per attempted fetch, homepage included, so the funnel is queryable:
  # how many domains got a homepage, how many got each secondary page, and why
  # the rest did not.
  defp page_fetches(home, visited, domain) do
    rows =
      [{:home, "/", home} | Enum.map(visited, fn {kind, page} -> {kind, path_of(page), page} end)]

    Enum.map(rows, fn {kind, path, page} ->
      %{
        domain: domain,
        page_kind: to_string(kind),
        path: path || "",
        outcome: page[:outcome] || if(page[:html], do: "ok", else: "error"),
        status: page[:status] || 0,
        elapsed_ms: page[:elapsed_ms] || 0,
        seen_at: now()
      }
    end)
  end

  defp path_of(page), do: page[:path]

  defp html_of(visited, kind) do
    case List.keyfind(visited, kind, 0) do
      {^kind, %{html: html}} -> html
      _ -> nil
    end
  end

  # ── extraction into child-table rows ───────────────────────────────────────

  # Read every visited page that plausibly carries an address, in yield order
  # (measured 2026-08-26 on German business domains: legal 60%, contact 22%,
  # about 13%). `source_page` records which kind it actually came from —
  # it used to be hardcoded "contact" for every row, which made the column
  # useless for judging whether an address is trustworthy. That matters:
  # imprint pages also carry the site's *agency* and arbitration-board
  # addresses, so a consumer needs to know it is reading one.
  @contact_page_kinds [:legal, :contact, :about, :pricing]

  defp contacts(visited, domain) do
    @contact_page_kinds
    |> Enum.flat_map(fn kind ->
      case html_of(visited, kind) do
        nil ->
          []

        html ->
          case PageExtractor.extract_all(html, domain) do
            {_pages, emails} when is_binary(emails) and emails != "" ->
              emails |> String.split("|", trim: true) |> Enum.map(&{&1, kind})

            _ ->
              []
          end
      end
    end)
    |> Enum.uniq_by(fn {email, _kind} -> email end)
    |> Enum.take(20)
    |> Enum.map(fn {email, kind} ->
      %{
        domain: domain,
        email: email,
        source_page: to_string(kind),
        on_domain: if(on_domain?(email, domain), do: 1, else: 0),
        seen_at: now()
      }
    end)
  end

  @doc """
  Does this address belong to the site it was found on?

  Imprint pages are legally required to name a contact and routinely name
  someone else's — the agency that built the site, the host, or a German
  statutory arbitration board (`schlichtungsstelle@s-d-r.org` is boilerplate).
  Measured 2026-08-26 on German business domains: 40.6% yield an address from
  a second page but only 28.1% yield one on the business's own domain, so
  12.5% of them would be sold as "this company's email" while belonging to
  somebody else.

  Flagged rather than filtered: an off-domain address is still real signal —
  the agency relationship is itself sellable, and for a tiny business a
  freemail address is often the only reachable human. Consumers that need the
  business's own mailbox filter on `on_domain = 1`.

      iex> LS.Enrichment.Agent.on_domain?("info@acme.de", "acme.de")
      true
      iex> LS.Enrichment.Agent.on_domain?("info@agentur.de", "acme.de")
      false
  """
  @spec on_domain?(String.t(), String.t()) :: boolean()
  def on_domain?(email, domain) when is_binary(email) and is_binary(domain) do
    with [_local, host] <- String.split(String.downcase(email), "@", parts: 2),
         base <- domain |> String.downcase() |> String.replace_prefix("www.", "") do
      host == base or String.ends_with?(host, "." <> base)
    else
      _ -> false
    end
  end

  def on_domain?(_, _), do: false

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
              max_concurrency: enrich_concurrency(), timeout: 120_000, on_timeout: :kill_task)
            |> Enum.flat_map(fn
              {:ok, r} -> [r]
              _ -> []
            end)

          # A killed task (>120s: WAF walls, dead hosts) vanishes from results.
          # Say so — a silent drop looks identical to a healthy small batch,
          # which is how a whole night of queue churn went unnoticed once.
          if length(results) < length(items) do
            Logger.warning(
              "[ENRICH] #{length(items) - length(results)}/#{length(items)} domains exceeded 120s and were dropped"
            )
          end

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
    GenServer.call(queue, {:dequeue_lane, :enrichment, enrich_concurrency() * 2, node_class()}, 15_000)
  catch
    :exit, _ -> :empty
  end
end
