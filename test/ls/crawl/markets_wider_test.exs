defmodule LS.Crawl.MarketsWiderTest do
  @moduledoc """
  2026-11-03, owner: markets with buying power that also buy from the
  competitors. The 11-02 list missed India (7 to 8% of BuiltWith's
  customers, .in 75% English and 1,466 sellable rows in the week before the
  gate, a better rate per fetch than .com), the Gulf and the rich small
  English territories. Poor countries where English or French is spoken
  are not markets: nobody there buys a subscription.
  """
  use ExUnit.Case, async: true

  alias LS.Crawl.Markets

  test "the markets added on 2026-11-03 are crawled" do
    for tld <- ~w(in co.in ae qa mt com.mt gg je im gi re net.nz) do
      assert Markets.crawl_tld?(tld), tld
    end
  end

  test "the big non-English, non-French suffixes stay out on yield" do
    for tld <- ~w(nl de it se dk es no fi at jp br com.br pl ru cn kr tr co.il) do
      refute Markets.crawl_tld?(tld), tld
    end
  end

  test "English- or French-speaking countries without buying power stay out" do
    for tld <- ~w(pk com.pk ph com.ph my com.my ng com.ng ke co.ke gh lk jm tt bs mu
                  ma tn dz sn ci cm ht mg nc pf) do
      refute Markets.crawl_tld?(tld), tld
    end
  end

  test "no admitted suffix is listed twice" do
    assert Markets.tlds() == Enum.uniq(Markets.tlds())
  end
end
