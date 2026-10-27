defmodule LS.Email.VerifierTest do
  @moduledoc """
  The scorer's writer and its one-shot backfill, against a real ClickHouse
  when one is reachable (skipped otherwise, like the data contract suite).
  """
  use ExUnit.Case, async: false

  alias LS.Clickhouse
  alias LS.Email.Verifier

  @moduletag :data_contract

  defp ch_up?, do: match?({:ok, _}, Clickhouse.query_raw("SELECT 1"))

  test "the backfill SQL parses and runs on the real schema" do
    if ch_up?() do
      assert {:ok, _} = Clickhouse.query_raw(LS.Email.Score.backfill_sql(0, 1024), 120_000, background: true)
    end
  end

  test "a contact row is scored and written with its evidence" do
    if ch_up?() do
      d = "score-test-#{System.unique_integer([:positive])}.example"
      rows = [%{domain: d, email: "hello@#{d}", source_page: "contact", on_domain: 1, seen_at: "2026-10-27 10:00:00"}]
      [check] = Verifier.score_rows(rows)
      # No business row for this domain: no MX known, so undeliverable with the reason first.
      assert check.verdict == "undeliverable"
      assert hd(check.evidence) == "no MX record: mail cannot be delivered"
      assert check.kind == "role"

      Process.sleep(300)
      {:ok, rows} = Clickhouse.query_raw("SELECT email, verdict, evidence FROM email_checks WHERE domain = '#{d}'")
      assert [[_, "undeliverable", ev]] = rows
      assert is_list(ev) and length(ev) >= 3
    end
  end

  test "placeholders and third parties are never scored" do
    if ch_up?() do
      assert Verifier.score_rows([%{domain: "acme.example", email: "name@company.com", source_page: "homepage"}, %{domain: "acme.example", email: "press@gymshark.com", source_page: "homepage"}]) == []
    end
  end

  test "garbage rows are ignored and nothing raises" do
    assert Verifier.score_rows([%{}, nil, %{domain: 1, email: 2}, "x"]) == []
    assert Verifier.score_async(:nope) == :ok
    assert Verifier.score_async([]) == :ok
  end
end
