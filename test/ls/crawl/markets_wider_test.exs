defmodule LS.Crawl.MarketsWiderTest do
  @moduledoc """
  2026-11-03, owner: keep every market where English or French is the
  language of business, the buyers are there. The 11-02 list had the big
  anglophone and francophone countries and missed India, the Gulf,
  Pakistan, Malaysia, the Philippines, anglophone Africa and francophone
  Africa and overseas France. .in alone yielded 1,466 sellable rows in the
  week before the gate, a better rate per fetch than .com.
  """
  use ExUnit.Case, async: true

  alias LS.Crawl.Markets

  test "the markets added on 2026-11-03 are crawled" do
    for tld <- ~w(in co.in pk com.pk ph com.ph my com.my ng com.ng ke co.ke gh lk mt ae qa
                  mu re nc pf ma tn dz sn ci cm ht mg net.nz) do
      assert Markets.crawl_tld?(tld), tld
    end
  end

  test "the big non-English, non-French suffixes stay out on yield" do
    for tld <- ~w(nl de it se dk es no fi at jp br com.br pl ru cn kr tr co.il) do
      refute Markets.crawl_tld?(tld), tld
    end
  end

  test "no admitted suffix is listed twice" do
    assert Markets.tlds() == Enum.uniq(Markets.tlds())
  end
end
