defmodule LS.HTTP.NeverContactTest do
  use ExUnit.Case, async: true

  alias LS.HTTP.NeverContact

  @moduledoc """
  The abuse-report firewall. Two Vultr reports in one week (2026-08
  morbihan-genealogie.bzh, 2026-09-04 xayann-services.com), each ending in
  "mitigation or VPS termination". A third strike risks the account, so a
  domain that has reported us once must be unreachable by every engine on
  every node, and that promise is cheap to test and catastrophic to break.
  """

  describe "blocked?/1" do
    test "a reported domain is blocked, including the www form the report named" do
      assert NeverContact.blocked?("xayann-services.com")
      assert NeverContact.blocked?("www.xayann-services.com")
      assert NeverContact.blocked?("morbihan-genealogie.bzh")
      assert NeverContact.blocked?("www.morbihan-genealogie.bzh")
    end

    test "case, trailing dots and deep subdomains cannot slip through" do
      assert NeverContact.blocked?("WWW.Xayann-Services.COM")
      assert NeverContact.blocked?("xayann-services.com.")
      assert NeverContact.blocked?("shop.mail.xayann-services.com")
    end

    test "everyone else is untouched, including lookalikes" do
      refute NeverContact.blocked?("example.com")
      refute NeverContact.blocked?("xayann-services.com.evil.example")
      refute NeverContact.blocked?("notxayann-services.com")
    end

    test "hostile input is not on the list rather than a crash" do
      refute NeverContact.blocked?(nil)
      refute NeverContact.blocked?(12_345)
      refute NeverContact.blocked?("")
      refute NeverContact.blocked?(String.duplicate("a.", 5_000) <> "com")
    end
  end

  describe "the choke points actually consult the list" do
    test "Client.fetch/3 refuses a reported domain before the rate limiter" do
      assert {:error, "never_contact", :never_contact} =
               LS.HTTP.Client.fetch("www.xayann-services.com", "203.0.113.10", [])
    end

    test "Browser.render/2 refuses a reported domain before the sidecar" do
      # 'we sent a real browser instead' is not a defense Vultr accepts twice
      assert {:error, :never_contact} = LS.Enrichment.Browser.render("xayann-services.com")
    end
  end

  describe "the crawler identity" do
    test "the HTTP lane declares ListSignalBot, never a fake browser" do
      # Both Vultr reports named 'Rogue User-Agent identification' as the
      # trigger: rotating desktop Chrome/Firefox strings from a client that
      # cannot pass a JS challenge is the exact fingerprint of malware to a
      # WAF. The UA must declare the bot and link the transparency page.
      src = File.read!("lib/ls/http/client.ex")

      assert src =~ "ListSignalBot",
             "the crawler must identify itself honestly"

      assert src =~ "+https://listsignal.com/bot",
             "the UA must link the transparency page a site owner can act on"

      refute Regex.match?(~r/"Mozilla[^"]*(Chrome|Firefox)\/\d[^"]*"/, src),
             "no fake desktop-browser User-Agent may reappear in the HTTP lane"
    end

    test "the recrawl scheduler never re-selects WAF-blocked domains for plain HTTP" do
      # 2.26M domains sat at 403/503 when this was written, each re-hit
      # on schedule from a rotating IP. Blocked domains belong to the
      # browser lane; the plain-HTTP recrawl must exclude them.
      src = File.read!("lib/ls/clickhouse.ex")
      [stale | _] = String.split(src, "def stale_domains") |> Enum.drop(1)
      [body | _] = String.split(stale, "def ")

      assert body =~ "http_status NOT IN (403, 503)",
             "stale_domains must exclude blocked statuses from plain-HTTP recrawl"

      refute body =~ ~r/NOT IN \([^)]*429/,
             "429 means come back later, not a wall: excluding it from recrawl would silently lose 388K rate-limited domains (2026-08-02 lesson)"
    end
  end
end
