defmodule LS.Reputation do
  @moduledoc """
  Master-side backfill of reputation columns that workers no longer carry.

  ## Why (2026-08-26)

  Every worker loaded the full reputation reference data into ETS: Tranco
  (403 MB / 4.31M rows) and Majestic (101 MB / 1M rows). On a 1,968 MB node
  that is 504 MB — a quarter of the machine — replicated 14 times, and it is
  the real reason the small workers sat near their low-memory floor and
  emailed about it nightly.

  **Tranco has to stay on the workers**: `LS.HTTP.DomainFilter` uses it as a
  crawl-decision bypass (a Tranco-ranked domain is crawled regardless of the
  TLD/MX/SPF heuristics, worth ~150K legitimate domains per 1.5 days), so
  removing it would silently narrow discovery.

  **Majestic is only a data column** — `majestic_rank` and
  `majestic_ref_subnets` — never a decision. So workers stop loading it and
  the master, which holds the same table on a 16 GB box, fills those two
  fields here on the way into ClickHouse. Reference data now lives once
  instead of fourteen times, and each small worker gets 101 MB back plus the
  daily reload spike that came with it.

  ## Never blanks good data

  If the master's own table is not loaded yet (boot, or a failed refresh),
  `fill/1` returns the rows untouched rather than writing empty ranks over
  them — `domains_current` is newest-row-wins, so a blank column would erase a
  real one.
  """

  alias LS.Reputation.{Majestic, Tranco}

  @doc """
  Fill the reputation columns workers no longer carry: `majestic_rank`,
  `majestic_ref_subnets` and `tranco_rank`.

  A row that already carries a value (a standalone node, or a replay from
  before this change) keeps it.
  """
  @spec fill([map()]) :: [map()]
  def fill(rows) when is_list(rows) do
    if loaded?(), do: Enum.map(rows, &fill_row/1), else: rows
  end

  def fill(rows), do: rows

  @doc "True when the master's reference tables actually hold data."
  def loaded? do
    table_loaded?(:majestic_ranks) or table_loaded?(:tranco_ranks)
  end

  defp table_loaded?(t) do
    case :ets.info(t, :size) do
      n when is_integer(n) and n > 0 -> true
      _ -> false
    end
  end

  defp fill_row(%{domain: domain} = row) when is_binary(domain) do
    row |> fill_majestic(domain) |> fill_tranco(domain)
  end

  defp fill_row(row), do: row

  defp fill_majestic(row, domain) do
    if is_nil(Map.get(row, :majestic_rank)) do
      case Majestic.lookup(domain) do
        %{rank: rank, ref_subnets: subnets} ->
          # Map.put, not %{row | ...}: a row may legitimately omit the key
          # entirely (recrawl items, replays), and struct-update would raise.
          row |> Map.put(:majestic_rank, rank) |> Map.put(:majestic_ref_subnets, subnets)

        _ ->
          row
      end
    else
      row
    end
  end

  # Workers run Tranco in :membership mode, so their tranco_rank is always nil
  # and the master supplies the value here from its full copy.
  defp fill_tranco(row, domain) do
    if is_nil(Map.get(row, :tranco_rank)) do
      case Tranco.lookup(domain) do
        rank when is_integer(rank) -> Map.put(row, :tranco_rank, rank)
        _ -> row
      end
    else
      row
    end
  end
end
