defmodule LS.BGP.ResolverCachePoisonTest do
  use ExUnit.Case, async: true

  alias LS.BGP.Resolver

  @moduledoc """
  2026-09-26: dal1 was quarantined for twelve hours and dropped 265K rows.
  Its BGP cache held 45 nil answers from one failed Team Cymru batch, kept
  for the 14-day TTL; two of them were AWS parking addresses shared by
  thousands of domains, so every such domain lost its BGP data and the
  Inserter's quality guard read the node as hollow. A nil answer is a
  failed lookup, and a failed lookup is never remembered.
  """

  test "only an answer that names an ASN is cached" do
    assert Resolver.cacheable?(%{asn: "14618", org: "AMAZON-AES", country: "US", prefix: "13.223.0.0/16"})
    refute Resolver.cacheable?(%{asn: nil, org: nil, country: nil, prefix: nil})
    refute Resolver.cacheable?(%{asn: "", org: "", country: "", prefix: ""})
    refute Resolver.cacheable?(nil)
    refute Resolver.cacheable?(%{})
  end

  test "the batch path caches only cacheable answers and never queries Cymru twice" do
    src = File.read!("lib/ls/bgp/resolver.ex")
    [batch_reply | _] = src |> String.split("def handle_call({:lookup_batch") |> Enum.at(1) |> String.split("\n  end\n")

    assert length(Regex.scan(~r/query_cymru_batched\(uncached\)/, batch_reply)) == 1,
           "the failure count was taken by running every Cymru batch a second time"

    assert batch_reply =~ "if cacheable?(result), do: put_in_cache(ip, result)"
  end
end
