defmodule LS.FinchPoolIsolationTest do
  @moduledoc """
  Two outages (2026-08-03, 2026-08-13) had the same cause: a high-volume HTTP
  caller sharing Req's default Finch pool with slow work. The pool starved,
  the pipeline stalled to 0/min, and the web acceptors died with it while
  systemd still reported the service "active".

  The Aug 3 fix routed clickhouse.ex but missed the Inserter — the single
  biggest writer at ~3,600 req/min — so Aug 13 repeated it. This test is a
  source-level tripwire: it fails in CI if a hot path forgets its pool.
  """
  use ExUnit.Case, async: true

  # path => why it must be isolated
  @must_route %{
    "lib/ls/cluster/inserter.ex" => "~3,600 ClickHouse inserts/min",
    "lib/ls/clickhouse.ex" => "every ClickHouse query",
    "lib/ls/ctl/poller.ex" => "continuous CT-log polling",
    "lib/ls/reputation/tranco.ex" => "multi-minute bulk download",
    "lib/ls/reputation/majestic.ex" => "multi-minute bulk download",
    "lib/ls/reputation/blocklist.ex" => "multi-minute bulk download"
  }

  test "every hot HTTP path names an explicit Finch pool" do
    for {path, why} <- @must_route do
      source = File.read!(path)

      # Req.get/post calls in these modules must carry a finch: option. The
      # option may sit on a continuation line, so check the call through to
      # its closing paren rather than line-by-line.
      calls =
        Regex.scan(~r/Req\.(get|post)\((?:[^()]|\([^()]*\))*\)/s, source)
        |> Enum.map(&hd/1)

      assert calls != [], "#{path}: expected HTTP calls but found none — did the module move?"

      for call <- calls do
        assert call =~ "finch:",
               """
               #{path} has a Req call with no explicit pool (#{why}).
               Unpooled hot paths caused the 2026-08-03 and 2026-08-13 outages.
               Add `finch: LS.Finch.CH | LS.Finch.CTL | LS.Finch.Bulk` and a pool_timeout.
               """
      end
    end
  end

  test "the three pools are declared in the supervision tree" do
    app = File.read!("lib/ls/application.ex")

    for pool <- ~w(LS.Finch.CH LS.Finch.CTL LS.Finch.Bulk) do
      assert app =~ pool, "#{pool} is referenced by callers but not supervised"
    end
  end
end
