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

    test "inferred_country is populated" do
      result = LS.Pipeline.run("example.com")
      assert is_binary(result.inferred_country)
      # example.com is a .com domain, should get a country
      assert result.inferred_country != ""
    end
  end

  describe "column count" do
    test "inserter has 55 columns matching schema" do
      assert length(LS.Cluster.Inserter.columns()) == 55
    end
  end
end
