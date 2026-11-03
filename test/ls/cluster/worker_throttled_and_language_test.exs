defmodule LS.Cluster.WorkerThrottledAndLanguageTest do
  @moduledoc """
  2026-11-03. Two rules on the worker's HTTP stage:

  A first 429 is not a result. It used to be written as the row's status,
  which moved http_last_checked_at and shelved the store for a cadence;
  the candidate now goes back to the tail once, flagged, and a second 429
  is recorded.

  A secondary page is read only when the homepage is in English or
  French: a page in another language, or with no detectable language,
  sells nothing, and neither would its contact page.
  """
  use ExUnit.Case, async: true

  alias LS.Cluster.WorkerAgent

  test "a first 429 is requeued, a flagged one keeps its 429, other statuses are untouched" do
    cands = [{"a.test", "1.1.1.1"}, {"b.test", "2.2.2.2"}, {"c.test", "3.3.3.3"}, {"d.test", "4.4.4.4"}]

    http_res = %{
      "a.test" => %{http_status: 429},
      "b.test" => %{http_status: 429},
      "c.test" => %{http_status: 200},
      "d.test" => %{http_error: "transport:timeout"}
    }

    by_domain = %{
      "a.test" => %{ctl_domain: "a.test"},
      "b.test" => %{ctl_domain: "b.test", after_429: true},
      "c.test" => %{ctl_domain: "c.test"},
      "d.test" => %{ctl_domain: "d.test"}
    }

    assert WorkerAgent.throttled_once(cands, http_res, by_domain) == [{"a.test", "1.1.1.1"}]
  end

  test "a candidate with no result is not throttled (the deadline cut owns it)" do
    assert WorkerAgent.throttled_once([{"x.test", "1.1.1.1"}], %{}, %{"x.test" => %{}}) == []
  end

  test "only English and French homepages earn a secondary page" do
    assert WorkerAgent.market_language?("en")
    assert WorkerAgent.market_language?("en-US")
    assert WorkerAgent.market_language?("fr")
    refute WorkerAgent.market_language?("de")
    refute WorkerAgent.market_language?("")
    refute WorkerAgent.market_language?(nil)
  end
end
