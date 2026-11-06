defmodule LS.HTTP.NeverContactSkieseliteTest do
  use ExUnit.Case, async: true

  alias LS.HTTP.{Client, NeverContact}

  @moduledoc """
  2026-10-29, fourth abuse report through Vultr, read on 11-06 with a
  24 hour notice before the instance is powered down. skieselite.com, a
  domain whose certificate first appeared in the CT logs on 10-28, served
  sg2 a "Sign in / Loading security check" homepage at 22:06:04 UTC, then
  reported four requests to /api/internal/session-meta two minutes later
  from a browser-like user agent we never send. Our record holds two
  requests, robots.txt and the homepage, with the declared bot UA; the
  page reader never fetches a path under /api, and the depth lane never
  took the domain. The site is still off-limits for good, on every engine,
  because the exposure is the Vultr account, not the data.
  """

  describe "skieselite.com never hears from us again" do
    test "the domain, www, and any subdomain are blocked" do
      for d <- ~w(skieselite.com www.skieselite.com media.skieselite.com SKIESELITE.COM skieselite.com.) do
        assert NeverContact.blocked?(d), d
      end
    end

    test "the plain client refuses before any socket, on any path" do
      assert {:error, "never_contact", :never_contact} = Client.fetch("skieselite.com", "104.21.84.24")
      assert {:error, "never_contact", :never_contact} = Client.fetch("www.skieselite.com", "172.67.185.8", path: "/api/internal/session-meta")
    end

    test "the browser sidecar gets the name on its blocklist" do
      assert "skieselite.com" in NeverContact.all()
      assert "skieselite" in NeverContact.stems()
    end

    test "neighbours with a similar shape are not swept up" do
      refute NeverContact.blocked?("skies.com")
      refute NeverContact.blocked?("elite.com")
      refute NeverContact.blocked?("skieselite-fans.example")
    end
  end

  describe "the path in the report was never one we would ask for" do
    test "a link under /api is recorded but never planned as a secondary page" do
      assert LS.HTTP.PageExtractor.page_kind("/api/internal/session-meta") == nil
      assert LS.Pipeline.secondary_plan(["Cloudflare", "Next.js", "Vercel"], "/api/internal/session-meta") == []
      assert LS.HTTP.PageExtractor.pages_to_visit("/api/internal/session-meta") == []
    end
  end
end
