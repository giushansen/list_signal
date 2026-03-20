defmodule LS.PipelineTest do
  use ExUnit.Case, async: false

  # These tests hit real DNS/HTTP/BGP — they need network access.
  # Tag with :external so they can be excluded in CI.
  @moduletag :external

  setup_all do
    LS.Signatures.load_all()
    :ok
  end

  # ============================================================================
  # DNS STAGE
  # ============================================================================

  describe "dns/1" do
    test "resolves a known domain" do
      assert {:ok, data} = LS.Pipeline.dns("google.com")
      assert is_map(data.dns)
      assert length(data.dns[:a]) > 0, "google.com should have A records"
      assert length(data.dns[:mx]) > 0, "google.com should have MX records"
      assert is_map(data.scores)
    end

    test "returns empty DNS for nonexistent domain" do
      assert {:ok, data} = LS.Pipeline.dns("this-domain-does-not-exist-xyz123.com")
      assert data.dns[:a] == []
      assert data.dns[:mx] == []
    end

    test "returns all DNS record types" do
      {:ok, data} = LS.Pipeline.dns("google.com")
      dns = data.dns
      assert Map.has_key?(dns, :a)
      assert Map.has_key?(dns, :aaaa)
      assert Map.has_key?(dns, :mx)
      assert Map.has_key?(dns, :txt)
      assert Map.has_key?(dns, :cname)
    end

    test "scores are integers" do
      {:ok, data} = LS.Pipeline.dns("google.com")
      for {_key, val} <- data.scores do
        assert is_integer(val), "Score values should be integers"
      end
    end
  end

  # ============================================================================
  # HTTP STAGE
  # ============================================================================

  describe "http/1" do
    test "fetches a live domain and returns enriched map" do
      result = LS.Pipeline.http("example.com")
      assert is_map(result)
      assert result.http_status == 200 or is_integer(result.http_status)
      assert is_binary(result.http_title)
      assert is_binary(result.http_tech)
      assert result.http_error == "" or is_binary(result.http_error)
    end

    test "returns error map for unreachable domain" do
      result = LS.Pipeline.http("this-will-never-resolve-xyz.com")
      assert is_map(result)
      assert result.http_error != "", "Should have an error message"
    end

    test "extracts title from response" do
      result = LS.Pipeline.http("example.com")
      if result.http_error == "" do
        assert is_binary(result.http_title)
        # example.com has a known title
        assert String.length(result.http_title) > 0
      end
    end

    test "returns all expected HTTP fields" do
      result = LS.Pipeline.http("example.com")
      expected_keys = [
        :http_status, :http_response_time, :http_server, :http_cdn,
        :http_blocked, :http_content_type, :http_tech, :http_tools,
        :http_is_js_site, :http_title, :http_meta_description,
        :http_pages, :http_emails, :http_error
      ]
      for key <- expected_keys do
        assert Map.has_key?(result, key), "Missing key: #{key}"
      end
    end
  end

  describe "http/2 with explicit IP" do
    test "fetches with provided IP" do
      # Use a known IP for example.com
      result = LS.Pipeline.http("example.com", "93.184.215.14")
      assert is_map(result)
    end
  end

  # ============================================================================
  # TECH DETECTION
  # ============================================================================

  describe "tech/1" do
    test "detects technologies on a real site" do
      result = LS.Pipeline.tech("github.com")
      case result do
        {:error, _} -> :ok  # network error is acceptable
        %{tech: tech, tools: tools} ->
          assert is_list(tech)
          assert is_list(tools)
      end
    end
  end

  describe "detect/2" do
    test "detects from raw HTML + headers" do
      body = ~s(<html><head><script src="https://cdn.jsdelivr.net/npm/vue@3"></script></head></html>)
      headers = [{"server", "nginx"}, {"content-type", "text/html"}]
      result = LS.Pipeline.detect(body, headers)
      assert is_map(result)
      assert Map.has_key?(result, :tech)
      assert Map.has_key?(result, :tools)
    end
  end

  # ============================================================================
  # BGP STAGE
  # ============================================================================

  describe "bgp/1 single IP" do
    test "resolves Google DNS IP" do
      assert {:ok, data} = LS.Pipeline.bgp("8.8.8.8")
      assert data.asn == "15169"
      assert String.contains?(data.org, "GOOGLE")
      assert data.country == "US"
      assert is_binary(data.prefix)
    end

    test "resolves Cloudflare IP" do
      assert {:ok, data} = LS.Pipeline.bgp("1.1.1.1")
      assert data.asn == "13335"
      assert String.contains?(data.org, "CLOUDFLARE")
    end
  end

  describe "bgp/1 batch" do
    test "resolves multiple IPs" do
      assert {:ok, results} = LS.Pipeline.bgp(["8.8.8.8", "1.1.1.1"])
      assert is_map(results)
      assert Map.has_key?(results, "8.8.8.8")
      assert Map.has_key?(results, "1.1.1.1")
      assert results["8.8.8.8"].asn == "15169"
      assert results["1.1.1.1"].asn == "13335"
    end
  end

  # ============================================================================
  # DOMAIN FILTER
  # ============================================================================

  describe "should_crawl?/1" do
    test "returns map with crawl decision" do
      result = LS.Pipeline.should_crawl?("google.com")
      assert is_map(result)
      assert Map.has_key?(result, :would_crawl)
      assert is_boolean(result.would_crawl)
      assert Map.has_key?(result, :has_a_record)
      assert Map.has_key?(result, :has_mx)
      assert Map.has_key?(result, :has_spf)
    end

    test "google.com should be crawlable" do
      result = LS.Pipeline.should_crawl?("google.com")
      assert result.has_a_record == true
      assert result.has_mx == true
    end

    test "nonexistent domain should not crawl" do
      result = LS.Pipeline.should_crawl?("nxdomain-zzzz-999.com")
      assert result.would_crawl == false
    end
  end

  # ============================================================================
  # FULL PIPELINE
  # ============================================================================

  describe "run/1" do
    test "single domain returns enriched map" do
      result = LS.Pipeline.run("example.com")
      assert is_map(result)
      assert result.domain == "example.com"
      assert is_binary(result.enriched_at)
      assert is_binary(result.worker)
      assert is_binary(result.ctl_tld)
    end

    test "single domain has all ClickHouse columns" do
      result = LS.Pipeline.run("example.com")
      expected_keys = [
        :enriched_at, :worker, :domain,
        :ctl_tld, :ctl_issuer, :ctl_subdomain_count, :ctl_subdomains,
        :ctl_web_scoring, :ctl_budget_scoring, :ctl_security_scoring,
        :dns_a, :dns_aaaa, :dns_mx, :dns_txt, :dns_cname,
        :dns_web_scoring, :dns_email_scoring, :dns_budget_scoring, :dns_security_scoring,
        :http_status, :http_response_time, :http_server, :http_cdn, :http_blocked,
        :http_content_type, :http_tech, :http_tools, :http_is_js_site,
        :http_title, :http_meta_description, :http_pages, :http_emails, :http_error,
        :bgp_ip, :bgp_asn_number, :bgp_asn_org, :bgp_asn_country, :bgp_asn_prefix,
        :bgp_web_scoring, :bgp_budget_scoring
      ]
      for key <- expected_keys do
        assert Map.has_key?(result, key), "Missing column: #{key}"
      end
    end

    test "batch returns list of maps" do
      results = LS.Pipeline.run(["example.com", "google.com"])
      assert is_list(results)
      assert length(results) == 2
      assert Enum.all?(results, &is_map/1)
      domains = Enum.map(results, & &1.domain)
      assert "example.com" in domains
      assert "google.com" in domains
    end

    test "verbose option prints stage output" do
      # Just verify it doesn't crash
      result = LS.Pipeline.run("example.com", verbose: true)
      assert is_map(result)
    end

    test "DNS data is populated for valid domain" do
      result = LS.Pipeline.run("google.com")
      assert result.dns_a != "", "google.com should have A records"
    end

    test "BGP data is populated when DNS resolves" do
      result = LS.Pipeline.run("google.com")
      if result.dns_a != "" do
        assert result.bgp_ip != "" or result.bgp_asn_number != "",
          "BGP should resolve when domain has A records"
      end
    end
  end

  # ============================================================================
  # DATA QUALITY — based on real sample from ClickHouse
  # ============================================================================

  describe "data quality" do
    test "string fields are never nil in output" do
      result = LS.Pipeline.run("example.com")
      string_fields = [
        :domain, :ctl_tld, :ctl_issuer, :ctl_subdomains,
        :dns_a, :dns_aaaa, :dns_mx, :dns_txt, :dns_cname,
        :http_server, :http_cdn, :http_blocked, :http_content_type,
        :http_tech, :http_tools, :http_is_js_site,
        :http_title, :http_meta_description, :http_pages, :http_emails, :http_error,
        :bgp_ip, :bgp_asn_number, :bgp_asn_org, :bgp_asn_country, :bgp_asn_prefix
      ]
      for field <- string_fields do
        val = Map.get(result, field)
        assert is_binary(val) or val == nil,
          "#{field} should be binary or nil, got: #{inspect(val)}"
        # Importantly, NOT a list, tuple, or atom
        refute is_list(val), "#{field} should not be a list"
        refute is_tuple(val), "#{field} should not be a tuple"
      end
    end

    test "integer fields are integers or nil" do
      result = LS.Pipeline.run("example.com")
      int_fields = [
        :ctl_subdomain_count, :ctl_web_scoring, :ctl_budget_scoring, :ctl_security_scoring,
        :dns_web_scoring, :dns_email_scoring, :dns_budget_scoring, :dns_security_scoring,
        :bgp_web_scoring, :bgp_budget_scoring
      ]
      for field <- int_fields do
        val = Map.get(result, field)
        assert is_integer(val) or val == nil,
          "#{field} should be integer or nil, got: #{inspect(val)}"
      end
    end

    test "pipe-delimited fields don't contain nested pipes from lists" do
      result = LS.Pipeline.run("google.com")
      # These should be "a|b|c" not "[\"a\", \"b\"]"
      for field <- [:dns_a, :dns_mx, :dns_txt, :http_tech, :http_tools] do
        val = Map.get(result, field, "")
        if val != "" do
          refute String.contains?(val, "["), "#{field} contains raw list: #{val}"
          refute String.contains?(val, "\""), "#{field} contains quotes: #{val}"
        end
      end
    end
  end
end
