defmodule LS.Crawl.MarketsTest do
  @moduledoc """
  2026-11-02, owner's decision: the crawl spends fetches on English- and
  French-speaking markets only. 22.5% of the week's 2.68M fetches came back
  in another language and 12.4% returned no page; the customers buy neither.
  """
  use ExUnit.Case, async: true

  alias LS.Crawl.Markets

  test "the English and French markets are crawled" do
    for tld <- ~w(com net org io co ai uk co.uk us ca au com.au nz co.nz ie sg hk fr be ch lu) do
      assert Markets.crawl_tld?(tld), tld
    end
  end

  test "other markets and low-yield suffixes are not" do
    for tld <- ~w(de nl jp co.jp br com.br it es se dk ru cn pl com.pl vn com.vn xyz top) do
      refute Markets.crawl_tld?(tld), tld
    end

    refute Markets.crawl_tld?("")
    refute Markets.crawl_tld?(nil)
  end

  test "every admitted suffix is a public suffix, so a poller gate on ctl_tld can match it" do
    for tld <- Markets.tlds(), do: assert(LS.CTL.PublicSuffix.public_suffix?(tld), tld)
  end

  test "case does not matter" do
    assert Markets.crawl_tld?("CO.UK")
  end

  test "the refresh schedule reads only English and French pages" do
    sql = LS.Clickhouse.stale_domains_sql(10)
    assert sql =~ Markets.refresh_language_sql()
    assert Markets.refresh_language_sql() =~ "http_language LIKE 'en%'"
    assert Markets.refresh_language_sql() =~ "http_language LIKE 'fr%'"
    refute Markets.refresh_language_sql() =~ "http_language = ''"
  end
end
