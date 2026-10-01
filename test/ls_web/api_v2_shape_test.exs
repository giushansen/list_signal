defmodule LSWeb.ApiV2ShapeTest do
  @moduledoc """
  The API speaks the product table's own field names (data model v2,
  2026-10-01). The OpenAPI schema, the developers page and the landing
  example are generated from or written against the same spec; these pin
  that they agree, and that the new `/api/v1/changes` endpoint is wired
  with the same key auth as the rest.
  """
  use LSWeb.ConnCase, async: true

  alias LS.Schema.Columns

  test "the OpenAPI company schema lists every API column with its dictionary meaning" do
    spec = LSWeb.OpenapiController.spec()
    props = spec.components.schemas["Company"].properties

    for name <- Columns.api_columns(:company) do
      assert Map.has_key?(props, name), "#{name} missing from the OpenAPI Company schema"
      assert props[name].description == Columns.get(name).doc
    end

    assert props["http_tech"].type == "array"
    assert props["changes"].type == "array"
    assert Map.has_key?(spec.paths, "/api/v1/changes")
    assert spec.info.version == "2.0.0"
  end

  test "/openapi.json serves the generated spec without a key", %{conn: conn} do
    conn = get(conn, ~p"/openapi.json")
    body = json_response(conn, 200)
    assert body["paths"]["/api/v1/changes"]["get"]["operationId"] == "listChanges"
    assert body["components"]["schemas"]["Change"]["properties"]["summary"]
  end

  test "/api/v1/changes requires a key like every other endpoint", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/changes?field=http_tech")
    assert conn.status == 401
  end

  test "the developers page carries the data dictionary, the signals section and the example", %{conn: conn} do
    html = conn |> get(~p"/developers") |> html_response(200)
    assert html =~ "Every field, by name"
    assert html =~ "Signals: what changed"
    assert html =~ "/api/v1/changes"

    for {name, _type, _family, _signal, _doc} <- Columns.doc_rows() do
      assert html =~ name, "#{name} missing from the dictionary"
    end

    refute html =~ "compiled_at", "internal columns do not belong in the dictionary"
  end

  test "the landing page shows a call and its answer in the product's field names", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)
    assert html =~ "/api/v1/company/gymshark.com"
    assert html =~ ~s("estimated_revenue": "$100M-$1B")
    assert html =~ ~s("http_tech": ["Shopify")
    assert html =~ "/api/v1/changes?field=http_tech"
  end

  test "the free-tier gate blanks addresses under the new key and keeps the count" do
    record = %{http_emails: ["a@b.com", "c@d.com"], http_phone: "+1 555", domain: "x.com"}
    free = LSWeb.McpController.gate(record, "free")
    assert free.email_count == 2
    assert free.http_emails =~ "gated"
    assert free.http_phone == "gated"
    assert LSWeb.McpController.gate(record, "starter") == record
  end

  test "search filters accepted are the documented ones" do
    assert LS.ApiData.search_filters() == ~w(tech app dns_tech email_provider country business_model industry revenue employees hiring shopify limit offset)
    assert LS.ApiData.changes_filters() == ~w(field change value domain country business_model period limit offset)
  end
end
