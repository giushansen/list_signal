defmodule LS.Query do
  @moduledoc """
  The one filter grammar (2026-10-27).

  The dashboard, its CSV export, `/api/v1/search`, `/api/v1/count`,
  `/api/v1/query` and the MCP tools all accept the names below with the
  same meaning. A list built by hand in the dashboard is the same URL
  query string on the export link, the same query string on the API, and
  the same argument map on the MCP tool; an agent that sensed a segment
  with a count can pull it with the same words. Before this module there
  were three grammars (`LS.Explorer` atom keys, `LS.ApiData` string keys,
  the export controller's own allow-list) and no two agreed on what
  `tech` meant.

  This module owns the vocabulary and the parsing. The SQL lives in
  `LS.Explorer.clauses/1`; `LS.ApiData.conditions/1` keeps a few clauses
  of its own where the API has promised an exact text, and delegates the
  rest. `test/ls/query_parity_test.exs` holds the two to the same meaning.

  Every value is parsed before it is trusted: lists are split and
  trimmed, numbers and dates are parsed, flags must be true, enums must
  be in their list. A value that fails is dropped, never passed through,
  and the name is reported in the ignored list so a caller can see it.
  """

  alias LS.Query.Filter

  @periods ~w(24h 7d 30d 90d)
  @changes ~w(added removed changed started stopped down back)

  @filters [
    # ── What it runs ────────────────────────────────────────────────────
    %Filter{name: "tech", key: :tech, type: :list, aliases: ~w(app shopify_app), group: "What it runs",
      doc: "Technologies, plugins or apps the site runs, every one of them. Catalog names, comma-separated. A platform, a vendor, a WordPress plugin or a Shopify app alike.",
      example: "Shopify,Klaviyo"},
    %Filter{name: "tech_any", key: :tech_any, type: :list, group: "What it runs",
      doc: "Runs at least one of these.", example: "Wix,Squarespace"},
    %Filter{name: "tech_not", key: :tech_not, type: :list, group: "What it runs",
      doc: "Runs none of these. The displacement filter: on Shopify and Klaviyo but not yet on Gorgias.", example: "Gorgias"},
    %Filter{name: "dns_tech", key: :dns_tech, type: :list, group: "What it runs",
      doc: "Vendors visible in DNS: email senders from SPF and DKIM, verification records.", example: "Mailchimp"},
    %Filter{name: "email_provider", key: :dns_email_provider, type: :list, aliases: ~w(dns_email_provider), group: "What it runs",
      doc: "Who hosts the mailboxes: Google Workspace, Microsoft 365, Zoho Mail, Proton Mail.", example: "Google Workspace"},

    # ── Who it is ──────────────────────────────────────────────────────
    %Filter{name: "country", key: :country, type: :list, group: "Who it is",
      doc: "ISO-2 country codes.", example: "US,GB,CA,AU"},
    %Filter{name: "business_model", key: :business_model, type: :list, group: "Who it is",
      doc: "Ecommerce, SaaS, Agency, Marketplace, Tool, Media, Consulting, LocalBusiness, Manufacturer and the other classifier labels. Shopify is accepted too and means a Shopify store.",
      example: "SaaS,Tool"},
    %Filter{name: "industry", key: :industry, type: :list, group: "Who it is",
      doc: "Industry labels from the classifier.", example: "Fintech"},
    %Filter{name: "revenue", key: :revenue, type: :list, group: "Who it is",
      doc: "Revenue bands: <$1M, $1M-$10M, $10M-$100M, $100M-$1B, $1B+.", example: "$1M-$10M,$10M-$100M"},
    %Filter{name: "employees", key: :employees, type: :list, group: "Who it is",
      doc: "Headcount bands: 1-10, 11-50, 51-500, 501-5000, 5001+.", example: "11-50,51-500"},
    %Filter{name: "language", key: :language, type: :list, group: "Who it is",
      doc: "Page language, primary subtag.", example: "en,de"},
    %Filter{name: "domain", key: :domain_search, type: :text, aliases: ~w(domain_search), group: "Who it is",
      doc: "The domain contains this text.", example: "surf"},
    %Filter{name: "keyword", key: :keyword, type: :list, group: "Who it is",
      doc: "Any of these words in the homepage title, description or H1. How to find the agencies that say what they do.",
      example: "shopify,ecommerce"},
    %Filter{name: "min_confidence", key: :min_confidence, type: :number, group: "Who it is",
      doc: "Minimum confidence of the business-model label, 0 to 1. 0.7 keeps the labels the golden set scores at 89%.", example: "0.7"},
    %Filter{name: "min_realness", key: :realness, type: :number, aliases: ~w(realness), group: "Who it is",
      doc: "Minimum estimated_realness, 0 to 1. 0.5 keeps businesses with mail, a contact and 90 days of certificates; 0.7 adds traffic, a catalog or jobs.",
      example: "0.5"},
    %Filter{name: "include_junk", key: :include_junk, type: :flag, group: "Who it is",
      doc: "Parked and placeholder sites are excluded everywhere by default; true includes them.", example: "true"},

    # ── Stores ─────────────────────────────────────────────────────────
    %Filter{name: "shopify", key: :shopify, type: :flag, group: "Stores",
      doc: "Shopify stores only. The same as business_model=Shopify.", example: "true"},
    %Filter{name: "has_catalog", key: :has_catalog, type: :flag, group: "Stores",
      doc: "A readable product catalog, so a real storefront and not a site that merely loads Shopify.", example: "true"},
    %Filter{name: "min_products", key: :min_products, type: :int, group: "Stores",
      doc: "At least this many products in the catalog.", example: "300"},
    %Filter{name: "max_products", key: :max_products, type: :int, group: "Stores",
      doc: "At most this many products.", example: "2000"},
    %Filter{name: "min_price_avg", key: :min_price_avg, type: :number, group: "Stores",
      doc: "Average product price at least this, in the store's currency.", example: "100"},
    %Filter{name: "max_price_avg", key: :max_price_avg, type: :number, group: "Stores",
      doc: "Average product price at most this.", example: "500"},
    %Filter{name: "min_new_products_30d", key: :min_new_products_30d, type: :int, group: "Stores",
      doc: "At least this many products added in the last 30 days: an active catalog is a live business.", example: "5"},

    # ── SaaS and hiring ────────────────────────────────────────────────
    %Filter{name: "has_pricing", key: :has_pricing, type: :flag, group: "SaaS and hiring",
      doc: "A pricing page with printed prices.", example: "true"},
    %Filter{name: "hiring", key: :hiring, type: :flag, group: "SaaS and hiring",
      doc: "Open roles on the public job board right now.", example: "true"},
    %Filter{name: "min_job_count", key: :min_job_count, type: :int, group: "SaaS and hiring",
      doc: "At least this many open roles.", example: "5"},
    %Filter{name: "ats", key: :ats_platform, type: :text, aliases: ~w(ats_platform), group: "SaaS and hiring",
      doc: "The applicant tracking system: greenhouse, lever, ashby, workable, smartrecruiters, personio and the rest.", example: "greenhouse"},

    # ── Reachability ───────────────────────────────────────────────────
    %Filter{name: "has_email", key: :has_email, type: :flag, group: "Reachability",
      doc: "At least one address published on the site.", example: "true"},
    %Filter{name: "has_named_email", key: :has_named_email, type: :flag, group: "Reachability",
      doc: "A person's address on the company's own domain, not info@ or hello@. These reply two to three times as often as role addresses.", example: "true"},
    %Filter{name: "has_phone", key: :has_phone, type: :flag, group: "Reachability",
      doc: "A phone number printed on the site.", example: "true"},

    # ── Quality ────────────────────────────────────────────────────────
    %Filter{name: "min_seo_score", key: :min_seo_score, type: :int, group: "Quality",
      doc: "SEO score at least this, 0 to 100.", example: "70"},
    %Filter{name: "max_seo_score", key: :max_seo_score, type: :int, group: "Quality",
      doc: "SEO score at most this. Unscored sites are not included: unknown is not bad.", example: "49"},

    # ── When ───────────────────────────────────────────────────────────
    %Filter{name: "first_seen_after", key: :first_seen_after, type: :date, group: "When",
      doc: "First seen in certificate logs on or after this date. The new-business signal.", example: "2026-10-01"},
    %Filter{name: "last_checked_after", key: :last_checked_after, type: :date, group: "When",
      doc: "Website checked on or after this date.", example: "2026-10-20"},
    %Filter{name: "discovered", key: :discovered, type: :enum, values: @periods, group: "When",
      doc: "First seen within the window: 24h, 7d, 30d or 90d. A relative first_seen_after.", example: "30d"},
    %Filter{name: "freshness", key: :freshness, type: :enum, values: @periods, group: "When",
      doc: "Checked within the window: 24h, 7d, 30d or 90d. Not the same as discovered.", example: "7d"},

    # ── What changed ───────────────────────────────────────────────────
    %Filter{name: "changed_field", key: :changed_field, type: :enum, values: :tracked_fields, group: "What changed",
      doc: "Keep companies with a recorded change on this tracked field: http_tech, hr_job_count, estimated_revenue, http_status, shop_theme and the other 21. Combine with changed_kind, changed_value and changed_within.",
      example: "hr_job_count"},
    %Filter{name: "changed_kind", key: :changed_kind, type: :enum, values: @changes, group: "What changed",
      doc: "Which way it moved: added, removed, changed, started, stopped, down, back.", example: "started"},
    %Filter{name: "changed_value", key: :changed_value, type: :text, group: "What changed",
      doc: "The exact value that was added, removed or arrived at, e.g. Klaviyo.", example: "Klaviyo"},
    %Filter{name: "changed_within", key: :changed_within, type: :enum, values: @periods, group: "What changed",
      doc: "How far back to look for the change: 24h, 7d, 30d (default) or 90d.", example: "30d"}
  ]

  # Names that are not filters but legitimately travel with them.
  @reserved ~w(sort limit offset fields group_by total page dir d checkout _csrf_token q)

  @doc "Every filter of the grammar, in documentation order."
  @spec filters() :: [Filter.t()]
  def filters, do: @filters

  @doc "The canonical filter names, in documentation order."
  @spec names() :: [String.t()]
  def names, do: Enum.map(@filters, & &1.name)

  @doc "Every name the parser accepts: the canonical names and their aliases."
  @spec accepted_names() :: [String.t()]
  def accepted_names, do: Enum.flat_map(@filters, &[&1.name | &1.aliases])

  @doc "The filter named `name` (canonical or alias), or nil."
  @spec get(String.t()) :: Filter.t() | nil
  def get(name), do: Enum.find(@filters, &(&1.name == name or name in &1.aliases))

  @doc "The Explorer key each canonical name maps to, for building URLs from a filter map."
  @spec key_to_name() :: %{atom() => String.t()}
  def key_to_name, do: Map.new(@filters, &{&1.key, &1.name})

  @doc """
  Parse a map of request params (string or atom keys, values as strings,
  numbers, booleans or lists) into `{filters, ignored}`: `filters` is a
  map keyed by Explorer atom with every value normalised to the string
  form the dashboard uses ("US,GB", "true", "300", "2026-10-01"), and
  `ignored` lists the names the caller sent that are not in the grammar.
  Blank and invalid values are dropped. Two aliases of one list filter
  (`tech` and `app`) are merged.
  """
  @spec parse(map() | keyword()) :: {map(), [String.t()]}
  def parse(params) do
    params = Map.new(params, fn {k, v} -> {to_string(k), v} end)

    # Canonical names before aliases, so a merged list reads "tech,app" in
    # the order the caller would expect and the result is deterministic.
    ordered = Enum.sort_by(params, fn {name, _} -> if(canonical?(name), do: 0, else: 1) end)

    {filters, ignored} =
      Enum.reduce(ordered, {%{}, []}, fn {name, raw}, {acc, ignored} ->
        case get(name) do
          nil ->
            if name in @reserved, do: {acc, ignored}, else: {acc, [name | ignored]}

          %Filter{} = f ->
            case normalise(f, raw) do
              nil -> {acc, ignored}
              value -> {Map.update(acc, f.key, value, &merge(f, &1, value)), ignored}
            end
        end
      end)

    {filters, Enum.reverse(ignored)}
  end

  defp canonical?(name), do: Enum.any?(@filters, &(&1.name == name))

  # A list filter given twice (tech and app) keeps both; anything else keeps the first.
  defp merge(%Filter{type: :list}, a, b), do: Enum.join(Enum.uniq(String.split(a <> "," <> b, ",")), ",")
  defp merge(_, a, _b), do: a

  @doc "Parse to a keyword list, the form `LS.Explorer` functions take."
  @spec parse_filters(map() | keyword()) :: keyword()
  def parse_filters(params), do: params |> parse() |> elem(0) |> Enum.to_list()

  @doc """
  The query-string pairs for a filter map, canonical names only, blanks
  dropped, so the dashboard's export link and a /data example can be built
  from the same filters a page is showing.
  """
  @spec to_params(map() | keyword()) :: [{String.t(), String.t()}]
  def to_params(filters) do
    names = key_to_name()

    filters
    |> Enum.flat_map(fn {key, value} ->
      value = to_string(value || "")

      case Map.get(names, key) do
        nil -> []
        _ when value == "" -> []
        name -> [{name, value}]
      end
    end)
    |> Enum.sort()
  end

  @doc "The English reading of a filter map, for audit rows and the example pages."
  @spec describe(map() | keyword()) :: String.t()
  def describe(filters) do
    filters
    |> to_params()
    |> Enum.map_join("; ", fn {name, value} -> "#{name} #{value}" end)
  end

  # ── Documentation surfaces ───────────────────────────────────────────

  @doc "OpenAPI query parameters for the search, count and query endpoints."
  @spec openapi_parameters() :: [map()]
  def openapi_parameters do
    for f <- @filters do
      %{name: f.name, in: "query", required: false, description: "#{f.doc} Example: #{f.example}", schema: openapi_schema(f)}
    end
  end

  defp openapi_schema(%Filter{type: :flag}), do: %{type: "boolean"}
  defp openapi_schema(%Filter{type: :int}), do: %{type: "integer"}
  defp openapi_schema(%Filter{type: :number}), do: %{type: "number"}
  defp openapi_schema(%Filter{type: :date}), do: %{type: "string", format: "date"}
  defp openapi_schema(%Filter{type: :enum, values: v}) when is_list(v), do: %{type: "string", enum: v}
  defp openapi_schema(_), do: %{type: "string"}

  @doc "The MCP tool inputSchema properties for the filters, one entry per canonical name."
  @spec mcp_properties() :: map()
  def mcp_properties do
    Map.new(@filters, fn f ->
      {String.to_atom(f.name), %{type: mcp_type(f), description: "#{f.doc} Example: #{f.example}"}}
    end)
  end

  defp mcp_type(%Filter{type: :flag}), do: "boolean"
  defp mcp_type(%Filter{type: :int}), do: "integer"
  defp mcp_type(%Filter{type: :number}), do: "number"
  defp mcp_type(_), do: "string"

  @doc "Filters grouped for the docs page: `[{group, [filter]}]` in grammar order."
  @spec groups() :: [{String.t(), [Filter.t()]}]
  def groups do
    @filters
    |> Enum.group_by(& &1.group)
    |> Enum.sort_by(fn {g, _} -> Enum.find_index(@filters, &(&1.group == g)) end)
  end

  @doc "The period windows the relative date filters accept."
  def periods, do: @periods

  # ── Value normalisation ──────────────────────────────────────────────

  defp normalise(_f, nil), do: nil
  defp normalise(_f, ""), do: nil

  defp normalise(%Filter{type: :list}, v) do
    v
    |> List.wrap()
    |> Enum.flat_map(&String.split(to_string(&1), ","))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.slice(&1, 0, 100))
    |> case do
      [] -> nil
      list -> Enum.join(list, ",")
    end
  end

  defp normalise(%Filter{type: :text}, v) do
    case v |> to_string() |> String.trim() do
      "" -> nil
      s -> String.slice(s, 0, 200)
    end
  end

  defp normalise(%Filter{type: :flag}, v) do
    if v in [true, "true", "1", 1, "yes", "on"], do: "true", else: nil
  end

  defp normalise(%Filter{type: :int}, v) when is_integer(v), do: Integer.to_string(v)
  defp normalise(%Filter{type: :int}, v) when is_float(v), do: Integer.to_string(trunc(v))

  defp normalise(%Filter{type: :int}, v) when is_binary(v) do
    case Integer.parse(String.trim(v)) do
      {n, _} -> Integer.to_string(n)
      :error -> nil
    end
  end

  defp normalise(%Filter{type: :number}, v) when is_number(v), do: to_string(v)

  defp normalise(%Filter{type: :number}, v) when is_binary(v) do
    case Float.parse(String.trim_trailing(String.trim(v), "+")) do
      {f, _} -> to_string(f)
      :error -> nil
    end
  end

  defp normalise(%Filter{type: :date}, v) when is_binary(v) do
    case Date.from_iso8601(String.slice(String.trim(v), 0, 10)) do
      {:ok, d} -> Date.to_iso8601(d)
      _ -> nil
    end
  end

  defp normalise(%Filter{type: :enum, values: :tracked_fields}, v) when is_binary(v) do
    v = String.trim(v)
    if v in LS.Signals.fields(), do: v, else: nil
  end

  defp normalise(%Filter{type: :enum, values: values}, v) when is_binary(v) do
    v = String.trim(v)
    if v in values, do: v, else: nil
  end

  defp normalise(_f, _v), do: nil
end
