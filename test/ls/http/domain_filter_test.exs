defmodule LS.HTTP.DomainFilterTest do
  use ExUnit.Case, async: false

  alias LS.HTTP.DomainFilter

  setup_all do
    DomainFilter.load_tlds()

    # The reject-case fixtures below must not hit the Tranco bypass. Some are
    # real domains that can appear in the daily list (naked.com already did),
    # so pin the tests by removing them from the shared ETS table.
    if :ets.whereis(:tranco_ranks) != :undefined do
      for d <- ["nomail.com", "nospf.com", "aa.io", "naked.com", "x99999.com"] do
        :ets.delete(:tranco_ranks, d)
      end
    end

    :ok
  end

  # ============================================================================
  # SHOULD CRAWL — valid domains
  # ============================================================================

  test "accepts .com domain with MX and SPF" do
    assert DomainFilter.should_crawl?(
      "example.com",
      "10:aspmx.l.google.com",
      "v=spf1 include:_spf.google.com ~all"
    )
  end

  test "accepts .io domain with MX and SPF" do
    assert DomainFilter.should_crawl?(
      "myapp.io",
      "10:smtp.google.com",
      "v=spf1 include:_spf.google.com ~all"
    )
  end

  test "accepts .co.uk domain with MX and SPF" do
    assert DomainFilter.should_crawl?(
      "business.co.uk",
      "10:mail.example.co.uk",
      "v=spf1 ip4:1.2.3.4 ~all"
    )
  end

  # ============================================================================
  # SHOULD NOT CRAWL — filtered out
  # ============================================================================

  test "rejects domain without MX records" do
    refute DomainFilter.should_crawl?(
      "nomail.com",
      "",
      "v=spf1 include:_spf.google.com ~all"
    )
  end

  test "rejects domain without SPF" do
    refute DomainFilter.should_crawl?(
      "nospf.com",
      "10:mx.example.com",
      "google-site-verification=abc123"
    )
  end

  test "rejects very short domain" do
    refute DomainFilter.should_crawl?(
      "aa.io",
      "10:mx.aa.io",
      "v=spf1 ~all"
    )
  end

  test "rejects domain with no MX and no SPF" do
    refute DomainFilter.should_crawl?("naked.com", "", "")
  end

  # ============================================================================
  # TLD LOADING
  # ============================================================================

  test "TLDs are loaded into ETS" do
    size = :ets.info(:http_high_value_tlds, :size)
    assert size > 30, "Expected 30+ high-value TLDs, got #{size}"
  end

  test ".com is a high-value TLD" do
    assert :ets.lookup(:http_high_value_tlds, "com") != []
  end

  test ".io is a high-value TLD" do
    assert :ets.lookup(:http_high_value_tlds, "io") != []
  end

  # ============================================================================
  # TRANCO BYPASS — ranked domains crawl regardless of the heuristic gate
  # ============================================================================

  describe "tranco bypass" do
    setup do
      case :ets.whereis(:tranco_ranks) do
        :undefined ->
          :ets.new(:tranco_ranks, [:set, :public, :named_table, read_concurrency: true])

        _ ->
          :ok
      end

      :ets.insert(:tranco_ranks, {"ranked-but-gated.pizza", 12_345})
      on_exit(fn -> :ets.delete(:tranco_ranks, "ranked-but-gated.pizza") end)
      :ok
    end

    test "tranco-ranked domain crawls even with no MX, no SPF, unlisted TLD" do
      assert DomainFilter.should_crawl?("ranked-but-gated.pizza", "", "")
    end

    test "unranked domain is still subject to the full heuristic gate" do
      refute DomainFilter.should_crawl?("unranked-no-mx.pizza", "", "")
    end

    test "junk heuristics still reject unranked garbage" do
      refute DomainFilter.should_crawl?("x99999.com", "10:mx.example.com", "v=spf1 ~all")
    end
  end
end
