defmodule LS.Email.VerifierQuoteTest do
  @moduledoc """
  2026-10-28: every named and free-mail check since the 10-27 release had
  been dropped. The evidence array was escaped twice on its way to
  ClickHouse (once by the verifier, once by the writer's TabSeparated
  pass), so an apostrophe in "a person's mailbox" reached the server as a
  backslash, a closing quote and a stray letter, and the whole batch was
  refused: 8,392 failed inserts in a day, found in the journal. The
  verifier now owns the escaping and hands the writer the wire form.
  """
  use ExUnit.Case, async: false

  alias LS.Clickhouse
  alias LS.Cluster.EnrichmentWriter
  alias LS.Email.Verifier

  defp ch_up?, do: match?({:ok, _}, Clickhouse.query_raw("SELECT 1"))

  test "the array literal escapes once and is tagged so the writer does not escape it again" do
    assert {:raw, lit} = Verifier.array_literal(["a person's mailbox", "back\\slash", "tab\there"])
    assert lit == "['a person\\'s mailbox','back\\\\slash','tab here']"
    assert EnrichmentWriter.tsv_value_public(%{evidence: {:raw, lit}}, "evidence") == lit
    # A plain string still gets the TabSeparated pass: that is what doubled the backslash.
    assert EnrichmentWriter.tsv_value_public(%{evidence: "x\\'y"}, "evidence") == "x\\\\'y"
    assert Verifier.array_literal(nil) == {:raw, "[]"}
  end

  test "a named address with an apostrophe in its evidence is written and read back intact" do
    if ch_up?() do
      d = "quote-test-#{System.unique_integer([:positive])}.example"
      [check] = Verifier.score_rows([%{domain: d, email: "jane@#{d}", source_page: "contact", seen_at: "2026-10-28 07:00:00"}])
      assert check.kind == "named"
      assert "a person's mailbox on #{d}" in check.evidence

      Process.sleep(300)
      {:ok, [[kind, ev]]} = Clickhouse.query_raw("SELECT kind, evidence FROM email_checks WHERE domain = '#{d}'")
      assert kind == "named"
      assert "a person's mailbox on #{d}" in ev
    end
  end

  test "the backfill can be limited to businesses checked since a time, for the day that was lost" do
    sql = LS.Email.Score.backfill_sql(1, 32, since: ~N[2026-10-27 06:50:00])
    assert sql =~ "AND b.http_last_checked_at >= '2026-10-27 06:50:00'"
    refute LS.Email.Score.backfill_sql(1, 32) =~ "http_last_checked_at >="
    refute LS.Email.Score.backfill_sql(1, 32, since: "garbage") =~ "http_last_checked_at >="
  end
end
