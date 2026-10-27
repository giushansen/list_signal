defmodule LS.Email.ScoreTest do
  @moduledoc """
  2026-10-27: addresses are scored from our own evidence, no SMTP
  handshake (catch-all domains and Microsoft 365 defeat it, and probing
  would put our addresses on blocklists). Every point has a line a
  customer can read; these pin the points, the verdict bands and the lines.
  """
  use ExUnit.Case, async: true

  alias LS.Email.Score

  @now ~U[2026-10-27 12:00:00Z]

  defp facts(over), do: Map.merge(%{email: "jane@acme.com", domain: "acme.com", mx: true, provider: "Google Workspace", spf: true, dmarc: true, source_page: "contact", last_seen: ~U[2026-10-26 12:00:00Z], now: @now}, over)

  test "a person's address on the contact page, mail set up, seen yesterday is strong with every reason listed" do
    r = Score.score(facts(%{}))
    # 20 page + 15 kind + 20 seen + 25 mx + 5 provider + 3 spf + 2 dmarc
    assert r.score == 90
    assert r.verdict == "strong"
    assert r.evidence == ["published on the contact page", "a person's mailbox on acme.com", "seen on the site 1 days ago", "MX present (Google Workspace)", "SPF published", "DMARC published"]
  end

  test "the verdict bands: strong from 75, good from 55, weak below" do
    assert Score.verdict(75) == "strong"
    assert Score.verdict(74) == "good"
    assert Score.verdict(55) == "good"
    assert Score.verdict(54) == "weak"
    # homepage, role, seen 100 days ago, MX only, unknown provider: 15 + 15 + 8 + 25 = 63
    r = Score.score(facts(%{source_page: "homepage", email: "info@acme.com", last_seen: ~U[2026-07-19 00:00:00Z], provider: "Other", spf: false, dmarc: false}))
    assert {r.score, r.verdict} == {63, "good"}
    assert "a role mailbox on acme.com" in r.evidence
    assert "MX present" in r.evidence
  end

  test "no MX is undeliverable whatever else is true, and says so first" do
    r = Score.score(facts(%{mx: false}))
    assert r.verdict == "undeliverable"
    assert r.score <= 15
    assert hd(r.evidence) == "no MX record: mail cannot be delivered"
  end

  test "a disposable host is undeliverable at zero; a third party or placeholder is rejected" do
    assert %{score: 0, verdict: "undeliverable", evidence: ["disposable mail host"]} = Score.score(facts(%{disposable: true}))
    assert %{score: 0, verdict: "rejected"} = Score.score(facts(%{email: "press@gymshark.com"}))
    assert %{score: 0, verdict: "rejected"} = Score.score(facts(%{email: "name@company.com"}))
  end

  test "the owner's free-mail box and a sister domain score lower than an on-domain mailbox" do
    on = Score.score(facts(%{})).score
    sister = Score.score(facts(%{email: "jane@acme.co"})).score
    free = Score.score(facts(%{email: "acmeshop@gmail.com"})).score
    assert on > sister and sister > free
    assert "the owner's free-mail box" in Score.score(facts(%{email: "acmeshop@gmail.com"})).evidence
  end

  test "freshness decays and an address not seen for over a year asks to be re-verified" do
    seen = fn at -> Score.score(facts(%{last_seen: at})) end
    assert seen.(~U[2026-10-20 00:00:00Z]).score > seen.(~U[2026-08-20 00:00:00Z]).score
    assert seen.(~U[2026-08-20 00:00:00Z]).score > seen.(~U[2026-05-20 00:00:00Z]).score
    old = seen.(~U[2025-01-01 00:00:00Z])
    assert Enum.any?(old.evidence, &String.ends_with?(&1, "re-verify before sending"))
    unknown = Score.score(facts(%{last_seen: nil}))
    assert "seen date unknown" in unknown.evidence
    # A string timestamp from ClickHouse is read too.
    assert Score.score(facts(%{last_seen: "2026-10-26 12:00:00"})).score == 90
  end

  test "an imprint or policy page counts like the contact page; about and career a little less; the rest least" do
    page = fn p -> Score.score(facts(%{source_page: p})).score end
    assert page.("legal") == page.("contact") and page.("policy") == page.("contact")
    assert page.("about") < page.("contact") and page.("about") == page.("career")
    assert page.("pricing") < page.("about")
    assert "published on the imprint page" in Score.score(facts(%{source_page: "legal"})).evidence
  end

  test "hostile input never raises" do
    assert %{verdict: "rejected"} = Score.score(%{})
    assert %{verdict: "rejected"} = Score.score(%{email: nil, domain: "x"})
    assert %{} = Score.score(facts(%{last_seen: "garbage", kind: "weird"}))
  end

  test "the SQL form carries the same point table and the same evidence wording" do
    sql = Score.backfill_sql(3, 32)
    p = Score.points()
    for v <- [p.page_contact, p.kind_on_domain, p.mx, p.seen_30], do: assert(sql =~ Integer.to_string(v))
    assert sql =~ "INSERT INTO email_checks"
    assert sql =~ "cityHash64(b.domain) % 32 = 3"
    assert sql =~ "no MX record: mail cannot be delivered"
    assert sql =~ "re-verify before sending"
    assert sql =~ "a role mailbox on "
    assert sql =~ "max_execution_time = 600"
    assert_raise FunctionClauseError, fn -> Score.backfill_sql(32, 32) end
  end
end
