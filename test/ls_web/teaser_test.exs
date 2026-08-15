defmodule LSWeb.TeaserTest do
  use ExUnit.Case, async: true

  alias LSWeb.Teaser

  # The whole point of this module: a blur is one devtools click from gone,
  # so whatever sits behind it must be fake. The "-x" marker is the proof.
  test "every fake email and subdomain carries the -x fake marker" do
    for fake <- Teaser.fake_emails("acme.com", 3), do: assert fake =~ ~r/-x\d+@acme\.com$/
    for fake <- Teaser.fake_subdomains("acme.com", 6), do: assert fake =~ ~r/-x\d\.acme\.com$/
  end

  test "fakes are deterministic so cached pages stay stable" do
    assert Teaser.fake_emails("acme.com", 3) == Teaser.fake_emails("acme.com", 3)
    assert Teaser.fake_subdomains("acme.com", 4) == Teaser.fake_subdomains("acme.com", 4)
  end

  test "counts are capped and zero/negative yields empty" do
    assert length(Teaser.fake_emails("a.com", 99)) == 3
    assert length(Teaser.fake_subdomains("a.com", 99)) == 6
    assert Teaser.fake_emails("a.com", 0) == []
    assert Teaser.fake_subdomains("a.com", -1) == []
  end
end

defmodule LSWeb.StoreDmarcTest do
  use ExUnit.Case, async: true

  # Regression: the checker grepped APEX TXT for v=DMARC, but DMARC lives at
  # _dmarc.<domain> — every correctly-configured domain (listsignal.com
  # included) showed "❌ No DMARC" on its own public page (found 2026-08-15).
  # `.invalid` is RFC-2606-reserved, so the live _dmarc lookup deterministically
  # returns nothing and these tests exercise the fallback path offline.
  import LSWeb.StoreController, only: [fetch_dmarc_policy: 2]

  test "apex-inlined DMARC still counts, with its policy extracted" do
    assert fetch_dmarc_policy("x.invalid", "v=spf1 a mx | v=DMARC1; p=quarantine; rua=...") == "quarantine"
  end

  test "policy defaults to none when p= is missing" do
    assert fetch_dmarc_policy("x.invalid", "v=DMARC1; rua=mailto:a@b.c") == "none"
  end

  test "no DMARC anywhere yields nil, which renders as No DMARC" do
    assert fetch_dmarc_policy("x.invalid", "v=spf1 include:_spf.google.com ~all") == nil
  end
end
