defmodule LSWeb.ExplorerDefaultRankingTest do
  @moduledoc """
  2026-10-23: a new customer opened the dashboard on google.com, "Directory,
  Marketing, 66%", SEO 43 in red, because the default order was Tranco rank.
  These pin the target-first default, the plain sorts that remain, and the
  two display rules that keep a giant from wearing a page classifier's guess.
  """
  use ExUnit.Case, async: true

  alias LS.Explorer
  alias LSWeb.ExplorerLive.Format

  test "the default page ranks by target score, freshness, then domain, and never opens on Tranco rank" do
    sql = Explorer.list_sql(%{})
    assert sql =~ "DESC, http_last_checked_at DESC, domain ASC"
    assert sql =~ "estimated_revenue IN ('$1M-$10M', '$10M-$100M'), 3"
    assert sql =~ "tranco_rank <= 1000, -4"
    assert sql =~ "estimated_revenue = '$1B+', -6"
    refute sql =~ "ORDER BY tranco_rank ASC NULLS LAST"
  end

  test "the score rewards the ICP classes, contacts, a known country and freshness" do
    score = Explorer.target_score_sql()
    for c <- ~w(SaaS Ecommerce Agency Consulting LocalBusiness Manufacturer), do: assert(score =~ "'#{c}'")
    assert score =~ "notEmpty(http_emails), 2"
    assert score =~ "http_phone != '', 1"
    assert score =~ "estimated_country != '', 1"
    assert score =~ "INTERVAL 30 DAY, 1"
  end

  test "a column prefix qualifies every column the score reads, for the export join" do
    q = Explorer.target_score_sql("d.")
    assert q =~ "d.estimated_revenue" and q =~ "d.http_emails" and q =~ "d.tranco_rank" and q =~ "d.http_last_checked_at"
    refute q =~ ~r/(?<![\w.])estimated_revenue/
  end

  test "sorting a header still gives the plain sort of that column" do
    sql = Explorer.list_sql(%{}, sort: "tranco_rank", dir: "asc")
    assert sql =~ "ORDER BY tranco_rank ASC NULLS LAST, domain ASC"
    refute sql =~ "estimated_revenue IN ('$1M-$10M'"
  end

  test "a $1B+ company shows as Enterprise unless the classifier is sure" do
    assert Format.model_label("Directory", "$1B+", 0.66) == "Enterprise"
    assert Format.model_label("Directory", "$1B+", "0.66") == "Enterprise"
    assert Format.model_label("SaaS", "$1B+", 0.9) == "SaaS"
    assert Format.model_label("Directory", "$10M-$100M", 0.66) == "Directory"
    assert Format.model_label(nil, "$1B+", nil) == "Enterprise"
    assert Format.model_label(nil, "", nil) == ""
  end

  test "the verified bracket wins over the estimate for the display rule" do
    assert Format.shown_revenue(%{"verified_revenue" => "$1B+", "estimated_revenue" => "$10M-$100M"}) == "$1B+"
    assert Format.shown_revenue(%{"verified_revenue" => "", "estimated_revenue" => "$1M-$10M"}) == "$1M-$10M"
    assert Format.shown_revenue(%{}) == ""
  end

  test "the SEO score is not shown for the Tranco top 10,000, and stays coloured below it" do
    assert Phoenix.HTML.safe_to_string(Format.seo_cell(43, 1)) =~ "n/a"
    assert Phoenix.HTML.safe_to_string(Format.seo_cell(43, 10_000)) =~ "n/a"
    assert Phoenix.HTML.safe_to_string(Format.seo_cell(43, 10_001)) =~ "text-red-400"
    assert Phoenix.HTML.safe_to_string(Format.seo_cell(43, nil)) =~ "text-red-400"
    assert Phoenix.HTML.safe_to_string(Format.seo_cell(85, 250_000)) =~ "text-emerald-400"
  end
end
