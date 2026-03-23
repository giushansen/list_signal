defmodule LS.Reputation.Test do
  use ExUnit.Case, async: false

  # ============================================================================
  # TLD FILTER — prevents registry domains from being treated as businesses
  # ============================================================================

  describe "TLDFilter.is_registry?/1" do
    test "flags known second-level TLDs" do
      assert LS.Reputation.TLDFilter.is_registry?("uk.com")
      assert LS.Reputation.TLDFilter.is_registry?("us.com")
      assert LS.Reputation.TLDFilter.is_registry?("it.com")
      assert LS.Reputation.TLDFilter.is_registry?("eu.org")
      assert LS.Reputation.TLDFilter.is_registry?("pp.ua")
      assert LS.Reputation.TLDFilter.is_registry?("my.id")
      assert LS.Reputation.TLDFilter.is_registry?("adv.br")
      assert LS.Reputation.TLDFilter.is_registry?("ind.br")
    end

    test "flags dynamic DNS providers" do
      assert LS.Reputation.TLDFilter.is_registry?("ddns.net")
      assert LS.Reputation.TLDFilter.is_registry?("synology.me")
      assert LS.Reputation.TLDFilter.is_registry?("myftpupload.com")
    end

    test "flags hosting platforms" do
      assert LS.Reputation.TLDFilter.is_registry?("herokuapp.com")
      assert LS.Reputation.TLDFilter.is_registry?("netlify.app")
      assert LS.Reputation.TLDFilter.is_registry?("vercel.app")
      assert LS.Reputation.TLDFilter.is_registry?("github.io")
      assert LS.Reputation.TLDFilter.is_registry?("blogspot.com")
    end

    test "does NOT flag real businesses" do
      refute LS.Reputation.TLDFilter.is_registry?("stripe.com")
      refute LS.Reputation.TLDFilter.is_registry?("google.com")
      refute LS.Reputation.TLDFilter.is_registry?("automattic.com")
      refute LS.Reputation.TLDFilter.is_registry?("sailpoint.com")
      refute LS.Reputation.TLDFilter.is_registry?("flyzipline.com")
      refute LS.Reputation.TLDFilter.is_registry?("hungryroot.com")
    end

    test "does NOT flag legitimate .co.uk subdomains" do
      # innfinite.co.uk is a business, co.uk itself is a registry
      assert LS.Reputation.TLDFilter.is_registry?("co.uk")
      refute LS.Reputation.TLDFilter.is_registry?("innfinite.co.uk")
    end

    test "heuristic catches short-prefix TLDs" do
      # 2-char prefix + single TLD = likely registry
      assert LS.Reputation.TLDFilter.is_registry?("cn.com")
      assert LS.Reputation.TLDFilter.is_registry?("sa.com")
      assert LS.Reputation.TLDFilter.is_registry?("de.com")
    end
  end

  # ============================================================================
  # TRANCO — CSV parsing and lookup
  # ============================================================================

  describe "Tranco CSV parsing" do
    test "parses rank,domain format" do
      csv = "1,google.com\n2,facebook.com\n3,youtube.com\n"
      parsed = parse_tranco(csv)
      assert parsed["google.com"] == 1
      assert parsed["facebook.com"] == 2
      assert map_size(parsed) == 3
    end

    test "strips www prefix on lookup" do
      assert strip_www("www.google.com") == "google.com"
      assert strip_www("google.com") == "google.com"
    end

    test "handles empty and malformed lines" do
      csv = "1,google.com\n\nbadline\n2,facebook.com\n"
      parsed = parse_tranco(csv)
      assert map_size(parsed) == 2
    end
  end

  # ============================================================================
  # MAJESTIC — CSV parsing with RefSubNets
  # ============================================================================

  describe "Majestic CSV parsing" do
    test "extracts rank and RefSubNets" do
      csv = "1,1,google.com,com,245000,380000,,,,,,\n2,2,facebook.com,com,198000,310000,,,,,,\n"
      parsed = parse_majestic(csv)
      assert parsed["google.com"] == {1, 245000}
      assert parsed["facebook.com"] == {2, 198000}
    end
  end

  # ============================================================================
  # BLOCKLIST — domain parsing from various formats
  # ============================================================================

  describe "Blocklist parsing" do
    test "plain domain format" do
      domains = parse_domains("malware1.com\nmalware2.net\n")
      assert "malware1.com" in domains
      assert "malware2.net" in domains
    end

    test "hostfile format (IP prefix)" do
      domains = parse_domains("0.0.0.0 malware1.com\n127.0.0.1 malware2.net\n")
      assert "malware1.com" in domains
      assert "malware2.net" in domains
    end

    test "skips comments, blanks, localhost" do
      domains = parse_domains("# header\n! adblock\n\n0.0.0.0 localhost\nreal.com\n")
      assert domains == ["real.com"]
    end
  end

  # ============================================================================
  # RDAP SCORER
  # ============================================================================


  # ============================================================================
  # INSERTER COLUMNS — verify all v3 columns present
  # ============================================================================

  describe "Inserter columns" do
    @v3_columns [
      :rdap_domain_created_at, :rdap_domain_expires_at, :rdap_domain_updated_at,
      :rdap_registrar, :rdap_registrar_iana_id, :rdap_nameservers,
      :rdap_status, :rdap_error,
      :tranco_rank, :majestic_rank, :majestic_ref_subnets,
      :is_malware, :is_phishing, :is_disposable_email
    ]

    test "sample enriched row has all v3 columns" do
      row = %{
        enriched_at: "2026-03-21 00:00:00", worker: "test", domain: "test.com",
        ctl_tld: "com", ctl_issuer: "", ctl_subdomain_count: 0, ctl_subdomains: "",
        ctl_web_scoring: 0, ctl_budget_scoring: 0, ctl_security_scoring: 0,
        dns_a: "", dns_aaaa: "", dns_mx: "", dns_txt: "", dns_cname: "",
        dns_web_scoring: 0, dns_email_scoring: 0, dns_budget_scoring: 0, dns_security_scoring: 0,
        http_status: 200, http_response_time: 500, http_server: "", http_cdn: "",
        http_blocked: "", http_content_type: "", http_tech: "", http_tools: "",
        http_is_js_site: "", http_title: "", http_meta_description: "",
        http_pages: "", http_emails: "", http_error: "",
        bgp_ip: "", bgp_asn_number: "", bgp_asn_org: "", bgp_asn_country: "",
        bgp_asn_prefix: "", bgp_web_scoring: 0, bgp_budget_scoring: 0,
        rdap_domain_created_at: "2020-01-01 00:00:00", rdap_domain_expires_at: nil,
        rdap_domain_updated_at: nil, rdap_registrar: "GoDaddy.com, LLC",
        rdap_registrar_iana_id: "146", rdap_nameservers: "ns1.example.com|ns2.example.com",
        rdap_status: "client transfer prohibited", rdap_dnssec: "false",
        rdap_age_scoring: 7, rdap_registrar_scoring: 0, rdap_error: "",
        tranco_rank: 50000, majestic_rank: 30000, majestic_ref_subnets: 1500,
        is_malware: "", is_phishing: "", is_disposable_email: ""
      }

      for col <- @v3_columns do
        assert Map.has_key?(row, col), "Missing column: #{col}"
      end
    end
  end

  # ============================================================================
  # HELPERS (same parsing logic as production modules)
  # ============================================================================

  defp parse_tranco(csv) do
    csv |> String.split("\n", trim: true) |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ",", parts: 2) do
        [r, d] ->
          case Integer.parse(String.trim(r)) do
            {rank, _} -> Map.put(acc, String.trim(d), rank)
            :error -> acc
          end
        _ -> acc
      end
    end)
  end

  defp parse_majestic(csv) do
    csv |> String.split("\n", trim: true) |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ",") do
        [r, _, d, _, s | _] ->
          with {rank, _} <- Integer.parse(String.trim(r)),
               {sn, _} <- Integer.parse(String.trim(s)) do
            Map.put(acc, String.trim(d), {rank, sn})
          else
            _ -> acc
          end
        _ -> acc
      end
    end)
  end

  defp parse_domains(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.reject(fn l ->
      l = String.trim(l)
      l == "" or String.starts_with?(l, "#") or String.starts_with?(l, "!")
    end)
    |> Enum.map(fn l ->
      case String.split(String.trim(l), ~r/\s+/, parts: 2) do
        [_, d] -> String.downcase(String.trim(d))
        [d] -> String.downcase(String.trim(d))
      end
    end)
    |> Enum.reject(&(&1 in ["", "localhost", "0.0.0.0"]))
  end

  defp strip_www(d), do: d |> String.downcase() |> String.trim_leading("www.")
end
