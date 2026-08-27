defmodule LS.Reputation.BloomTest do
  use ExUnit.Case, async: true

  alias LS.Reputation.Bloom

  @moduledoc """
  The bloom filter that replaced 402 MB of Tranco ETS on every worker.

  The property everything rests on: NO FALSE NEGATIVES. A false positive means
  we crawl a domain we would have skipped, which is harmless and is the
  direction the crawl filter already errs in. A false negative would mean
  silently losing a ranked domain from discovery, which is exactly the kind of
  invisible regression that must never be traded for memory.
  """

  describe "no false negatives, ever" do
    test "every key that was added is reported present" do
      f = Bloom.new(10_000, 0.01)
      keys = for i <- 1..10_000, do: "site#{i}.example.com"
      Enum.each(keys, &Bloom.put(f, &1))

      missing = Enum.reject(keys, &Bloom.member?(f, &1))
      assert missing == [], "#{length(missing)} ranked domains would be LOST from discovery"
    end

    test "holds even when loaded well past its sizing" do
      # An oversubscribed filter degrades into more false POSITIVES, never
      # false negatives. Tranco grows between refreshes, so this matters.
      f = Bloom.new(1_000, 0.01)
      keys = for i <- 1..10_000, do: "over#{i}.example"
      Enum.each(keys, &Bloom.put(f, &1))

      assert Enum.all?(keys, &Bloom.member?(f, &1))
    end

    test "real-shaped domains, including unicode and long labels" do
      f = Bloom.new(1_000, 0.01)

      keys = [
        "google.com",
        "sub.domain.co.uk",
        "xn--80ak6aa92e.com",
        String.duplicate("a", 200) <> ".example",
        "münchen.de",
        "1.2.3.4.example"
      ]

      Enum.each(keys, &Bloom.put(f, &1))
      assert Enum.all?(keys, &Bloom.member?(f, &1))
    end
  end

  describe "false positive rate stays near the target" do
    test "roughly 1% at the configured size" do
      n = 50_000
      f = Bloom.new(n, 0.01)
      Enum.each(1..n, fn i -> Bloom.put(f, "in#{i}.example") end)

      probes = for i <- 1..20_000, do: "out#{i}.notpresent"
      fp = Enum.count(probes, &Bloom.member?(f, &1))
      rate = fp / length(probes)

      assert rate < 0.03, "false positive rate #{Float.round(rate * 100, 2)}% is far above target"
    end

    test "an empty filter says no to everything" do
      f = Bloom.new(1_000, 0.01)
      refute Bloom.member?(f, "anything.example")
      assert Bloom.count(f) == 0
    end
  end

  describe "sizing" do
    test "4.31M Tranco entries at 1% fit in about 5 MB, versus 402 MB of ETS" do
      s = Bloom.size_for(4_310_000, 0.01)
      mb = s.bytes / 1_048_576

      assert mb > 4.0 and mb < 6.0, "expected ~4.9MB, got #{Float.round(mb, 2)}MB"
      assert s.hashes == 7
    end

    test "a tighter rate costs more memory, monotonically" do
      loose = Bloom.size_for(1_000_000, 0.05)
      tight = Bloom.size_for(1_000_000, 0.001)
      assert tight.bits > loose.bits
    end

    test "degenerate sizes do not produce a zero-bit filter" do
      s = Bloom.size_for(1, 0.5)
      assert s.bits >= 64 and s.hashes >= 1

      f = Bloom.new(1, 0.5)
      Bloom.put(f, "x")
      assert Bloom.member?(f, "x")
    end
  end

  describe "hostile input" do
    test "member?/2 on a non-filter is false rather than a crash" do
      refute Bloom.member?(nil, "x")
      refute Bloom.member?(%{}, "x")
      assert Bloom.count(nil) == 0
      assert Bloom.memory_mb(nil) == 0.0
    end
  end
end
