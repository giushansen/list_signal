defmodule LS.HTTP.RobotsTest do
  use ExUnit.Case, async: false

  alias LS.HTTP.Robots

  @moduledoc """
  robots.txt is the opt-out the /bot page promises. Until 2026-09-06 no code
  read robots.txt at all, so the promise was false while two Vultr abuse
  reports in one week (2026-08-28, 2026-09-04) each threatened termination.
  These tests pin both halves: the parser/matcher semantics (RFC 9309), and
  the fact that every engine (plain HTTP, camoufox, the recrawl and both
  enrichment lanes) actually consults the decision.
  """

  setup do
    for d <- ["opted-out.example", "partial.example", "open.example"], do: Robots.forget(d)
    :ok
  end

  describe "parse/1 picks the right group" do
    test "a Disallow for everyone applies to us" do
      assert Robots.parse("User-agent: *\nDisallow: /\n") == [{:disallow, "/"}]
    end

    test "our own group wins over the wildcard group" do
      body = """
      User-agent: *
      Disallow: /

      User-agent: ListSignalBot
      Disallow: /private/
      """

      assert Robots.parse(body) == [{:disallow, "/private/"}]
    end

    test "a group naming us and others on consecutive lines is ours" do
      body = "User-agent: Googlebot\nUser-agent: listsignalbot\nDisallow: /x\n\nUser-agent: *\nDisallow: /\n"
      assert Robots.parse(body) == [{:disallow, "/x"}]
    end

    test "an empty Disallow allows everything" do
      assert Robots.parse("User-agent: *\nDisallow:\n") == []
    end

    test "field names and the agent token are case-insensitive, comments and CRLF are fine" do
      body = "# hello\r\nUSER-AGENT: LISTSIGNALBOT # us\r\nDISALLOW: /a # nope\r\nAllow: /a/b\r\n"
      assert Robots.parse(body) == [{:disallow, "/a"}, {:allow, "/a/b"}]
    end

    test "rules for other bots only never apply to us" do
      assert Robots.parse("User-agent: Googlebot\nDisallow: /\n") == []
    end

    test "hostile bodies allow everything instead of raising" do
      assert Robots.parse(nil) == []
      assert Robots.parse(%{}) == []
      assert Robots.parse(<<0, 255, 1, 2>>) == []
      assert Robots.parse("") == []
      assert Robots.parse(String.duplicate("Disallow: /\n", 500_000)) == []
      assert Robots.parse("User-agent: *\nDisallow: /\n" <> :crypto.strong_rand_bytes(300_000)) |> is_list()
    end

    test "the rule count is bounded whatever the file says" do
      body = "User-agent: *\n" <> String.duplicate("Disallow: /x\n", 50_000)
      assert length(Robots.parse(body)) <= 1_000
    end
  end

  describe "allowed?/2 (longest match wins, Allow wins ties)" do
    test "a blanket Disallow blocks every path" do
      rules = [{:disallow, "/"}]
      refute Robots.allowed?(rules, "/")
      refute Robots.allowed?(rules, "/about")
      refute Robots.allowed?(rules, "/products.json")
    end

    test "a prefix Disallow blocks only under it" do
      rules = [{:disallow, "/private/"}]
      refute Robots.allowed?(rules, "/private/x")
      assert Robots.allowed?(rules, "/")
      assert Robots.allowed?(rules, "/privately")
    end

    test "a longer Allow carves an exception out of a Disallow" do
      rules = [{:disallow, "/"}, {:allow, "/public/"}]
      assert Robots.allowed?(rules, "/public/page")
      refute Robots.allowed?(rules, "/secret")
    end

    test "wildcards and end anchors" do
      rules = [{:disallow, "/*.pdf$"}, {:disallow, "/tmp*"}]
      refute Robots.allowed?(rules, "/docs/a.pdf")
      assert Robots.allowed?(rules, "/docs/a.pdf?x=1")
      refute Robots.allowed?(rules, "/tmpfiles/1")
      assert Robots.allowed?(rules, "/temp")
    end

    test "no rules or a nil path never raise and allow" do
      assert Robots.allowed?([], "/")
      assert Robots.allowed?([{:disallow, "/x"}], nil)
      assert Robots.allowed?(:garbage, "/")
      assert Robots.allowed?([{:disallow, "(("}], "/((")
    end
  end

  describe "the engines consult the decision" do
    test "Client.fetch/3 refuses a robots-disallowed path before the rate limiter" do
      Robots.seed("opted-out.example", [{:disallow, "/"}])

      assert {:error, "robots_disallow", :robots_disallow} =
               LS.HTTP.Client.fetch("opted-out.example", "203.0.113.10", [])

      assert {:error, "robots_disallow", :robots_disallow} =
               LS.HTTP.Client.fetch("opted-out.example", "203.0.113.10", path: "/about")
    end

    test "only the disallowed paths are refused" do
      Robots.seed("partial.example", [{:disallow, "/private/"}])
      assert {:error, "robots_disallow", :robots_disallow} =
               LS.HTTP.Client.fetch("partial.example", "203.0.113.10", path: "/private/x")
      # An allowed path proceeds past the gate (and then fails on the
      # unroutable TEST-NET address, which is the point: it was attempted).
      assert Robots.check("partial.example", "203.0.113.10", "/") == :allow
    end

    test "the robots.txt request itself is exempt, or the check would recurse" do
      assert Robots.exempt?("/robots.txt")
      assert Robots.exempt?("/robots.txt?x=1")
      refute Robots.exempt?("/")
      refute Robots.exempt?("/about")
    end

    test "Browser.render/2 honours the same opt-out" do
      Robots.seed("opted-out.example", [{:disallow, "/"}])
      assert {:error, :robots_disallow} = LS.Enrichment.Browser.render("opted-out.example", "/")
    end

    test "the recrawl and both enrichment lanes leave an opted-out domain alone" do
      src = File.read!("lib/ls/clickhouse.ex")

      [stale | _] = String.split(src, "def stale_domains") |> Enum.drop(1)
      assert stale =~ "http_error != 'robots_disallow'",
             "stale_domains must not put an opted-out domain back on the HTTP schedule"

      [lanes | _] = String.split(src, "def enrichment_lane_filter(opts)") |> Enum.drop(1)
      [lanes | _] = String.split(lanes, "\n  end\n")
      assert length(String.split(lanes, "b.last_http_error != 'robots_disallow'")) == 3,
             "both the browser lane and the HTTP lane must exclude robots_disallow"
    end

    test "the transparency page promises exactly what the code does" do
      page = File.read!("lib/ls_web/controllers/page_html/bot.html.heex")
      assert page =~ "User-agent: ListSignalBot"
      assert page =~ "Disallow: /"
    end
  end

  describe "cache" do
    test "a seeded decision expires" do
      Robots.seed("open.example", [{:disallow, "/"}], -1)
      assert Robots.lookup("open.example") == :miss
    end

    test "lookup of an unknown domain is a miss, not a crash" do
      assert Robots.lookup("never-seen.example") == :miss
    end
  end
end
