defmodule LS.ClickhousePoolTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Which ClickHouse connection pool each caller uses.

  ## The 2026-08-27 outage (~15 minutes of downtime)

  The compactor's `INSERT INTO businesses ... SELECT` takes 105-110 SECONDS
  per pass, and it drew from `LS.Finch.CH` — the same 150-connection pool the
  website renders from. Enough slow background passes plus normal traffic
  exhausted it ("Finch was unable to provide a connection within the timeout
  due to excess queuing"). Erlang's `global` then disconnected all 14 workers
  to prevent overlapping partitions, the BEAM stalled for ~2.5 minutes with no
  log output at all, and the site was down from 07:30 to 07:46 local.

  The fix is isolation, not tuning: background work gets its own small pool,
  so a slow compaction can only ever starve itself. These tests pin which side
  of that line each caller sits on — a background caller silently reverting to
  the shared pool is invisible until the next outage.
  """

  alias LS.Clickhouse

  describe "finch_for/1" do
    test "background work is routed away from the web tier's pool" do
      assert Clickhouse.finch_for(background: true) == LS.Finch.CHBackground
    end

    test "anything a user waits on keeps the big shared pool" do
      assert Clickhouse.finch_for([]) == LS.Finch.CH
      assert Clickhouse.finch_for(background: false) == LS.Finch.CH
      assert Clickhouse.finch_for(max_execution_time: 10) == LS.Finch.CH
    end

    test "a malformed opt falls back to the interactive pool rather than crashing a query" do
      assert Clickhouse.finch_for(background: nil) == LS.Finch.CH
      assert Clickhouse.finch_for(background: "yes") == LS.Finch.CHBackground
    end
  end

  describe "the long-running callers are on the background pool" do
    @source File.read!("lib/ls/clickhouse.ex")
    @optimizer File.read!("lib/ls/cluster/optimizer.ex")

    test "every compaction entry point passes background: true" do
      # These are the calls measured at 105-110s in the outage window.
      for fragment <- [
            "compact_sql(since_unix, until_unix), 1_200_000, background: true",
            "compact_sql(0, nil, 1790), 30 * 60_000, background: true",
            "compact_sql_shard(shard, total_shards), 1_200_000, background: true"
          ] do
        assert @source =~ fragment,
               "a compaction call reverted to the shared pool: #{fragment}"
      end
    end

    test "OPTIMIZE FINAL passes background: true — it runs for minutes" do
      assert @optimizer =~ "background: true"
    end

    test "the background pool is deliberately small so it cannot starve anything else" do
      app = File.read!("lib/ls/application.ex")
      assert app =~ "LS.Finch.CHBackground"

      [_, size] = Regex.run(~r/LS\.Finch\.CHBackground.*?size: (\d+)/s, app)
      assert String.to_integer(size) <= 30, "a large background pool defeats the isolation"
    end
  end
end
