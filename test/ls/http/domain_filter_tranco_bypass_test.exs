defmodule LS.HTTP.DomainFilterTrancoBypassTest do
  use ExUnit.Case, async: false

  alias LS.HTTP.DomainFilter
  alias LS.Reputation.Tranco

  @moduledoc """
  The Tranco bypass is the FIRST clause of `verdict/5`, before the
  junk-name rule, and that ordering is deliberate: measured 2026-07-26/27,
  the shape heuristics were skipping about 150K domains with independently
  measured traffic per 1.5 days. A ranked name is crawled whatever its
  shape.

  Written 2026-10-04 because the interaction is a trap. The rank table
  loaded on this machine holds 4,637,479 names, and three of them look
  like textbook junk: a-b-c.com, a-b-c-5.com, a-b-c-8.com. So
  `verdict("a-b-c.com", ...)` is `:crawl` once reference data is up and
  `{:skip, :junk_name}` before it, which makes any test that pins a fixed
  answer for that name depend on load timing. These tests pin the
  relationship instead of the answer, so they hold either way.
  """

  @spf "v=spf1 include:_spf.google.com ~all"

  setup_all do
    DomainFilter.load_tlds()
    :ok
  end

  test "a junk-shaped name no reputation list could carry is a junk skip, always" do
    # .invalid can never appear in Tranco (RFC 2606), so no reference data
    # can change this answer, and junk_name is checked before the TLD rule.
    assert {:skip, :junk_name} = DomainFilter.verdict("a-b-c.invalid", "mx.example", @spf)
    assert {:skip, :junk_name} = DomainFilter.verdict("a-b-c.invalid", "", "")
  end

  test "whether a junk-shaped name crawls follows its rank, in both directions" do
    for d <- ["a-b-c.com", "a-b-c-8.com"] do
      verdict = DomainFilter.verdict(d, "aspmx.l.google.com", @spf)

      if Tranco.ranked?(d) do
        assert verdict == :crawl,
               "#{d} is ranked, so the bypass must win over its shape (worth ~150K domains per 1.5 days)"
      else
        assert verdict == {:skip, :junk_name},
               "#{d} is not ranked here, so the shape rule decides"
      end
    end
  end

  test "the bypass is the first clause: nothing else can overrule a ranked name" do
    # Source-level, because the cond's order is the whole point and a
    # reordering would be invisible to any single-name assertion.
    src = File.read!("lib/ls/http/domain_filter.ex")
    [_, body] = String.split(src, "def verdict(domain, mx, txt, ip \\\\ nil, issuer \\\\ \"\") do", parts: 2)
    clauses = body |> String.split("end", parts: 2) |> hd()

    assert clauses =~ ~r/cond do\s*\n\s*tranco_ranked\?\(domain\) -> :crawl/,
           "tranco_ranked? must stay the first clause of verdict/5"

    assert String.contains?(clauses, "not not_junk_domain?(domain) -> {:skip, :junk_name}")
  end
end
