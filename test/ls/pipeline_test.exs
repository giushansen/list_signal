defmodule LS.PipelineTest do
  use ExUnit.Case, async: false

  describe "reputation/1" do
    test "returns all reputation signals" do
      result = LS.Pipeline.reputation("google.com")
      assert is_map(result)
      assert Map.has_key?(result, :tranco_rank)
      assert Map.has_key?(result, :majestic)
      assert Map.has_key?(result, :blocklist)
    end

    test "unknown domain has nil ranks" do
      result = LS.Pipeline.reputation("zzzz-unknown-9999.test")
      assert result.tranco_rank == nil
      assert result.majestic == nil
      assert result.blocklist == nil
    end
  end

  describe "should_crawl?/1" do
    test "returns map with crawl decision and reputation" do
      result = LS.Pipeline.should_crawl?("google.com")
      assert Map.has_key?(result, :would_crawl)
      assert Map.has_key?(result, :blocked)
      assert Map.has_key?(result, :tranco_rank)
    end
  end

  describe "run/1 v3 columns" do
    test "single domain has all ClickHouse columns" do
      result = LS.Pipeline.run("example.com")
      v3_keys = [
        :rdap_domain_created_at, :rdap_domain_expires_at, :rdap_registrar,
        :tranco_rank, :majestic_rank, :majestic_ref_subnets,
        :is_malware, :is_phishing, :is_disposable_email,
        :inferred_country
      ]
      for key <- v3_keys, do: assert(Map.has_key?(result, key), "Missing: #{key}")
    end

    test "blocklist flags are strings" do
      result = LS.Pipeline.run("example.com")
      assert is_binary(result.is_malware)
      assert is_binary(result.is_phishing)
      assert is_binary(result.is_disposable_email)
    end

    test "inferred_country is either empty or a real 2-letter code, never junk" do
      # Changed 2026-08-27. This used to assert a country was ALWAYS produced,
      # which is the opposite of the rule this module is built on: unknown
      # beats fabricated. example.com is a .com on a Cloudflare address with
      # no ASN org and no ccTLD, so "" is the correct answer, and the old
      # assertion only passed while BGP was willing to invent one.
      #
      # The invariant is what matters and it survives every rules change:
      # whatever comes out is either empty or a well-formed code. A malformed
      # value here reaches every country filter and every list we sell.
      result = LS.Pipeline.run("example.com")
      cc = result.inferred_country
      assert is_binary(cc)

      assert cc == "" or (byte_size(cc) == 2 and cc == String.upcase(cc)),
             "inferred_country must be \"\" or a 2-letter uppercase code, got #{inspect(cc)}"
    end
  end

  describe "column count" do
    test "inserter has 65 columns matching schema (59 + dns_dmarc, dns_bimi, dns_dkim, dns_ptr, dns_ms_enterprise, http_observed on 2026-09-06)" do
      # 55 + is_junk (004_is_junk.sql)
      #    + http_country_evidence, http_country_evidence_src,
      #      rdap_registrant_country (018_country_evidence.sql)
      #
      # This count is the seam between the Elixir insert and the ClickHouse
      # table. A mismatch shifts every value one column to the left and
      # writes a whole batch of garbage, so the number is asserted rather
      # than trusted.
      assert length(LS.Cluster.Inserter.columns()) == 65
    end
  end
end
