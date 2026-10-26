defmodule LS.Schema.ChangesHostnameTimeTest do
  @moduledoc """
  2026-10-26: a business the rings keep from being fetched is recompiled
  when a certificate sighting names a new host (since 10-24), and the host
  was stored (20,279 of 20,287 checked), but the change event was dated by
  the last fetch, months back, where the feed never shows it. Certificate
  fields are now dated by the pass that folded them.
  """
  use ExUnit.Case, async: true

  alias LS.Schema.{Changes, Columns}

  test "a hostname event is dated now, not by the last fetch" do
    {_, rule, type, opts} = Enum.find(Columns.tracked_rules(), &(elem(&1, 0) == "ctl_subdomains"))
    sql = Changes.rule_sql({"ctl_subdomains", rule, type, opts})
    assert sql =~ "('ctl_subdomains', 'added', toString(x), '', now())"
    refute sql =~ "('ctl_subdomains', 'added', toString(x), '', n.http_last_checked_at)"
  end

  test "page facts keep the fetch time" do
    assert Changes.rule_sql({"http_tech", :set, "Array(String)"}) =~ "n.http_last_checked_at)"
    assert Changes.rule_sql({"http_title", :changed, "String"}) =~ "n.http_last_checked_at)"
  end
end
