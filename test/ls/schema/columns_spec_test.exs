defmodule LS.Schema.ColumnsSpecTest do
  @moduledoc """
  The product table is declared once (data model v2, 2026-10-01). These
  pin the naming rules the owner set and the invariants every generated
  artifact (DDL, fold, migration, API, docs) depends on. A column that
  breaks a rule here would reach the API, the CSV and the docs with the
  wrong name, which is the drift the spec exists to prevent.
  """
  use ExUnit.Case, async: true

  alias LS.Schema.Columns

  @prefixes ~w(ctl_ dns_ http_ http_deep_ shop_ hr_ rdap_ bgp_ news_ tranco_ majestic_ estimated_ verified_)

  test "every column name is unique" do
    names = Columns.names()
    assert names == Enum.uniq(names)
  end

  test "every column carries a pipeline prefix, except the two table-level stamps and the domain" do
    for name <- Columns.names(), name not in ~w(domain compiled_at) do
      assert Enum.any?(@prefixes, &String.starts_with?(name, &1)),
             "#{name} has no pipeline, estimated_ or verified_ prefix"
    end
  end

  test "no column is named with the forbidden bare words or the dropped _source suffix" do
    for name <- Columns.names() do
      refute name in ~w(country industry business_model is_junk as_of first_seen last_verified_at), "#{name} is a v1 bare name"
      refute String.ends_with?(name, "_source"), "#{name}: _source was retired, the prefix or _evidence says the source"
    end
  end

  test "every estimated_ value column has its confidence or evidence next to it" do
    names = MapSet.new(Columns.names())

    for name <- Columns.names(),
        String.starts_with?(name, "estimated_"),
        not String.ends_with?(name, ["_confidence", "_evidence"]),
        name not in ~w(estimated_at estimated_version estimated_junk) do
      assert MapSet.member?(names, name <> "_evidence") or MapSet.member?(names, name <> "_confidence"),
             "#{name} has neither _evidence nor _confidence"
    end
  end

  test "every column has a type, a fold expression and a one-line meaning" do
    for col <- Columns.all() do
      assert col.type != ""
      assert col.select not in [nil, ""]
      assert is_binary(col.doc) and col.doc != "", "#{col.name} has no doc"
    end
  end

  test "tracked columns exist, are scalars or arrays, and carry a known rule" do
    names = MapSet.new(Columns.names())

    for {name, rule, _type} <- Columns.tracked() do
      assert MapSet.member?(names, name)
      assert rule in [:set, :set_added, :changed, :started_stopped, :down_back] or match?({:pct, _}, rule)
    end

    assert {"http_tech", :set, _} = List.keyfind(Columns.tracked(), "http_tech", 0)
    assert {"hr_job_count", :started_stopped, _} = List.keyfind(Columns.tracked(), "hr_job_count", 0)
    assert {"http_status", :down_back, _} = List.keyfind(Columns.tracked(), "http_status", 0)
  end

  test "the API and export surfaces only name real columns and never internal ones" do
    names = MapSet.new(Columns.names())
    internal = for col <- Columns.all(), col.internal, into: MapSet.new(), do: col.name

    for surface <- [:company, :search], name <- Columns.api_columns(surface) do
      assert MapSet.member?(names, name)
      refute MapSet.member?(internal, name), "#{name} is internal and reached the API"
    end

    for name <- Columns.export_columns() do
      refute MapSet.member?(internal, name)
    end

    assert "domain" in Columns.api_columns(:search)
    assert "http_tech" in Columns.api_columns(:company)
    assert "http_emails" in Columns.export_columns()
  end

  test "the DDL creates the table keyed by domain, versioned by compiled_at, with the two flags" do
    ddl = Columns.ddl("businesses_v2")
    assert ddl =~ "CREATE TABLE IF NOT EXISTS businesses_v2"
    assert ddl =~ "ENGINE = ReplacingMergeTree(compiled_at)"
    assert ddl =~ "ORDER BY domain"
    assert ddl =~ "`is_shopify` UInt8 MATERIALIZED has(http_tech, 'Shopify')"
    assert ddl =~ "`is_saas` UInt8 MATERIALIZED estimated_business_model = 'SaaS'"
    assert ddl =~ "`http_tech` Array(LowCardinality(String))"
  end

  test "the fold and the v1 transform produce every column, aliased by its name" do
    fold = Columns.fold_select()
    v1 = Columns.v1_select()

    for name <- Columns.names() do
      assert fold =~ " AS #{name}", "fold misses #{name}"
      assert v1 =~ " AS #{name}", "v1 transform misses #{name}"
    end
  end

  test "legacy aliases cover the renamed scalars and never an array" do
    ddl = Columns.legacy_alias_ddl("businesses_v2")
    assert Enum.any?(ddl, &(&1 =~ "`business_model` LowCardinality(String) ALIAS estimated_business_model"))
    assert Enum.any?(ddl, &(&1 =~ "`as_of` DateTime ALIAS compiled_at"))
    refute Enum.any?(ddl, &(&1 =~ "ALIAS http_tech"))
    refute Enum.any?(ddl, &(&1 =~ "ALIAS dns_mx"))
    assert Map.get(Columns.legacy_map(), "inferred_country") == "estimated_country"
  end
end
