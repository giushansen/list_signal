defmodule LS.HTTP.NeverContactGroupAndRedirectTest do
  use ExUnit.Case, async: true

  alias LS.HTTP.{Client, NeverContact}

  @moduledoc """
  2026-09-25: third abuse report from the Shinhan Financial Group CERT via
  Vultr, this time a connection from ny2 to one of their hosts on port
  10243 at 07:32:40 UTC. No Shinhan domain was crawled; the never-contact
  list held. The connection came from the camoufox render of another page
  (abbotts.com or abacedin.com.br, rendered on ny2 in that minute) loading
  a third-party resource on their host and port. Three rules follow:
  the whole group is blocked by name, the browser sidecar gates every
  request a page triggers (standard ports, no IP literals, no blocked
  hosts), and the HTTP client never follows a redirect to a non-standard
  port, an IP literal, or a blocked host.
  """

  describe "the group is blocked by name" do
    test "every Shinhan brand and any domain containing the word" do
      for d <- ~w(shinhan.com www.shinhanbank.com shinhanlife.org shinhancareer.co.kr api.shinhandigitalforum.com shinhanclub.com anything-shinhan-x.kr) do
        assert NeverContact.blocked?(d), d
      end
    end

    test "unrelated sites are not blocked" do
      refute NeverContact.blocked?("example.com")
      refute NeverContact.blocked?("shopify.com")
    end

    test "the browser gets the words and the exact list" do
      list = LS.Enrichment.Browser.blocked_list()
      assert "shinhan" in list
      assert "shinhangroup.com" in list
    end
  end

  describe "redirects the client refuses" do
    test "a Location naming a non-standard port is not followed" do
      assert Client.resolve_redirect("a.example", "/", "https://b.example:10243/x") == :stop
      assert Client.resolve_redirect("a.example", "/", "http://b.example:8080/") == :stop
    end

    test "a Location on an IP literal is not followed" do
      assert Client.resolve_redirect("a.example", "/", "https://1.2.3.4/") == :stop
      assert Client.resolve_redirect("a.example", "/", "http://10.1.2.220/") == :stop
    end

    test "a Location on a never-contact host is not followed" do
      assert Client.resolve_redirect("a.example", "/", "https://www.shinhan.com/") == :stop
    end

    test "ordinary redirects still work" do
      assert Client.resolve_redirect("a.example", "/", "https://www.a.example/home") == {:ok, "www.a.example", "/home"}
      assert Client.resolve_redirect("a.example", "/", "https://b.example:443/") == {:ok, "b.example", "/"}
      assert Client.resolve_redirect("a.example", "/contact", "/contact/") == {:ok, "a.example", "/contact/"}
    end
  end
end
