defmodule LS.Schema.HasEmailColumnTest do
  @moduledoc """
  2026-10-28: `has_email` is a one-byte MATERIALIZED flag on the product
  table so the ranking and the has_email filter stop decompressing the 243
  MB http_emails array on 27M rows (0.9 s of a 1.5 s ranking). Declared
  once in LS.Schema.Columns like is_shopify; the compactor never writes it.
  """
  use ExUnit.Case, async: true

  test "the product table DDL declares has_email as MATERIALIZED notEmpty(http_emails)" do
    ddl = LS.Schema.Columns.ddl()
    assert ddl =~ "`has_email` UInt8 MATERIALIZED notEmpty(http_emails)"
  end

  test "the compactor's write list never names a materialized column" do
    for name <- ~w(has_email is_shopify is_saas) do
      refute name in LS.Schema.Columns.names(), "#{name} is computed by the table, an INSERT naming it fails"
    end
  end

  test "the schema file and the migration carry the same expression" do
    assert File.read!("clickhouse/schema.sql") =~ "`has_email` UInt8 MATERIALIZED notEmpty(http_emails)"
    assert File.read!("clickhouse/migrations/030_businesses_has_email.sql") =~ "MATERIALIZE COLUMN `has_email`"
  end
end
