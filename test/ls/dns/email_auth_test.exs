defmodule LS.DNS.EmailAuthTest do
  use ExUnit.Case, async: true

  alias LS.DNS.EmailAuth

  @moduledoc """
  DMARC / BIMI / DKIM parsing and probe budgeting (2026-09-06). The revenue
  estimator's DMARC signal had read the apex TXT record since it was
  written, where DMARC never lives, so it voted "micro" for every domain.
  These records are third-party data: every parser here must survive
  garbage without raising, and the probe budget must stay bounded because
  every domain with MX pays for it in the discovery pipeline.
  """

  describe "parse_dmarc/1" do
    test "reads the domain policy, ignoring the subdomain policy" do
      assert EmailAuth.parse_dmarc(["v=DMARC1; p=reject; sp=none; rua=mailto:x@y"]) == "reject"
      assert EmailAuth.parse_dmarc(["v=DMARC1;p=quarantine"]) == "quarantine"
      assert EmailAuth.parse_dmarc(["V=dmarc1 ; P = None ;"]) == "none"
    end

    test "a record that is not DMARC, or has no valid policy, is empty" do
      assert EmailAuth.parse_dmarc(["v=spf1 -all"]) == ""
      assert EmailAuth.parse_dmarc(["v=DMARC1; p=bogus"]) == ""
      assert EmailAuth.parse_dmarc(["p=reject"]) == "", "without v=DMARC1 it is not a DMARC record"
      assert EmailAuth.parse_dmarc([]) == ""
    end

    test "hostile input never raises" do
      assert EmailAuth.parse_dmarc(nil) == ""
      assert EmailAuth.parse_dmarc([nil, 42, <<255, 0>>]) == ""
      assert EmailAuth.parse_dmarc([String.duplicate("v=DMARC1;", 100_000)]) == ""
      assert EmailAuth.parse_dmarc(["v=DMARC1; p=reject" <> String.duplicate(";x=y", 50_000)]) == "reject"
    end
  end

  describe "parse_bimi/1" do
    test "returns the https logo URL" do
      assert EmailAuth.parse_bimi(["v=BIMI1; l=https://cdn.example.com/logo.svg; a=https://cdn.example.com/vmc.pem"]) ==
               "https://cdn.example.com/logo.svg"
    end

    test "refuses non-https and non-BIMI records, caps length, strips separators" do
      assert EmailAuth.parse_bimi(["v=BIMI1; l=http://x/logo.svg"]) == ""
      assert EmailAuth.parse_bimi(["v=spf1 l=https://x"]) == ""
      long = EmailAuth.parse_bimi(["v=BIMI1; l=https://x/" <> String.duplicate("a", 5_000)])
      assert String.length(long) <= 200
      refute EmailAuth.parse_bimi(["v=BIMI1; l=https://x/a|b\tc"]) =~ ~r/[|\t]/
      assert EmailAuth.parse_bimi(nil) == ""
    end
  end

  describe "dkim?/1" do
    test "recognises a key record in either common form" do
      assert EmailAuth.dkim?(["v=DKIM1; k=rsa; p=MIGfMA0GCSq..."])
      assert EmailAuth.dkim?(["k=rsa; p=MIIBIjANBg..."])
      refute EmailAuth.dkim?(["v=spf1 include:_spf.google.com ~all"])
      refute EmailAuth.dkim?([])
      refute EmailAuth.dkim?(:nope)
    end
  end

  describe "selectors_for/1 keeps the probe budget" do
    test "picks the provider's selectors from the MX hosts" do
      assert EmailAuth.selectors_for(["10:aspmx.l.google.com"]) == ["google", "k1"]
      assert EmailAuth.selectors_for(["0:example-com.mail.protection.outlook.com"]) == ["selector1", "selector2"]
      assert EmailAuth.selectors_for(["10:mx.zoho.eu"]) == ["zoho", "zmail"]
    end

    test "an unknown provider still probes, within budget" do
      sels = EmailAuth.selectors_for(["10:mail.example.com"])
      assert length(sels) == EmailAuth.max_dkim_probes()
    end

    test "never more than the budget, never raises" do
      assert length(EmailAuth.selectors_for(Enum.map(1..50, &"#{&1}:mx#{&1}.google.com"))) <= EmailAuth.max_dkim_probes()
      assert EmailAuth.selectors_for(nil) == []
      assert EmailAuth.selectors_for([nil, 12]) |> is_list()
    end
  end

  describe "lookup/2" do
    test "a domain without MX costs nothing and yields empty fields" do
      assert EmailAuth.lookup("example.com", []) == %{dmarc: "", bimi: "", dkim: ""}
      assert EmailAuth.lookup(nil, ["10:mx"]) == %{dmarc: "", bimi: "", dkim: ""}
    end
  end
end
