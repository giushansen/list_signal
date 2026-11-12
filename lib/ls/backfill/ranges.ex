defmodule LS.Backfill.Ranges do
  @moduledoc """
  The domain space cut into sorted ranges, and a keyset cursor over them,
  for the backfills that walk `enrich_log` (2026-11-12).

  `enrich_log` is sorted by `(domain, enriched_at)`, so a predicate on a
  domain RANGE reads only that range's granules, while a hash shard
  (`cityHash64(domain) % n`) reads all 87 GB every time. Measured on prod
  2026-11-12: the membership query over `be` to `bf` (305,614 compiled
  businesses, about 1% of the table) ran in 2.0 s.

  Ranges split on the first two characters in byte order, so together they
  cover every string exactly once: `{"", first}` before the first
  boundary, then each boundary to the next, then the last boundary with no
  upper end. A cursor is `{range_index, last_domain_read}`; a page reads
  past `last_domain_read` inside its range, so a range bigger than one
  page is read in pages and none is skipped.
  """

  # Byte order: '-' (45) < '.' (46) < digits < letters.
  @alphabet ~w(- . 0 1 2 3 4 5 6 7 8 9 a b c d e f g h i j k l m n o p q r s t u v w x y z)
  @boundaries for a <- @alphabet, b <- @alphabet, do: a <> b
  @ranges Enum.zip(["" | @boundaries], @boundaries ++ [nil])

  @doc "Every range as `{lo, hi}` (`hi` nil for the last), sorted and contiguous."
  @spec all() :: [{String.t(), String.t() | nil}]
  def all, do: @ranges

  @doc "How many ranges there are."
  @spec count() :: pos_integer()
  def count, do: length(@ranges)

  @doc "The range at `index`, or nil past the end."
  @spec at(non_neg_integer()) :: {String.t(), String.t() | nil} | nil
  def at(index) when is_integer(index) and index >= 0, do: Enum.at(@ranges, index)
  def at(_), do: nil

  @doc """
  Pure: the SQL condition for one page of a range: inside `{lo, hi}` and
  past `after` (nil or "" at the start of the range).
  """
  @spec where_sql({String.t(), String.t() | nil}, String.t() | nil) :: String.t()
  def where_sql({lo, hi}, after_domain) do
    [
      "domain >= '#{lit!(lo)}'",
      if(is_binary(hi), do: "domain < '#{lit!(hi)}'"),
      if(is_binary(after_domain) and after_domain != "", do: "domain > '#{lit!(after_domain)}'")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" AND ")
  end

  @doc """
  Pure: where the cursor goes after a page that returned `domains` (sorted)
  out of a `page` limit: the same range past the last domain when the page
  was full, the next range otherwise. `:done` past the last range.
  """
  @spec advance({non_neg_integer(), String.t() | nil}, [String.t()], pos_integer()) ::
          {non_neg_integer(), String.t() | nil} | :done
  def advance({index, _after}, domains, page) when length(domains) >= page, do: {index, List.last(domains)}
  def advance({index, _after}, _domains, _page), do: if(index + 1 < count(), do: {index + 1, nil}, else: :done)

  @doc """
  Pure: the domains of a result that are safe inside a quoted SQL literal.
  CH returns what workers wrote, and workers write what certificates said:
  hostile until filtered.
  """
  @spec safe_domains(term()) :: [String.t()]
  def safe_domains(rows) when is_list(rows) do
    for row <- rows,
        d = (case row do
               [d | _] -> d
               d -> d
             end),
        is_binary(d),
        d != "",
        byte_size(d) <= 253,
        not String.contains?(d, ["'", "\\", "\n", "\r", "\t", <<0>>]),
        do: d
  end

  def safe_domains(_), do: []

  @doc "Read a saved cursor, or the start."
  @spec load(Path.t()) :: {non_neg_integer(), String.t() | nil}
  def load(path) do
    with {:ok, bin} <- File.read(path),
         {index, after_domain} when is_integer(index) and index >= 0 and (is_nil(after_domain) or is_binary(after_domain)) <-
           :erlang.binary_to_term(bin, [:safe]) do
      {index, after_domain}
    else
      _ -> {0, nil}
    end
  rescue
    _ -> {0, nil}
  end

  @doc "Save a cursor so a restart resumes where the walk was."
  @spec save(Path.t(), {non_neg_integer(), String.t() | nil}) :: :ok | {:error, term()}
  def save(path, {index, after_domain} = cursor) when is_integer(index) and (is_nil(after_domain) or is_binary(after_domain)),
    do: File.write(path, :erlang.term_to_binary(cursor))

  defp lit!(s) when is_binary(s) do
    if String.contains?(s, ["'", "\\"]), do: raise(ArgumentError, "unsafe literal"), else: s
  end
end
