defmodule LS.Recrawl.LivenessTest do
  use ExUnit.Case, async: true

  alias LS.Recrawl.Liveness

  @moduledoc """
  2026-10-03: a worker writes no row for a name whose DNS fails, so a known
  business that went dark never advanced its last check and the oldest-first
  due query handed it out again every 30 minutes. 34 of the first 40 due
  names failed DNS from a laptop; in three hours 65K known businesses were
  enqueued for 7.5K refreshed, and 7 to 11 of every run's 11 batches wrote
  0 to 2 rows. The master now resolves the list first and records the dead.
  """

  @due [{"alive.example", "a"}, {"dead.example", "a"}, {"noaddr.example", "b"}, {"broken.example", "c"}]

  defp resolver(%{} = answers), do: fn d -> Map.get(answers, d, {:ok, %{a: ["203.0.113.9"]}}) end

  test "names with no A record or a resolver error are dead, the rest stay live with their tier" do
    resolve =
      resolver(%{
        "dead.example" => {:error, :dns_error},
        "noaddr.example" => {:ok, %{a: [], aaaa: [], mx: ["mx.example"]}},
        "broken.example" => {:ok, :garbage}
      })

    assert {:ok, live, dead} = Liveness.partition(@due, resolve)
    assert live == [{"alive.example", "a"}]
    assert Enum.sort(dead) == [{"broken.example", "c"}, {"dead.example", "a"}, {"noaddr.example", "b"}]
  end

  test "a resolver that cannot answer an anchor name is suspect and nothing is declared dead" do
    resolve = resolver(%{"cloudflare.com" => {:error, :timeout}, "dead.example" => {:error, :dns_error}})
    assert {:error, :resolver_suspect} = Liveness.partition(@due, resolve)
  end

  test "an empty due list resolves to nothing without touching the anchors" do
    assert {:ok, [], []} = Liveness.partition([], fn _ -> {:ok, %{a: ["203.0.113.1"]}} end)
    assert {:ok, 0} = Liveness.record_dead([])
  end

  test "dead? is pure and hostile answers count as dead" do
    assert Liveness.dead?({:error, :dns_error})
    assert Liveness.dead?({:ok, %{a: []}})
    assert Liveness.dead?({:ok, %{a: nil}})
    assert Liveness.dead?({:ok, %{}})
    assert Liveness.dead?(:boom)
    refute Liveness.dead?({:ok, %{a: ["203.0.113.1"]}})
  end

  test "the recorded check is a full copy of the newest row with only the check's columns overridden" do
    cols = ~w(domain enriched_at worker dns_a dns_mx http_status http_error http_title http_tech)
    sql = Liveness.record_dead_sql(cols)
    assert sql =~ "INSERT INTO enrich_log (domain, enriched_at, worker, dns_a, dns_mx, http_status, http_error, http_title, http_tech)"
    assert sql =~ "now() AS enriched_at"
    assert sql =~ "'master' AS worker"
    assert sql =~ "CAST(NULL AS Nullable(Int32)) AS http_status"
    assert sql =~ "'dns_unresolved' AS http_error"
    # Everything else is carried as it was: last known DNS, title and tech.
    assert sql =~ "SELECT domain, now() AS enriched_at, 'master' AS worker, dns_a, dns_mx, CAST(NULL AS Nullable(Int32)) AS http_status, 'dns_unresolved' AS http_error, http_title, http_tech"
    assert sql =~ "FROM (SELECT * FROM domains WHERE domain IN {doms:Array(String)}"
    assert sql =~ "ORDER BY enriched_at DESC LIMIT 1 BY domain"
    assert Liveness.error() == "dns_unresolved"
  end

  test "the due query makes a dead business come back after its cadence, never sooner" do
    # The recorded check advances http_last_checked_at (as_of = max enriched_at
    # in the compactor) and sets http_error, which the due query does not
    # exclude: the dead name costs one lookup per cadence, never a batch.
    sql = LS.Clickhouse.stale_domains_sql(10)
    assert sql =~ "http_error != 'robots_disallow'"
    refute sql =~ "dns_unresolved"
  end
end
