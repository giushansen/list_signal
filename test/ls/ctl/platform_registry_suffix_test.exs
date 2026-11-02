defmodule LS.CTL.PlatformRegistrySuffixTest do
  @moduledoc """
  2026-11-02: `platforms` held 985 public suffixes (com.pl and com.vn since
  07-30, org.ph, co.it, on.ca...) learned from their certificate rate once
  the parser had collapsed every name under them. `known?/1` walks suffixes,
  so everything under those countries was dropped at the poller.
  """
  use ExUnit.Case, async: false

  alias LS.CTL.PlatformRegistry

  setup do
    for t <- [:platform_registry, :platform_pending] do
      if :ets.whereis(t) == :undefined, do: :ets.new(t, [:set, :public, :named_table])
    end

    :ok
  end

  test "a public suffix is never learned as a platform, however often it is observed" do
    stats = %{reason: "cert_rate", cert_count: 500, max_subdomain_count: 2, estimated_hosted_domains: 500}
    for _ <- 1..5, do: assert(PlatformRegistry.observe("com.pl", stats) == :ok)
    refute PlatformRegistry.known?("com.pl")
    refute PlatformRegistry.known?("example.com.pl")
    assert :ets.lookup(:platform_pending, "com.pl") == []
  end

  test "a real platform apex is still learned after the grace window" do
    stats = %{reason: "cert_rate", cert_count: 500, max_subdomain_count: 2, estimated_hosted_domains: 500}
    PlatformRegistry.observe("suffix-test-platform.com", stats)
    refute PlatformRegistry.known?("suffix-test-platform.com")
    PlatformRegistry.observe("suffix-test-platform.com", stats)
    assert PlatformRegistry.known?("shop.suffix-test-platform.com")
    :ets.delete(:platform_registry, "suffix-test-platform.com")
    :ets.delete(:platform_pending, "suffix-test-platform.com")
  end
end
