defmodule LS.DNS.VendorsTest do
  @moduledoc """
  `dns_email_provider` and `dns_tech` come from one rule list that produces
  both the Elixir functions and the ClickHouse expressions (2026-10-01).
  These pin the rules on real-shaped records and the shape of the SQL; the
  data-contract suite runs the SQL against a server.
  """
  use ExUnit.Case, async: true

  alias LS.DNS.Vendors

  test "mailbox provider from MX hosts" do
    assert Vendors.email_provider(["aspmx.l.google.com", "alt1.aspmx.l.google.com"]) == "Google Workspace"
    assert Vendors.email_provider("acme-com.mail.protection.outlook.com") == "Microsoft 365"
    assert Vendors.email_provider(["mx.zoho.eu"]) == "Zoho Mail"
    assert Vendors.email_provider(["mail.protonmail.ch"]) == "Proton Mail"
    assert Vendors.email_provider(["mx1.mimecast.com"]) == "Mimecast"
    assert Vendors.email_provider(["mail.example-selfhosted.net"]) == "Other"
    assert Vendors.email_provider([]) == ""
    assert Vendors.email_provider(nil) == ""
    assert Vendors.email_provider("") == ""
  end

  test "vendors from SPF includes, verification records and CNAMEs" do
    txt = "v=spf1 include:servers.mcsv.net include:sendgrid.net include:_spf.salesforce.com ~all|atlassian-domain-verification=abc|facebook-domain-verification=xyz"
    vendors = Vendors.tech(txt, ["aspmx.l.google.com"], "")
    assert "Mailchimp" in vendors
    assert "SendGrid" in vendors
    assert "Salesforce" in vendors
    assert "Atlassian" in vendors
    assert "Meta Business" in vendors
    refute "Google Workspace" in vendors, "mailbox providers are not repeated in dns_tech"
  end

  test "a security gateway in MX shows as a vendor too" do
    assert "Proofpoint" in Vendors.tech("", "mx0a-00123456.pphosted.com", "")
  end

  test "hostile input never raises and yields nothing" do
    assert Vendors.tech(nil, nil, nil) == []
    assert Vendors.tech(<<0, 255, 1>>, [], "") == []
    assert Vendors.email_provider(<<255, 254>>) == "Other"
  end

  test "the SQL mirrors the rules: one multiSearch per vendor, Other for unknown MX, empty for none" do
    sql = Vendors.email_provider_sql("h.dns_mx")
    assert sql =~ "multiSearchAnyCaseInsensitive(h.dns_mx, ['aspmx.l.google.com'"
    assert sql =~ "'Google Workspace'"
    assert sql =~ "h.dns_mx != '', 'Other', ''"

    tech = Vendors.tech_sql("h.dns_txt", "h.dns_mx", "h.dns_cname")
    assert tech =~ "lower(concat(h.dns_txt, '|', h.dns_mx, '|', h.dns_cname))"
    assert tech =~ "'Mailchimp'"
    assert tech =~ "arrayDistinct(arrayFilter(x -> x != ''"

    for {name, pats} <- Vendors.tech_rules() do
      assert tech =~ "'#{name}'"
      for p <- pats, do: assert(tech =~ "'#{p}'")
    end
  end

  test "every pattern is lowercase and quote-free, since the SQL lowercases the haystack" do
    for {_, pats} <- Vendors.tech_rules() ++ Vendors.providers(), p <- pats do
      assert p == String.downcase(p), p
      refute String.contains?(p, "'")
    end
  end
end
