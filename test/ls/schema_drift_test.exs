defmodule LS.SchemaDriftTest do
  @moduledoc """
  The production schema in `clickhouse/schema.sql` is the reference the
  local harness cannot be: on 2026-10-01 the v2 master booted on prod and
  its enrichment refill failed every 5 minutes with Code 47 (`dns_ptr`
  unknown in `domains`) while the laptop harness, which had the column,
  kept every test green. The enrichment lanes got no new work for an hour.

  These checks read the dumped prod schema and assert that every raw column
  the code reads from a log table is one that table actually has.
  """
  use ExUnit.Case, async: true

  @schema Path.expand("../../clickhouse/schema.sql", __DIR__)

  defp columns_of(table) do
    sql = File.read!(@schema)
    [_, block] = String.split(sql, "-- ═══ #{table} ═══", parts: 2)
    [block | _] = String.split(block, "\n-- ═══", parts: 2)
    Regex.scan(~r/^\s+`([a-z_0-9]+)`\s/m, block) |> Enum.map(fn [_, c] -> c end) |> MapSet.new()
  end

  test "the enrichment refill reads its raw DNS strings from columns enrich_log has" do
    cols = columns_of(LS.Schema.Tables.enrich_log())
    for c <- LS.Clickhouse.refill_log_columns(), do: assert(c in cols, "#{c} is not a column of enrich_log")
  end

  test "the explorer detail panel reads raw columns enrich_log has" do
    cols = columns_of(LS.Schema.Tables.enrich_log())
    for c <- LS.Explorer.log_detail_columns(), do: assert(c in cols, "#{c} is not a column of enrich_log")
  end

  test "every column the Inserter writes exists in prod's enrich_log" do
    cols = columns_of(LS.Schema.Tables.enrich_log())
    for c <- LS.Cluster.Inserter.columns(), c = to_string(c), do: assert(c in cols, "Inserter writes #{c}, enrich_log lacks it")
  end

  test "domains never received dns_ptr or dns_ms_enterprise, which is why the readers above use the log" do
    cols = columns_of(LS.Schema.Tables.domains())
    refute "dns_ptr" in cols, "domains grew dns_ptr: the readers may move back, update this test"
    refute "dns_ms_enterprise" in cols
  end
end
