defmodule LSWeb.CompareDegradeTest do
  @moduledoc """
  2026-08-24: /compare/klaviyo-vs-mailchimp returned 500 whenever ClickHouse
  was busy — `compare_techs/2` hard-matched `{:ok, x}` on four of the heaviest
  scans on the site, so one timeout raised MatchError on a public SEO page.
  A page missing a panel beats a 500; a half-empty page cached for 6h is worse
  than either, so a degraded result must not persist.
  """
  use ExUnit.Case, async: true

  test "ok_or_empty/1 unwraps success and swallows every failure shape" do
    assert LS.Clickhouse.ok_or_empty({:ok, [1, 2]}) == [1, 2]
    assert LS.Clickhouse.ok_or_empty({:error, %{reason: :timeout}}) == []
    assert LS.Clickhouse.ok_or_empty(:anything_else) == []
  end

  test "the compare page's heavy scans are no longer hard-matched" do
    # Tripwire on the source: a `{:ok, x} = stores_by_tech(...)` style match
    # inside compare_techs is exactly what produced the 500.
    src = File.read!("lib/ls/clickhouse.ex")
    [_, body] = String.split(src, "def compare_techs(tech_a, tech_b) do", parts: 2)
    body = body |> String.split("\n  end\n", parts: 2) |> hd()

    refute body =~ ~r/\{:ok,\s*\w+\}\s*=\s*(stores_by_tech|tech_country_distribution)/,
           "compare_techs must degrade these scans, not pattern-match them"

    assert body =~ "degraded?", "compare_techs must report when it fell back"
  end

  test "the controller drops a degraded result instead of caching it for 6h" do
    src = File.read!("lib/ls_web/controllers/compare_controller.ex")
    assert src =~ "invalidate(:compare_page"
    assert src =~ ":degraded"
  end
end
