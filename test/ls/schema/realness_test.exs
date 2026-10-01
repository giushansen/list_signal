defmodule LS.Schema.RealnessTest do
  @moduledoc """
  `estimated_realness` (2026-10-01): a score from facts already in the
  row, with the facts named in `_evidence`. These pin the contract: weights
  bounded, junk zeroes it, the same expression compiles over fold
  expressions and over bare column names, and the spec carries both
  columns to the API and the export.
  """
  use ExUnit.Case, async: true

  alias LS.Schema.{Columns, Realness}

  test "weights are positive and the score is capped at 1" do
    for {_, w} <- Realness.facts(), do: assert(w > 0 and w <= 0.2)
    assert Realness.facts() |> Enum.map(&elem(&1, 1)) |> Enum.sum() >= 1.0
    assert Realness.score_sql(& &1) =~ "least(1.0,"
  end

  test "a junk verdict zeroes the score and empties the evidence" do
    assert Realness.score_sql(& &1) =~ "if(estimated_junk != '', 0,"
    assert Realness.evidence_sql(& &1) =~ "if(estimated_junk != '', '',"
  end

  test "every input is a product column and every evidence key appears in the evidence SQL" do
    names = Columns.names()
    for c <- Realness.inputs(), do: assert(c in names, "#{c} is not a product column")
    sql = Realness.evidence_sql(& &1)
    for {k, _} <- Realness.facts(), do: assert(sql =~ "'#{k}'")
  end

  test "the fold and the v1 transform resolve inputs through the other columns' expressions, not aliases" do
    fold = Columns.fold_expr(Columns.get("estimated_realness"))
    assert fold =~ "h.dns_mx"
    assert fold =~ "h.http_company_id"
    refute fold =~ ~r/\bif\(notEmpty\(dns_mx\)/
    v1 = Columns.v1_expr(Columns.get("estimated_realness"))
    assert v1 =~ "b.dns_mx"
  end

  test "the spec exposes the score on both API surfaces and in the export, the evidence on the company" do
    assert "estimated_realness" in Columns.api_columns(:search)
    assert "estimated_realness" in Columns.api_columns(:company)
    assert "estimated_realness_evidence" in Columns.api_columns(:company)
    assert "estimated_realness" in Columns.export_columns()
    assert Columns.get("estimated_realness").type == "Float32"
  end

  test "the capture columns exist for the conditional-GET and template work and stay out of the public shape" do
    for c <- ~w(http_etag http_last_modified http_body_simhash) do
      assert Columns.get(c).internal, "#{c} is internal"
      assert c in Enum.map(LS.Cluster.Inserter.columns(), &to_string/1), "#{c} is written by the inserter"
      assert c in LS.Clickhouse.Compact.history_cols(), "#{c} is folded"
    end
  end
end
