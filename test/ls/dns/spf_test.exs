defmodule LS.DNS.SPFTest do
  use ExUnit.Case, async: true

  alias LS.DNS.SPF

  # Real dns_txt bundle for facebook.com, straight out of production ClickHouse.
  @facebook_txt "google-site-verification=wdH5DTJTc9AYNwVunSVFeK0hYDGUIEOGb-RReU6pJlY|" <>
                  "facebook-domain-verification=y7isfmi3kzyg1r4wophh9vyb6pgbda|" <>
                  "v=spf1 redirect=_spf.facebook.com|" <>
                  "zoom-domain-verification=4b2ef4e1-6dee-4483-9869-9bef353fd147"

  describe "redirect= modifier (the facebook.com regression)" do
    test "facebook.com is not graded weak" do
      spf = SPF.parse(@facebook_txt)

      refute spf.summary =~ "Weak"
      refute spf.tier == :bronze
      assert spf.tier == :silver
      assert spf.summary =~ "_spf.facebook.com"
    end

    test "a redirect alongside mechanisms grades higher" do
      spf = SPF.parse("v=spf1 ip4:1.2.3.4 include:_spf.example.com redirect=_spf.other.com")

      assert spf.tier == :gold
      assert spf.summary =~ "redirect to _spf.other.com"
    end
  end

  describe "mechanisms other than include:" do
    test "ip4/ip6/a/mx/exists all count as authorised senders" do
      for record <- [
            "v=spf1 ip4:192.0.2.0/24 -all",
            "v=spf1 ip6:2001:db8::/32 -all",
            "v=spf1 a -all",
            "v=spf1 a:mail.example.com -all",
            "v=spf1 mx -all",
            "v=spf1 mx:mail.example.com -all",
            "v=spf1 exists:%{i}._spf.example.com -all"
          ] do
        spf = SPF.parse(record)
        refute spf.tier == :bronze, "#{record} was graded #{spf.tier}: #{spf.summary}"
        assert spf.summary =~ "1 mechanism", record
      end
    end

    test "counts mixed mechanisms" do
      spf = SPF.parse("v=spf1 ip4:1.2.3.4 ip4:5.6.7.8 mx include:_spf.google.com -all")

      assert spf.tier == :gold
      assert spf.summary =~ "4 mechanisms"
      assert spf.summary =~ "strict (-all)"
    end
  end

  describe "all-qualifiers" do
    test "-all is strict" do
      assert SPF.parse("v=spf1 include:a.com -all").summary =~ "strict (-all)"
    end

    test "~all is soft" do
      assert SPF.parse("v=spf1 include:a.com ~all").summary =~ "soft (~all)"
    end

    test "?all enforces nothing" do
      spf = SPF.parse("v=spf1 include:a.com ?all")
      assert spf.tier == :bronze
      assert spf.summary =~ "?all enforces nothing"
    end

    test "+all and a bare all authorise the whole internet" do
      for record <- ["v=spf1 include:a.com +all", "v=spf1 include:a.com all"] do
        spf = SPF.parse(record)
        assert spf.tier == :bronze, record
        assert spf.summary =~ "+all authorises every sender", record
      end
    end

    test "no all and no redirect is the only genuinely incomplete record" do
      spf = SPF.parse("v=spf1 include:a.com")
      assert spf.tier == :bronze
      assert spf.summary =~ "no all mechanism"
    end
  end

  describe "no-mail domains" do
    test "v=spf1 -all is a valid, strict 'this domain sends no mail' record" do
      spf = SPF.parse("v=spf1 -all")
      assert spf.tier == :silver
      assert spf.summary =~ "No-mail domain"
    end
  end

  describe "known-good records from large senders" do
    # Each of these is a real, correctly-configured record; none may be bronze.
    @good [
      {"google.com", "v=spf1 include:_spf.google.com ~all"},
      {"facebook.com", "v=spf1 redirect=_spf.facebook.com"},
      {"microsoft.com", "v=spf1 include:_spf-a.microsoft.com include:_spf-b.microsoft.com " <>
         "include:_spf-c.microsoft.com include:_spf-ssg-a.msft.net ip4:147.243.1.153 -all"},
      {"amazon.com", "v=spf1 include:spf1.amazon.com include:spf2.amazon.com " <>
         "include:amazonses.com -all"},
      {"apple.com", "v=spf1 ip4:17.0.0.0/8 include:spf.apple.com ~all"},
      {"shopify.com", "v=spf1 include:_spf.google.com include:spf.mandrillapp.com " <>
         "include:servers.mcsv.net -all"},
      {"stripe.com", "v=spf1 include:amazonses.com include:_spf.google.com ~all"}
    ]

    for {domain, record} <- @good do
      test "#{domain} is not graded weak" do
        spf = SPF.parse(unquote(record))

        assert spf.tier in [:gold, :silver],
               "#{unquote(domain)} graded #{spf.tier}: #{spf.summary}"

        refute spf.summary =~ "Weak"
        refute spf.summary =~ "no qualifier"
      end
    end
  end

  describe "input handling" do
    test "returns nil when there is no SPF record" do
      assert SPF.parse(nil) == nil
      assert SPF.parse("") == nil
      assert SPF.parse("google-site-verification=abc|v=DMARC1") == nil
      assert SPF.parse(12_345) == nil
    end

    test "finds the SPF record anywhere in the pipe-joined bundle" do
      assert SPF.parse("a=b|c=d|v=spf1 include:x.com -all|e=f").tier == :silver
    end

    test "tolerates leading whitespace around records" do
      assert SPF.parse("a=b| v=spf1 include:x.com -all ").tier == :silver
    end

    test "recovers records whose TXT chunks were concatenated without spaces" do
      # Real shape seen in production for qq.com / 163.com mail domains.
      spf = SPF.parse("v=spf1include:spf.mail.qq.com~all")

      assert spf.tier == :silver
      assert spf.summary =~ "1 mechanism"
      assert spf.summary =~ "soft (~all)"
    end

    test "an SPF record with nothing but the version is incomplete, not a crash" do
      assert SPF.parse("v=spf1").tier == :bronze
    end
  end

  test "the phrase that started this ('no qualifier') is gone for good" do
    records = [
      "v=spf1 redirect=_spf.facebook.com",
      "v=spf1 ip4:1.2.3.4 -all",
      "v=spf1 mx ~all",
      "v=spf1 include:a.com",
      "v=spf1 -all"
    ]

    for r <- records do
      refute SPF.parse(r).summary =~ "no qualifier", r
    end
  end
end
