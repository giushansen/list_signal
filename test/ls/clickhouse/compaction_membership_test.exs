defmodule LS.Clickhouse.CompactionMembershipTest do
  use ExUnit.Case, async: true

  @moduledoc """
  2026-10-03: from the 09-07 fold rewrite to today, a crawled domain became
  a business only if the classifier assigned a model (or the site was
  walled). On 10-02 that threw away 446K first fetches that returned a 2xx
  page with a title: a Kennebunkport shop, a dive school, a photographer.
  An observed page with a title and no junk verdict is a business now, with
  an empty model until the classifier decides; walled sites keep their row
  on a mail server alone, for the browser lane.
  """

  test "the fold keeps observed, titled, non-junk sites whether or not they are classified" do
    src = File.read!("lib/ls/clickhouse/compact.ex")
    [having | _] = src |> String.split("HAVING (is_malware = '' AND is_phishing = '')") |> Enum.at(1) |> String.split("\n    ) h")
    assert having =~ "(business_model != '' AND crawlable)"
    assert having =~ "OR (crawlable AND http_title != '' AND is_junk = '')"
    assert having =~ "OR ((last_http_blocked != '' OR last_http_status IN (401, 403, 429)) AND dns_mx != '')"
  end

  test "the title and junk verdict the rule reads come from observed fetches only" do
    src = File.read!("lib/ls/clickhouse/compact.ex")
    assert src =~ ~r/argMaxIf\(s_http_title, s_enriched_at, #\{observed_sql\("s_"\)\}\) AS http_title/
    assert src =~ "argMaxIf(s_is_junk, s_enriched_at, s_http_status BETWEEN 200 AND 399) AS is_junk"
  end
end
