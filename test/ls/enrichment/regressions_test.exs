defmodule LS.Enrichment.RegressionsTest do
  @moduledoc """
  One test per production incident. Each name states the failure it prevents,
  so a future change that reintroduces it fails here with the story attached
  rather than in prod at 3am.

  The pattern these incidents share: a value arrives from a third party
  (a Shopify payload, a browser timing, an HTML title) and reaches ClickHouse
  without being made safe for TabSeparated or for an unsigned column. One bad
  value fails the parse for the WHOLE batch, so a single hostile product title
  silently costs an entire store's data.
  """
  use ExUnit.Case, async: true

  alias LS.Cluster.EnrichmentWriter
  alias LS.Enrichment.Agent

  describe "homepage routing (2026-07-31: ~8K guaranteed failures in 4h)" do
    test "WAF-walled businesses go to the browser even in the light tier" do
      # The light tier was checked FIRST, so blocked domains in the tail were
      # sent to plain HTTP — the exact client discovery had already been
      # refused by. Guaranteed failure, plus a 30-day cooldown before retry.
      for blocked <- [
            %{http_blocked: "cloudflare", tier: "light"},
            %{last_http_status: 403, tier: "light"},
            %{last_http_status: 401, tier: "light"}
          ] do
        assert Agent.home_strategy(blocked) == :browser_first,
               "a blocked business must reach camoufox regardless of tier: #{inspect(blocked)}"
      end
    end

    test "reachable tail businesses stay off the browser" do
      # The whole point of the light tier: a render slot spent on an unranked
      # tail site is one a ranked or blocked business did not get.
      assert Agent.home_strategy(%{tier: "light"}) == :http_only
      assert Agent.home_strategy(%{tier: "light", last_http_status: 200}) == :http_only
    end

    test "full-tier reachable businesses try HTTP first, browser as fallback" do
      assert Agent.home_strategy(%{tier: "full"}) == :http_then_browser
      assert Agent.home_strategy(%{}) == :http_then_browser
    end
  end

  describe "browser lane budget (2026-08-01: paid camoufox capacity sat idle)" do
    test "the browser lane is selected by its own query, not by value ranking" do
      # A blocked business has no emails and weak classification BECAUSE
      # discovery could not read it, so in one value-ordered query it sorts
      # below ~7M reachable businesses and never reaches the queue: the
      # browser bucket read 0 while ~900K blocked businesses waited and every
      # sidecar on the fleet idled at busy=0.
      #
      # The two lanes must therefore be disjoint — no domain can satisfy both
      # filters, or the lanes would compete for the same rows again.
      browser = LS.Clickhouse.enrichment_lane_filter(browser_only: true)
      http = LS.Clickhouse.enrichment_lane_filter(browser_only: false)

      assert browser =~ "last_http_blocked != ''"
      # 429 is deliberately NOT here — see the "429 is not a wall" describe.
      # 503 IS here since 2026-09-04: a WAF challenge page answers 503 to a
      # plain client, and re-asking over HTTP became Vultr abuse report #2.
      assert browser =~ "401, 403, 503"
      # the HTTP lane must EXCLUDE everything the browser lane claims
      assert http =~ "b.crawlable"
      assert http =~ "last_http_blocked = ''"
      assert http =~ "NOT IN (401, 403, 503)"
    end
  end

  describe "browser work reaches every node (2026-08-01, second half)" do
    # Reserving queue slots for browser work was not enough: datacenter nodes
    # were written to take browser items only if the HTTP bucket ran dry, and
    # it never does. Nine camoufox-equipped nodes idled while one residential
    # node carried the whole blocked backlog. The dequeue split is therefore
    # part of the contract, not an implementation detail.
    test "a datacenter batch reserves a share for browser work" do
      assert LS.Cluster.EnrichmentQueue.browser_share(:datacenter, 24) > 0,
             "datacenter nodes must take browser work even when HTTP items are plentiful"

      assert LS.Cluster.EnrichmentQueue.browser_share(:residential, 24) >=
               LS.Cluster.EnrichmentQueue.browser_share(:datacenter, 24),
             "residential nodes still get first pick of WAF-walled work"
    end
  end

  describe "429 is not a wall (2026-08-02: 83% of all failures)" do
    test "a rate-limited business is not sent to the browser" do
      # 429 means "come back later", not "you need a better fingerprint".
      # Routing those to camoufox made them 83% of every failure while
      # consuming the scarcest resource in the fleet — and re-asking a CDN
      # that already said slow down is how source IPs get blacklisted.
      assert Agent.home_strategy(%{last_http_status: 429}) == :http_then_browser
      assert Agent.home_strategy(%{last_http_status: 429, tier: "light"}) == :http_only

      # Real walls still go to the browser — including the 503 a WAF
      # challenge page serves to a plain client (2026-09-04, abuse report #2).
      assert Agent.home_strategy(%{last_http_status: 403}) == :browser_first
      assert Agent.home_strategy(%{last_http_status: 401}) == :browser_first
      assert Agent.home_strategy(%{last_http_status: 503}) == :browser_first
      assert Agent.home_strategy(%{http_blocked: "cloudflare"}) == :browser_first
    end

    test "the browser lane query excludes rate-limited businesses" do
      browser_lane = LS.Clickhouse.enrichment_lane_filter(browser_only: true)

      refute browser_lane =~ "429",
             "the browser bucket must not be filled with domains that only need patience"

      assert browser_lane =~ "401"
      assert browser_lane =~ "403"
    end
  end

  describe "TabSeparated safety (three separate batch-loss incidents)" do
    test "a backslash in a product title cannot shift the following columns" do
      # luckyvintageseattle.com: a title ending in `\` swallowed the next tab
      # as an escape and dropped the whole biz_products batch.
      assert EnrichmentWriter.tsv_value_public(%{title: "60s Print 2pc Set\\"}, "title") ==
               "60s Print 2pc Set\\\\"

      assert EnrichmentWriter.tsv_value_public(%{title: "a\\b"}, "title") == "a\\\\b"
    end

    test "tabs, newlines and carriage returns become spaces" do
      # A raw newline in a CT-log domain name broke every platforms flush.
      assert EnrichmentWriter.tsv_value_public(%{title: "a\tb\nc\rd"}, "title") == "a b c d"
    end

    test "negative values in unsigned columns are clamped, not passed through" do
      # A Shopify store reported products_count = -2; camoufox reported a
      # negative TTFB. Both are unsigned columns in ClickHouse.
      assert EnrichmentWriter.tsv_value_public(%{products_count: -2}, "products_count") == "0"
      assert EnrichmentWriter.tsv_value_public(%{perf_ttfb_ms: -5}, "perf_ttfb_ms") == "0"
      assert EnrichmentWriter.tsv_value_public(%{job_count: -1}, "job_count") == "0"
      # ...but a legitimately signed column keeps its sign.
      assert EnrichmentWriter.tsv_value_public(%{discount_depth: -0.5}, "discount_depth") == "-0.5"
    end

    test "nil becomes ClickHouse NULL, not an empty string" do
      # An empty string in a DateTime column is a parse error; \\N is not.
      assert EnrichmentWriter.tsv_value_public(%{seen_at: nil}, "seen_at") == "\\N"
    end

    test "a column absent from the row degrades to NULL rather than raising" do
      # Rolling deploys mean a mid-flight agent can send rows shaped by the
      # previous release; one raise here would kill the batch.
      assert EnrichmentWriter.tsv_value_public(%{}, "definitely_not_a_column_xyz") == "\\N"
    end
  end
end
