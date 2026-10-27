defmodule LS.SchemaExamplesTest do
  @moduledoc """
  The two fictional businesses on /data must cover every customer-facing
  column with a value of the column's type (2026-10-27). A column added
  to LS.Schema.Columns without an example here fails the build, so the
  page can never silently show a field with no example, and a wrong type
  (a string in a numeric column) can never pass for a real row.
  """
  use ExUnit.Case, async: true

  alias LS.Schema.{Columns, Examples}

  test "every customer-facing column has a value on both examples, and nothing else does" do
    names = Columns.doc_rows() |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    for {_, _, record} <- Examples.all() do
      assert Map.keys(record) |> Enum.sort() == names
    end
  end

  test "every value has the column's type" do
    for {_, label, record} <- Examples.all(), {name, type, _, _, _} <- Columns.doc_rows() do
      value = Map.fetch!(record, name)
      assert typed?(type, value), "#{label}: #{name} (#{type}) holds #{inspect(value)}"
    end
  end

  defp typed?("Array(" <> _, v), do: is_list(v)
  defp typed?("Nullable(DateTime)", v), do: is_nil(v) or datetime?(v)
  defp typed?("DateTime", v), do: datetime?(v)
  defp typed?("Nullable(Float32)", v), do: is_nil(v) or is_number(v)
  defp typed?("Nullable(" <> _, v), do: is_nil(v) or is_integer(v)
  defp typed?("Float32", v), do: is_number(v)
  defp typed?("UInt8", v), do: v in [0, 1]
  defp typed?(_, v), do: is_binary(v)

  defp datetime?(v), do: is_binary(v) and Regex.match?(~r/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/, v)

  test "the store is a store and the SaaS is a SaaS, in the vocabularies the classifier writes" do
    store = Examples.store()
    saas = Examples.saas()
    assert store["estimated_business_model"] == "Ecommerce" and "Shopify" in store["http_tech"]
    assert store["shop_product_count"] > 0 and store["hr_job_count"] == 0
    assert saas["estimated_business_model"] == "SaaS" and saas["shop_product_count"] == nil
    assert saas["hr_job_count"] > 0 and saas["hr_ats"] == "greenhouse"
    assert store["estimated_revenue"] in LS.Revenue.Estimator.revenue_labels()
    assert saas["estimated_employees"] in LS.Revenue.Estimator.employee_labels()
  end

  test "the examples are fictional: the domains are not the real rows they were modelled on" do
    for {_, _, record} <- Examples.all() do
      refute record["domain"] in ["melbournesnowboard.com.au", "veremark.com"]
      assert record["domain"] =~ ~r/^[a-z]+\.(com\.au|co\.uk)$/
    end
  end

  test "the API record shape matches /api/v1/company" do
    for which <- ~w(store saas) do
      record = Examples.api_record(which)
      for col <- Columns.api_columns(:company), do: assert(Map.has_key?(record, col), col)
      assert length(record["changes"]) == 5
      assert Enum.all?(record["changes"], &(&1.summary != ""))
      assert Enum.all?(record["email_details"], &(&1.kind in ~w(named role) and &1.verdict in ~w(strong good weak undeliverable)))
      assert is_map(record["email_pattern"]) and is_list(record["people"])
    end
  end

  test "every example question parses with nothing ignored and opens in the dashboard as the same search" do
    for q <- Examples.queries() do
      {parsed, ignored} = LS.Query.parse(Map.new(q.filters))
      assert ignored == [], q.id
      assert map_size(parsed) == length(q.filters)

      url = Examples.dashboard_url(q)
      assert String.starts_with?(url, "/dashboard?")
      params = url |> String.replace_prefix("/dashboard?", "") |> URI.decode_query()
      assert LSWeb.ExplorerLive.filters_from_params(params) |> Map.take(Map.keys(parsed)) == parsed

      conds = LS.ApiData.conditions(Map.new(q.filters))
      assert length(conds) > 2, "#{q.id} compiles to no filter"
      assert Examples.mcp(q) =~ "listsignal_count"
      assert Examples.curl(q) =~ "/api/v1/search?"
    end
  end

  test "show prints a value the way the page needs it" do
    assert Examples.show(%{"a" => nil}, "a") == "null"
    assert Examples.show(%{"a" => ""}, "a") == "\"\""
    assert Examples.show(%{"a" => []}, "a") == "[]"
    assert Examples.show(%{"a" => ["x", "y"]}, "a") == "x, y"
    assert Examples.show(%{"a" => 142.6}, "a") == "142.6"
    assert Examples.show(%{"a" => 1299.0}, "a") == "1299"
    assert Examples.show(%{"a" => 7}, "a") == "7"
  end
end
