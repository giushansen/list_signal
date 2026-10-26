defmodule LS.Cluster.WorkerChildRowsTest do
  @moduledoc """
  2026-10-26: per-address provenance and people travel beside the batch
  rows to the master's child-table writer, so the Inserter and the
  enrich_log schema are untouched.
  """
  use ExUnit.Case, async: true

  alias LS.Cluster.WorkerAgent

  test "contacts and people rows are stamped with the domain and the crawl time" do
    http_res = %{
      "store.example" => %{
        http_status: 200,
        _contacts: [%{email: "hello@store.example", source_page: "contact", on_domain: 1, kind: "role"}],
        _people: [%{name: "Ada Lovelace", title: "Owner", email: "", source: "about"}]
      },
      "failed.example" => %{http_error: "transport::timeout"},
      "odd.example" => :not_a_map
    }

    %{contacts: [c], people: [p]} = WorkerAgent.child_rows(http_res)
    assert %{domain: "store.example", email: "hello@store.example", source_page: "contact", on_domain: 1} = c
    assert %{domain: "store.example", name: "Ada Lovelace", title: "Owner", email: "", source_page: "about"} = p
    assert String.length(c.seen_at) == 19
  end

  test "no rows is an empty map, and garbage never raises" do
    assert WorkerAgent.child_rows(%{}) == %{contacts: [], people: []}
    assert WorkerAgent.child_rows(nil) == %{contacts: [], people: []}
  end

  test "the fold publishes only sellable contact rows from the depth lane" do
    sql = LS.Clickhouse.Compact.fold_select_sql(1_700_000_000, 1_700_003_600)
    assert sql =~ "groupUniqArrayIf(20)(email, (on_domain = 1 OR"
    assert sql =~ "FROM http_contacts WHERE domain IN (SELECT arrayJoin(_touched)) GROUP BY domain"
  end
end
