defmodule LS.DNS.ResolverTest do
  use ExUnit.Case, async: false

  @moduletag :external

  # ============================================================================
  # BASIC RESOLUTION
  # ============================================================================

  test "resolves google.com A records" do
    assert {:ok, data} = LS.DNS.Resolver.lookup("google.com")
    assert length(data[:a]) > 0
    # A records should be IP strings
    for ip <- data[:a] do
      assert Regex.match?(~r/^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/, ip)
    end
  end

  test "resolves MX records" do
    assert {:ok, data} = LS.DNS.Resolver.lookup("google.com")
    assert length(data[:mx]) > 0
    # MX records should be "priority:host" format
    for mx <- data[:mx] do
      assert String.contains?(mx, ":"), "MX should be priority:host format, got: #{mx}"
    end
  end

  test "resolves TXT records" do
    assert {:ok, data} = LS.DNS.Resolver.lookup("google.com")
    assert length(data[:txt]) > 0
    assert Enum.any?(data[:txt], &String.contains?(&1, "spf"))
  end

  test "returns all record types" do
    assert {:ok, data} = LS.DNS.Resolver.lookup("google.com")
    assert Map.has_key?(data, :a)
    assert Map.has_key?(data, :aaaa)
    assert Map.has_key?(data, :mx)
    assert Map.has_key?(data, :txt)
    assert Map.has_key?(data, :cname)
  end

  # ============================================================================
  # ERROR HANDLING
  # ============================================================================

  test "returns empty records for nonexistent domain" do
    assert {:ok, data} = LS.DNS.Resolver.lookup("this-will-never-exist-xyzzy-99999.com")
    assert data[:a] == []
    assert data[:mx] == []
    assert data[:txt] == []
  end

  test "returns empty lists for domain with no records of a type" do
    # Most domains don't have AAAA or CNAME at root
    {:ok, data} = LS.DNS.Resolver.lookup("example.com")
    assert is_list(data[:aaaa])
    assert is_list(data[:cname])
  end

  # ============================================================================
  # STATS
  # ============================================================================

  test "stats returns expected fields" do
    stats = LS.DNS.Resolver.stats()
    assert Map.has_key?(stats, :total_queries)
    assert Map.has_key?(stats, :successful_queries)
    assert Map.has_key?(stats, :failed_queries)
    assert Map.has_key?(stats, :success_rate)
    assert is_number(stats.success_rate)
  end
end
