defmodule LS.HTTP.FingerprintsTest do
  @moduledoc """
  The data-driven vendor fingerprint layer (2026-10-22): every name it can
  emit is a catalog entry, every pattern compiles, the evidence kinds it
  reads behave, and the one false positive found in review stays out.
  """
  use ExUnit.Case, async: true

  alias LS.HTTP.{Fingerprints, TechDetector}
  alias LS.Tech.Catalog

  test "every fingerprinted name is published by the catalog, so the closed list holds" do
    for name <- Fingerprints.names(), do: assert(Catalog.known?(name), "#{name} is fingerprinted but not in LS.Tech.Catalog")
    assert length(Fingerprints.names()) >= 250
  end

  test "every pattern compiles (a skipped pattern would be a silent hole)" do
    for {name, c} <- Fingerprints.compiled() do
      raw = Fingerprints.entry(name)
      assert length(c.script) == length(raw["script"] || []), "#{name}: a script pattern did not compile"
    end
  end

  test "script hosts, meta generators, headers and cookies each detect" do
    assert "HighLevel" in Fingerprints.detect(["https://stcdn.leadconnectorhq.com/_preview/B_l5wQCG.js"], %{}, %{}, [])
    assert "Usercentrics" in Fingerprints.detect(["https://web.cmp.usercentrics.eu/modules/autoblocker.js"], %{}, %{}, [])
    assert "Docusaurus" in Fingerprints.detect([], %{"generator" => "Docusaurus v3.5.2"}, %{}, [])
    assert "WP Engine" in Fingerprints.detect([], %{}, %{"x-powered-by" => "WP Engine"}, [])
    assert "Teachable" in Fingerprints.detect([], %{}, %{}, ["_gat_teachabletracker"])
    assert Fingerprints.detect([], %{}, %{}, []) == []
  end

  test "a Wix site is not a Hostinger site: the generic 'Website Builder' generator pattern is out" do
    refute "Hostinger Website Builder" in Fingerprints.detect([], %{"generator" => "Wix.com Website Builder"}, %{}, [])
    assert "Hostinger Website Builder" in Fingerprints.detect([], %{"generator" => "Hostinger Website Builder"}, %{}, [])
  end

  test "the layer runs inside TechDetector.detect/1 alongside the hand-written rules" do
    body = ~s(<html><head><meta name="generator" content="Divi v.4.27"><script src="https://cdn.trustindex.io/loader.js?ver=1"></script><script src="https://www.googletagmanager.com/gtm.js?id=GTM-1"></script></head><body></body></html>)
    tech = TechDetector.detect(%{body: body, headers: [{"server", "nginx"}]}).tech
    assert "Divi" in tech and "Trustindex" in tech
    assert "Google Tag Manager" in tech and "Nginx" in tech
  end

  test "hostile input never raises" do
    assert Fingerprints.detect(nil, nil, nil, nil) == []
    assert Fingerprints.detect([<<0xFF, 0xFE>>], %{"generator" => <<0xFF>>}, %{}, []) == []
    assert TechDetector.detect(%{body: <<0xFF, 0xFE, 0xFD>>, headers: []}).tech |> is_list()
  end

  test "mined vendors our own crawl surfaced are in: CallRail, Umami, CCM19, Leadoo" do
    assert "CallRail" in Fingerprints.detect(["//cdn.callrail.com/companies/509575822/abc/12/swap.js"], %{}, %{}, [])
    assert "Umami" in Fingerprints.detect(["https://cloud.umami.is/script.js"], %{}, %{}, [])
    assert "CCM19" in Fingerprints.detect(["https://cloud.ccm19.de/app.js?apiKey=x"], %{}, %{}, [])
    assert "Leadoo" in Fingerprints.detect(["https://bot.leadoo.com/bot/dynamic/chat.js?company=x"], %{}, %{}, [])
  end

  test "new DNS verification tokens name their vendor" do
    v = LS.DNS.Vendors.tech("zoho-verification=zb1|knowbe4-site-verification=abc|slack-domain-verification=xyz|canva-domain-verify=q", [], "")
    assert "Zoho" in v and "KnowBe4" in v and "Slack" in v and "Canva" in v
  end
end
