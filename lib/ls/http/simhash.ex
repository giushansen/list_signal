defmodule LS.HTTP.Simhash do
  @moduledoc """
  A 64-bit simhash of a page's visible text (Charikar; Manku, Jain and
  Sarma, "Detecting Near-Duplicates for Web Crawling", Google 2007).

  Two pages built from one template hash to values a few bits apart, so
  one parking or hosting template becomes a cluster of thousands of
  domains at Hamming distance 3 or less. That is the structural junk
  detector the string rules cannot be: golden sets measured 24% (v1) and
  35% (v2) junk while the flag covered under 1%.

  Stored at fetch time as `http_body_simhash` (8 bytes per row), folded as
  the newest observed value. Clustering is a ClickHouse query over
  `businesses`; the hash gates nothing until it has been scored against
  the golden set.

  Features are word 3-shingles of the lowercased body text, each hashed to
  64 bits with the first 8 bytes of MD5 (stable across BEAM versions,
  unlike `:erlang.phash2/1`). Fewer than three words gives 0: nothing to
  compare.
  """

  import Bitwise

  @bits 64

  @doc "The simhash of a list of text blocks, 0 when there is too little text."
  @spec of([String.t()] | String.t()) :: non_neg_integer()
  def of(texts) when is_list(texts), do: texts |> Enum.filter(&is_binary/1) |> Enum.join(" ") |> of()

  def of(text) when is_binary(text) do
    words =
      text
      |> LS.HTTP.PageBlocks.scrub()
      |> String.downcase()
      |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)

    case shingles(words) do
      [] ->
        0

      feats ->
        votes = :array.new(@bits, default: 0)

        votes =
          Enum.reduce(feats, votes, fn f, acc ->
            <<h::unsigned-64, _::binary>> = :crypto.hash(:md5, f)

            Enum.reduce(0..(@bits - 1), acc, fn i, a ->
              bit = h >>> i &&& 1
              :array.set(i, :array.get(i, a) + if(bit == 1, do: 1, else: -1), a)
            end)
          end)

        Enum.reduce(0..(@bits - 1), 0, fn i, acc ->
          if :array.get(i, votes) > 0, do: acc ||| 1 <<< i, else: acc
        end)
    end
  end

  def of(_), do: 0

  @doc "Bits that differ between two hashes."
  @spec distance(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def distance(a, b) when is_integer(a) and is_integer(b), do: popcount(bxor(a, b))

  defp shingles(words) when length(words) < 3, do: []
  defp shingles(words), do: words |> Enum.chunk_every(3, 1, :discard) |> Enum.map(&Enum.join(&1, " "))

  defp popcount(0), do: 0
  defp popcount(n), do: (n &&& 1) + popcount(n >>> 1)

end
