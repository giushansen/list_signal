defmodule LS.QueryGrammarTest do
  @moduledoc """
  One filter grammar on every surface (2026-10-27). Before this, the
  dashboard, the CSV export and the API each had their own names and
  their own SQL: `tech` was hasAll on the dashboard and has() on the API,
  the dashboard had no `has_named_email`, the API had no `tech_not`, and
  the API excluded junk while the dashboard did not, so one filter set
  counted differently on two surfaces. These tests hold the grammar, the
  Explorer and the API to one meaning per name.
  """
  use ExUnit.Case, async: true

  alias LS.{ApiData, Explorer, Query}

  describe "the grammar" do
    test "every filter has a unique name, a doc and an example, and aliases never shadow a name" do
      names = Query.names()
      assert names == Enum.uniq(names)

      for f <- Query.filters() do
        assert f.doc != "" and f.example != "", f.name
        for a <- f.aliases, do: refute(a in names, "alias #{a} shadows a filter name")
      end
    end

    test "parse maps public names and aliases to Explorer keys and reports what it ignored" do
      {filters, ignored} = Query.parse(%{"email_provider" => "Google Workspace", "domain" => "surf", "ats" => "greenhouse", "min_realness" => "0.5", "bogus" => "x", "sort" => "tranco"})
      assert filters[:dns_email_provider] == "Google Workspace"
      assert filters[:domain_search] == "surf"
      assert filters[:ats_platform] == "greenhouse"
      assert filters[:realness] == "0.5"
      assert ignored == ["bogus"]
      refute "sort" in ignored, "paging names travel with filters and are not errors"
    end

    test "two aliases of one list filter merge: tech and app both reach the tech clause" do
      {filters, _} = Query.parse(%{"tech" => "Shopify", "app" => "Klaviyo"})
      assert filters[:tech] == "Shopify,Klaviyo"
    end

    test "values arrive typed from MCP and as strings from a URL, and normalise the same" do
      {a, _} = Query.parse(%{"has_named_email" => true, "min_products" => 300, "country" => ["US", "GB"], "min_confidence" => 0.7})
      {b, _} = Query.parse(%{"has_named_email" => "true", "min_products" => "300", "country" => "US,GB", "min_confidence" => "0.7"})
      assert a == b
      assert a[:has_named_email] == "true"
      assert a[:min_products] == "300"
      assert a[:country] == "US,GB"
    end

    test "hostile and empty values are dropped, never passed through" do
      {filters, _} = Query.parse(%{"first_seen_after" => "yesterday", "country" => " , ", "hiring" => "maybe", "discovered" => "nonsense", "min_products" => "lots", "changed_field" => "password", "changed_kind" => "exploded"})
      assert filters == %{}
    end

    test "to_params prints canonical names only, blanks dropped, so the CSV link is the API query string" do
      params = Query.to_params(%{dns_email_provider: "Google Workspace", tech: "", domain_search: "surf", shopify_app: "Judge.me", page: 3})
      assert params == [{"domain", "surf"}, {"email_provider", "Google Workspace"}]
    end

    test "the MCP properties and the OpenAPI parameters carry every name" do
      names = MapSet.new(Query.names())
      assert Query.mcp_properties() |> Map.keys() |> Enum.map(&to_string/1) |> MapSet.new() == names
      assert Query.openapi_parameters() |> Enum.map(& &1.name) |> MapSet.new() == names
    end
  end

  describe "the dashboard accepts every name" do
    test "a URL that names any filter opens as that search" do
      for f <- Query.filters(), f.type != :enum or is_list(f.values) do
        filters = LSWeb.ExplorerLive.filters_from_params(%{f.name => f.example})
        assert Map.get(filters, f.key) not in [nil, ""], "#{f.name} did not reach the dashboard filters"
      end
    end

    test "a URL with no filter leaves the default view alone" do
      assert LSWeb.ExplorerLive.filters_from_params(%{"d" => "gymshark.com", "page" => "2"}) == %{}
    end
  end

  describe "parity: one name, one meaning" do
    @api_owned ~w(tech dns_tech email_provider country business_model industry revenue employees min_realness)

    test "every filter compiles to a clause on the Explorer and on the API" do
      for f <- Query.filters(), f.name not in ~w(include_junk changed_kind changed_value changed_within) do
        explorer = Explorer.clauses([{f.key, f.example}])
        api = ApiData.conditions(%{f.name => f.example}) -- Explorer.base_clauses([])
        assert explorer != [], "#{f.name} produced no Explorer clause"
        assert api != [], "#{f.name} produced no API clause"

        unless f.name in @api_owned do
          assert explorer == api, "#{f.name}: Explorer #{inspect(explorer)} vs API #{inspect(api)}"
        end
      end
    end

    test "the API's own clauses mean what the Explorer's mean" do
      # Single technology: the API promised has(), the dashboard hasAll([..]); one element either way.
      assert ApiData.conditions(%{"tech" => "Klaviyo"}) |> hd() == "has(http_tech, 'Klaviyo')"
      assert Explorer.clauses(tech: "Klaviyo") == ["hasAll(http_tech, ['Klaviyo'])"]
      # Several: both are hasAll.
      assert ApiData.conditions(%{"tech" => "Shopify,Klaviyo"}) |> hd() == "hasAll(http_tech, ['Shopify', 'Klaviyo'])"
      # Shopify as a model reads the stored flag on both.
      assert "is_shopify = 1" in ApiData.conditions(%{"business_model" => "Shopify"})
      assert Explorer.clauses(business_model: "Shopify") == ["is_shopify = 1"]
      assert "(estimated_business_model = 'SaaS' OR is_shopify = 1)" in ApiData.conditions(%{"business_model" => "Shopify,SaaS"})
      # The named-email predicate is one string, from LS.HTTP.EmailClass.
      [named] = Explorer.clauses(has_named_email: "true")
      assert named == LS.HTTP.EmailClass.named_email_sql()
      assert named in ApiData.conditions(%{"has_named_email" => "true"})
      assert String.starts_with?(named, "arrayExists(e -> NOT match(e, '^(info|hello|")
    end

    test "the base scope is the same on both and include_junk lifts only the junk part" do
      assert Explorer.scoped_where([]) == "WHERE http_title != '' AND estimated_junk = ''"
      assert Explorer.scoped_where(include_junk: "true") == "WHERE http_title != ''"
      assert ApiData.conditions(%{}) == ["http_title != ''", "estimated_junk = ''"]
      assert ApiData.conditions(%{"include_junk" => "true"}) == ["http_title != ''"]
      assert Explorer.count_sql([]) == "SELECT count() FROM businesses WHERE http_title != '' AND estimated_junk = ''"
    end
  end

  describe "the new clauses" do
    test "tech_any, tech_not and dns_tech are array tests on canonical names" do
      assert Explorer.clauses(tech_any: "Wix, Squarespace") == ["hasAny(http_tech, ['Wix', 'Squarespace'])"]
      assert Explorer.clauses(tech_not: "Gorgias") == ["NOT hasAny(http_tech, ['Gorgias'])"]
      assert Explorer.clauses(dns_tech: "Mailchimp") == ["hasAll(dns_tech, ['Mailchimp'])"]
    end

    test "keyword searches title, tagline and H1, any word, case-insensitive, escaped" do
      [clause] = Explorer.clauses(keyword: "shopify,e'commerce")
      assert clause =~ "positionCaseInsensitiveUTF8(http_title, 'shopify') > 0"
      assert clause =~ "positionCaseInsensitiveUTF8(http_h1, 'shopify') > 0"
      assert clause =~ " OR positionCaseInsensitiveUTF8(http_title, 'e\\'commerce')"
      refute clause =~ "e'commerce"
    end

    test "has_phone, min_confidence, shopify and the two dates" do
      assert Explorer.clauses(has_phone: "true") == ["http_phone != ''"]
      assert Explorer.clauses(min_confidence: "0.7") == ["estimated_business_model_confidence >= 0.7"]
      assert Explorer.clauses(min_confidence: "7") == []
      assert Explorer.clauses(shopify: "true") == ["is_shopify = 1"]
      assert Explorer.clauses(first_seen_after: "2026-10-01") == ["ctl_first_seen_at >= toDateTime('2026-10-01 00:00:00')"]
      assert Explorer.clauses(last_checked_after: "2026-10-20T10:00:00Z") == ["http_last_checked_at >= toDateTime('2026-10-20 00:00:00')"]
      assert Explorer.clauses(first_seen_after: "never") == []
      assert Explorer.clauses(discovered: "90d") == ["ctl_first_seen_at >= now() - INTERVAL 90 DAY"]
    end

    test "changed_* compile to one membership test on changes_log, field and kind from fixed lists" do
      [clause] = Explorer.clauses(changed_field: "hr_job_count", changed_kind: "started", changed_within: "30d")
      assert clause == "domain IN (SELECT domain FROM changes_log WHERE field = 'hr_job_count' AND changed_at >= now() - INTERVAL 30 DAY AND change = 'started')"

      [with_value] = Explorer.clauses(changed_field: "http_tech", changed_kind: "added", changed_value: "Klaviyo", changed_within: "7d")
      assert with_value =~ "value = 'Klaviyo'"
      assert with_value =~ "INTERVAL 7 DAY"

      # Default window 30 days; a kind or value without a field is nothing to look at.
      [default] = Explorer.clauses(changed_field: "http_status")
      assert default =~ "INTERVAL 30 DAY"
      assert Explorer.clauses(changed_kind: "started") == []
      assert Explorer.clauses(changed_field: "password", changed_kind: "started") == []
      # A quote in the value cannot leave the literal.
      [hostile] = Explorer.clauses(changed_field: "http_tech", changed_value: "x'; DROP TABLE businesses; --")
      assert hostile =~ "value = 'x\\' DROP TABLE businesses --'"
    end

    test "the same change filter runs on the API" do
      conds = ApiData.conditions(%{"changed_field" => "hr_job_count", "changed_kind" => "started", "changed_within" => "30d", "country" => "US"})
      assert Enum.any?(conds, &String.starts_with?(&1, "domain IN (SELECT domain FROM changes_log"))
      assert "estimated_country = 'US'" in conds
    end
  end

  describe "the API surface" do
    test "search_filters is the grammar then paging" do
      assert ApiData.search_filters() == Query.names() ++ ~w(total sort limit offset)
    end

    test "the MCP search, count and query tools expose every grammar name" do
      tools = LSWeb.McpController.tools()

      for name <- ~w(listsignal_count listsignal_search_companies listsignal_query) do
        t = Enum.find(tools, &(&1.name == name))
        props = t.inputSchema.properties |> Map.keys() |> Enum.map(&to_string/1)
        for n <- Query.names(), do: assert(n in props, "#{name} lacks #{n}")
      end

      count = Enum.find(tools, &(&1.name == "listsignal_count"))
      assert count.description =~ "Free"
    end

    test "the OpenAPI count and query paths carry the grammar" do
      spec = LSWeb.OpenapiController.spec()

      for path <- ["/api/v1/search", "/api/v1/count", "/api/v1/query"] do
        names = spec.paths[path].get.parameters |> Enum.map(& &1.name)
        for n <- Query.names(), do: assert(n in names, "#{path} lacks #{n}")
      end
    end
  end
end
