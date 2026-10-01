defmodule LS.Schema.ChangesNoiseTest do
  @moduledoc """
  The first v2 passes (2026-10-01) wrote 54,219 subdomain events, 15,602 of
  them "www added", and 19,399 "social link added" rows that were the new
  column filling for the first time. Two rule options keep that out of the
  feed: `ignore` for infrastructure labels, `since` for a column that did
  not exist when the old row was observed.
  """
  use ExUnit.Case, async: true

  alias LS.Schema.{Changes, Columns}

  test "subdomain events skip mail, hosting-panel and device-enrolment labels but keep expansion labels" do
    {_, rule, type, opts} = Enum.find(Columns.tracked_rules(), &(elem(&1, 0) == "ctl_subdomains"))
    sql = Changes.rule_sql({"ctl_subdomains", rule, type, opts})
    for label <- ~w(www mail webmail cpanel autodiscover mta-sts), do: assert(sql =~ "'#{label}'")
    for label <- ~w(app shop api careers staging), do: refute(sql =~ "'#{label}'", "#{label} is a signal")
    assert sql =~ "arrayFilter(t -> t.3 NOT IN ("
  end

  test "a column introduced with v2 cannot have changed on a row observed before v2" do
    {_, rule, type, opts} = Enum.find(Columns.tracked_rules(), &(elem(&1, 0) == "http_social_links"))
    sql = Changes.rule_sql({"http_social_links", rule, type, opts})
    assert sql =~ "if(ifNull(o.http_last_seen_at, toDateTime(0)) >= toDateTime('2026-10-01 08:25:00'),"
    assert String.ends_with?(sql, ", [])")
  end

  test "the detector carries the old row's observation time and uses the rules with options" do
    sql = Changes.detect_sql("tmp_x")
    assert sql =~ "SELECT domain, http_last_seen_at,"
    assert sql =~ "toDateTime('2026-10-01 08:25:00')"
    assert sql =~ "'www'"
  end

  test "a rule without options is unchanged" do
    assert Changes.rule_sql({"http_tech", :set, "Array(String)", [since: nil, ignore: []]}) ==
             Changes.rule_sql({"http_tech", :set, "Array(String)"})
  end

  test "the junk fold lets a parking nameserver override the page verdict" do
    sql = Columns.fold_expr(Columns.get("estimated_junk"))
    assert sql =~ "'parked', h.is_junk)"
    assert sql =~ "sedoparking.com"
  end

  test "shop currency and locale changes are tracked (international expansion)" do
    names = Columns.tracked() |> Enum.map(&elem(&1, 0))
    assert "shop_currency" in names
    assert "shop_locales" in names
  end
end
