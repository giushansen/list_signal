defmodule LS.Reputation.Bloom do
  @moduledoc """
  A fixed-size bloom filter for "have I seen this domain?", backed by
  `:atomics` so every scheduler reads it without copying.

  ## Why this exists (2026-08-27)

  Workers held the whole Tranco list in ETS to answer one question:
  `LS.HTTP.DomainFilter` asks whether a domain is Tranco-ranked, and crawls it
  regardless of the TLD/MX/SPF heuristics when it is. That membership test
  cost **402 MB on machines with 1,968 MB of RAM**, and it was the single
  largest consumer on the 1-core nodes, which alerted on low memory nightly.

  Measured on prod, 4.31M entries:

  | | ETS | Bloom |
  |---|---|---|
  | memory | 402 MB | **4.9 MB** |
  | hit | 1.55 us | **0.72 us** |
  | miss | 3.16 us | **0.09 us** |

  Misses dominate (most certificate-transparency domains are unranked), and
  the miss is where the bloom wins by 35x.

  ## The failure mode is the safe one

  A bloom filter can report a domain as present when it is not (a false
  positive at the configured rate), but it can NEVER report a domain as absent
  when it is present. For this caller a false positive means we crawl a domain
  we would otherwise have skipped, which is the direction the filter already
  errs in. **No ranked domain is ever lost**, which is the property that makes
  it safe to trade 402 MB for 4.9 MB here.

  The rank VALUE is a different question: it is an output column, so the
  master fills it from its own copy of the list (`LS.Reputation.fill/1`).
  """

  import Bitwise

  @doc """
  Sizing for `n` expected members at false-positive rate `p`.

  Returns `%{bits: m, hashes: k, bytes: b}` using the standard
  `m = -n ln p / (ln 2)^2` and `k = (m/n) ln 2`.
  """
  @spec size_for(pos_integer(), float()) :: %{bits: pos_integer(), hashes: pos_integer(), bytes: pos_integer()}
  def size_for(n, p) when is_integer(n) and n > 0 and is_float(p) and p > 0 and p < 1 do
    m = max(round(-n * :math.log(p) / (:math.log(2) * :math.log(2))), 64)
    k = max(round(m / n * :math.log(2)), 1)
    %{bits: m, hashes: k, bytes: div(m, 8) + 1}
  end

  @doc "A new empty filter sized for `n` members at rate `p`."
  @spec new(pos_integer(), float()) :: map()
  def new(n, p \\ 0.01) do
    %{bits: m, hashes: k} = size_for(n, p)
    %{ref: :atomics.new(div(m, 64) + 1, signed: false), bits: m, hashes: k, count: :counters.new(1, [])}
  end

  @doc "Add `key`. Returns the filter (mutated in place; `:atomics` is a reference)."
  def put(%{ref: ref, bits: m, hashes: k, count: c} = f, key) do
    Enum.each(0..(k - 1), fn i ->
      h = :erlang.phash2({i, key}, m)
      word = div(h, 64) + 1
      :atomics.put(ref, word, bor(:atomics.get(ref, word), bsl(1, rem(h, 64))))
    end)

    :counters.add(c, 1, 1)
    f
  end

  @doc """
  True when `key` may be present, false when it is definitely absent.

  False positives are possible at the configured rate; false negatives are not.
  """
  @spec member?(map(), term()) :: boolean()
  def member?(%{ref: ref, bits: m, hashes: k}, key) do
    Enum.all?(0..(k - 1), fn i ->
      h = :erlang.phash2({i, key}, m)
      band(:atomics.get(ref, div(h, 64) + 1), bsl(1, rem(h, 64))) != 0
    end)
  end

  def member?(_, _), do: false

  @doc "How many keys were added."
  def count(%{count: c}), do: :counters.get(c, 1)
  def count(_), do: 0

  @doc "Approximate memory in MB."
  def memory_mb(%{bits: m}), do: Float.round(m / 8 / 1_048_576, 2)
  def memory_mb(_), do: 0.0
end
