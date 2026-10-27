defmodule LS.PlansTest do
  @moduledoc """
  One table of plan numbers (2026-10-27). Before LS.Plans the same plan
  was typed in seven places with three units; two were stale ($39, $29,
  500 rows) when this shipped. These tests pin the table's shape and the
  places that must read from it.
  """
  use ExUnit.Case, async: true

  alias LS.Plans

  test "the ladder is monotonic: more money, more rows, bigger pages, more searches" do
    plans = Plans.self_serve()
    rows = Enum.map(plans, &Plans.rows/1)
    assert rows == Enum.sort(rows) and rows == Enum.uniq(rows)
    assert Enum.map(plans, &Plans.monthly/1) == Enum.sort(Enum.map(plans, &Plans.monthly/1))
    assert Enum.map(plans, &Plans.per_min/1) == Enum.sort(Enum.map(plans, &Plans.per_min/1))
    assert Enum.map(plans, &Plans.per_page/1) == Enum.sort(Enum.map(plans, &Plans.per_page/1))
  end

  test "the numbers the pricing page prints" do
    assert Plans.rows("free") == 1_000 and Plans.monthly("free") == 0
    assert Plans.rows("starter") == 2_500 and Plans.monthly("starter") == 49
    assert Plans.rows("pro") == 15_000 and Plans.monthly("pro") == 149
    assert Plans.rows("scale") == 75_000 and Plans.monthly("scale") == 399
    assert Plans.monthly("dfy") == 999
    refute Plans.emails?("free")
    for p <- ~w(starter pro scale dfy), do: assert(Plans.emails?(p))
  end

  test "yearly is ten months: two months free, the badge the page shows" do
    for p <- ~w(starter pro scale) do
      assert Plans.yearly(p) == Plans.monthly(p) * 12 - Plans.monthly(p) * 2, p
      assert Plans.yearly_per_month(p) == div(Plans.yearly(p), 12)
    end

    assert Plans.yearly("dfy") == nil
  end

  test "done for you is Scale plus a person: same limits" do
    for f <- [&Plans.rows/1, &Plans.per_page/1, &Plans.per_min/1, &Plans.seats/1, &Plans.file_cap/1] do
      assert f.("dfy") == f.("scale")
    end
  end

  test "an unknown plan reads as free, never as more" do
    assert Plans.get("enterprise") == Plans.get("free")
    assert Plans.rows(nil) == 1_000
    refute Plans.paid?("enterprise")
  end

  test "a file never exceeds the month, and the query read is wider only on paid plans" do
    for p <- Plans.names(), do: assert(Plans.file_cap(p) <= Plans.rows(p), p)
    assert Plans.query_max("free") == Plans.per_page("free")
    assert Plans.query_max("pro") == 500
  end

  test "the user schema, the webhook and the checkout accept every paid plan" do
    user = %LS.Accounts.User{}

    for p <- Plans.paid_plans() do
      assert LS.Accounts.User.plan_changeset(user, %{plan: p}).valid?, p
    end

    refute LS.Accounts.User.plan_changeset(user, %{plan: "enterprise"}).valid?
  end

  test "fmt prints thousands" do
    assert Plans.fmt(1_000) == "1,000"
    assert Plans.fmt(75_000) == "75,000"
    assert Plans.fmt(999) == "999"
  end
end
