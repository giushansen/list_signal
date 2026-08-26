defmodule LS.HTTP.ClientRedirectTest do
  use ExUnit.Case, async: true

  alias LS.HTTP.Client

  # ==========================================================================
  # INCIDENT 2026-08-26 — the redirect follower dropped the target path.
  #
  # It switched to the redirect's HOST but re-sent the ORIGINAL path, and
  # ignored relative Location headers entirely. The commonest redirect on the
  # web is a trailing slash on the same host (/contact -> /contact/), so we
  # re-requested /contact, got the same 301 back, and burned every hop.
  #
  # Cost, measured over 300 domains through the real client: pipeline 2's
  # secondary pages (contact, pricing, login, career) succeeded only 76.2% of
  # the time, and 68% of those failures were this — 49.5% too_many_redirects
  # plus 18.7% raw 3xx handed back as if they were content. Every email,
  # price and job the enrichment lane collects was scaled down by it.
  # ==========================================================================
  describe "resolve_redirect/3 (2026-08-26: 68% of secondary-page failures)" do
    test "a trailing-slash redirect on the same host advances the path" do
      # The exact case that looped: skyhum.net/contact -> /contact/
      assert Client.resolve_redirect("skyhum.net", "/contact", "https://skyhum.net/contact/") ==
               {:ok, "skyhum.net", "/contact/"}
    end

    test "an absolute redirect carries the target path, not the original" do
      assert Client.resolve_redirect("acme.com", "/contact", "https://www.acme.com/contact-us") ==
               {:ok, "www.acme.com", "/contact-us"}
    end

    test "a root-relative Location is followed on the same host" do
      # Previously fell through to `_ ->` and was never followed at all: the
      # raw 301 was returned and read as if it were page content.
      assert Client.resolve_redirect("acme.com", "/contact", "/kontakt") ==
               {:ok, "acme.com", "/kontakt"}
    end

    test "a document-relative Location resolves against the current directory" do
      assert Client.resolve_redirect("acme.com", "/de/contact", "impressum") ==
               {:ok, "acme.com", "/de/impressum"}
    end

    test "the query string on the redirect target is preserved" do
      assert Client.resolve_redirect("acme.com", "/login", "https://acme.com/auth?next=/app") ==
               {:ok, "acme.com", "/auth?next=/app"}
    end

    test "a redirect to a bare host keeps a valid root path" do
      assert Client.resolve_redirect("acme.com", "/contact", "https://www.acme.com") ==
               {:ok, "www.acme.com", "/"}
    end

    test "a Location carrying no new target stops instead of looping" do
      # Following these would re-request the URL we are already on.
      assert Client.resolve_redirect("acme.com", "/contact", "") == :stop
      assert Client.resolve_redirect("acme.com", "/contact", "#section") == :stop
    end

    test "the original path is never reused for a different host" do
      # The precise shape of the bug: same path, new host.
      refute Client.resolve_redirect("acme.com", "/contact", "https://cdn.acme.com/login") ==
               {:ok, "cdn.acme.com", "/contact"}
    end

    test "a malformed Location never raises and never replays the original path" do
      # Garbage in a Location header is third-party data, so it must degrade
      # rather than crash. What it must NOT do is hand back the path we just
      # requested — that is the loop this incident was made of.
      for junk <- ["ht!tp://[[[", "http://", "///", "%%%", "\0bad"] do
        case Client.resolve_redirect("acme.com", "/contact", junk) do
          :stop -> :ok
          {:ok, _host, new_path} -> refute new_path == "/contact"
        end
      end
    end
  end
end
