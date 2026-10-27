defmodule LSWeb.OpenapiController do
  @moduledoc """
  Serves `/openapi.json`, the machine-readable contract for `/api/v1`.

  The company schema is generated from `LS.Schema.Columns`: every property
  is a product column with the dictionary's own description, so the spec,
  the JSON, the dashboard and the docs page cannot drift apart. The filter
  parameters of search, count and query are generated from `LS.Query`
  for the same reason. Endpoint descriptions are hand-written: they are
  the ranking factor in agent tool-selection. `test/ls_web/api_v1_test.exs`
  pins the paths.
  """

  use LSWeb, :controller

  alias LS.{Plans, Query}
  alias LS.Schema.Columns

  def show(conn, _params) do
    conn
    |> put_resp_header("cache-control", "public, max-age=3600")
    |> json(spec())
  end

  def spec do
    %{
      openapi: "3.1.0",
      info: %{
        title: "ListSignal API",
        version: "2.1.0",
        description:
          "Live business intelligence for 14M+ online businesses, in two parts: the businesses (what each one is, runs, sells and earns: technologies and apps, revenue and employee bands, country, hiring, catalog, mailbox provider, contact data) and the signals (every change on a tracked field: a technology added or removed, hiring started or stopped, a revenue band moved, a website down or back). One filter grammar everywhere: the names on /search, /count and /query are the dashboard's filters and the CSV export's, documented at https://listsignal.com/data. Field names are the same in the API, the dashboard and the CSV; see the data dictionary at https://listsignal.com/developers#fields. Plans meter rows a month across every surface (#{plans_line()}); a search costs the rows it returns, a company record one row, counts and stats are free. Contact emails and phone require a paid plan. Auth: 'Authorization: Bearer ls_...' (or X-API-Key). Errors are RFC 9457 problem+json with actionable detail.",
        contact: %{email: "will@listsignal.com", url: "https://listsignal.com/developers"},
        "x-logo": %{
          url: "https://listsignal.com/images/brand/tile-green-512.png",
          altText: "ListSignal"
        }
      },
      servers: [%{url: "https://listsignal.com"}],
      security: [%{bearerAuth: []}],
      paths: %{
        "/api/v1/company/{domain}" => %{
          get: %{
            operationId: "getCompany",
            summary: "Get one company's full record by domain, with its recent changes",
            description:
              "Everything ListSignal knows about a domain, every product field under its own name, plus `changes`: the last 20 recorded changes, `email_details` (kind, source page, deliverability score and verdict per address), `email_pattern` and `people`. Costs one row. 404 when the domain is not yet in the dataset.",
            parameters: [
              %{
                name: "domain",
                in: "path",
                required: true,
                description: "Bare domain, e.g. gymshark.com (no scheme, no path)",
                schema: %{type: "string", example: "gymshark.com"}
              }
            ],
            responses: std_responses("Company record", "Company")
          }
        },
        "/api/v1/search" => %{
          get: %{
            operationId: "searchCompanies",
            summary: "Search companies with the shared filters: stack, who, stores, hiring, reachability, quality, when, what changed",
            description:
              "One page of the dataset, in the product's target ranking by default (sort=tranco for traffic order). All filters combine with AND; lists are comma-separated; the names and meanings are the dashboard's (https://listsignal.com/data#filters). `total=true` adds the count of everything that matches. The page cap is the plan's rows a page (#{page_line()}); each row returned costs one row of the month. The response echoes the filters honoured and the names ignored, so a mistyped one is visible immediately.",
            parameters:
              Query.openapi_parameters() ++
                [
                  qp("sort", "relevance (default: the product's target ranking, small real businesses with contact details first), tranco, first_seen, last_checked, products, jobs"),
                  %{name: "total", in: "query", required: false, description: "true to add the count of everything that matches", schema: %{type: "boolean"}},
                  %{name: "limit", in: "query", schema: %{type: "integer", maximum: 100, default: 25}},
                  %{name: "offset", in: "query", schema: %{type: "integer", maximum: 10_000, default: 0}}
                ],
            responses: std_responses("Matching companies", "SearchRow")
          }
        },
        "/api/v1/count" => %{
          get: %{
            operationId: "countCompanies",
            summary: "How many companies match the filters. Free: size a segment before you pull it",
            description:
              "The same filters as /search and /query, the same number as the dashboard's result count. Never charged, so an agent can test a filter, tighten it and only then spend rows. Approximate by about 0.03% (duplicates from unmerged parts); the response says so.",
            parameters: Query.openapi_parameters(),
            responses: std_responses("Count")
          }
        },
        "/api/v1/query" => %{
          get: %{
            operationId: "queryCompanies",
            summary: "The analysis read: total, group_by with counts, chosen fields, up to 500 rows",
            description:
              "One bounded read over the whole dataset: the shared filters, a sort, a comma-separated `fields` list drawn from the search columns, an optional `group_by` (estimated_business_model, estimated_country, estimated_revenue, estimated_employees, estimated_industry, dns_email_provider, ctl_tld) returning the top 50 values with counts, and the total. Up to 500 rows a call on Pro and Scale (the plan's rows a page on Free and Starter), ten seconds of execution. `limit=0` returns the total and the groups only and is free; rows returned cost one row each.",
            parameters:
              Query.openapi_parameters() ++
                [
                  qp("sort", "relevance (default), tranco, first_seen, last_checked, products, jobs"),
                  qp("fields", "Comma-separated columns to return, from the search columns; domain is always included"),
                  qp("group_by", "One of estimated_business_model, estimated_country, estimated_revenue, estimated_employees, estimated_industry, dns_email_provider, ctl_tld"),
                  %{name: "limit", in: "query", schema: %{type: "integer", maximum: 500, default: 100}},
                  %{name: "offset", in: "query", schema: %{type: "integer", maximum: 50_000, default: 0}}
                ],
            responses: std_responses("Rows, total and groups")
          }
        },
        "/api/v1/changes" => %{
          get: %{
            operationId: "listChanges",
            summary: "The change feed: what moved on which business, newest first",
            description:
              "One row per change of one tracked field on one business, with a one-line `summary` (\"Klaviyo added\", \"from $1M-$10M to $10M-$100M\", \"started hiring (12 roles)\", \"website down (502)\"). Filter by field, change kind, exact value, domain, country, business model and period. Each change row costs one row. Tracked fields are listed by /stats. To filter companies by a change instead, use changed_field on /search, /count or /query.",
            parameters: [
              qp("field", "A tracked field, e.g. http_tech, hr_job_count, estimated_revenue, http_status"),
              qp("change", "added, removed, changed, started, stopped, down, back"),
              qp("value", "Exact value, e.g. Klaviyo"),
              qp("domain", "Domain substring"),
              qp("country", "ISO-2 country of the business"),
              qp("business_model", "Business model of the business"),
              qp("period", "24h, 7d (default), 30d or 90d"),
              %{name: "limit", in: "query", schema: %{type: "integer", maximum: 100, default: 50}},
              %{name: "offset", in: "query", schema: %{type: "integer", maximum: 10_000, default: 0}}
            ],
            responses: std_responses("Changes", "Change")
          }
        },
        "/api/v1/technologies" => %{
          get: %{
            operationId: "listTechnologies",
            summary: "All tracked technologies, plugins and apps with company counts, category and ecosystem. Free",
            responses: std_responses("Technology directory")
          }
        },
        "/api/v1/stats" => %{
          get: %{
            operationId: "getDatasetStats",
            summary: "Live dataset statistics and the list of tracked fields. Free",
            description: "Businesses tracked, Shopify stores, technologies, domains checked in the past hour, and the fields the change feed tracks. Refreshed every 60 seconds. Citable.",
            responses: std_responses("Dataset statistics")
          }
        }
      },
      components: %{
        securitySchemes: %{
          bearerAuth: %{
            type: "http",
            scheme: "bearer",
            description: "API key from listsignal.com Settings. Free: 1,000 rows a month."
          }
        },
        schemas: %{
          "Company" => %{
            type: "object",
            description: "A business, every field under its product-table name. Prefix says the source: http_ the website, dns_ DNS, ctl_ certificate logs, rdap_ registration, bgp_ network, shop_ the store catalog, hr_ the job board, news_ news; estimated_ a rule or model with _confidence and _evidence; verified_ a public registry.",
            properties: schema_properties(:company) |> Map.put("changes", %{type: "array", items: %{"$ref": "#/components/schemas/Change"}})
          },
          "SearchRow" => %{
            type: "object",
            properties: schema_properties(:search) |> Map.put("has_contact", %{type: "boolean", description: "Whether an email is on file (addresses on paid plans via /company)."})
          },
          "Change" => %{
            type: "object",
            properties: %{
              "domain" => %{type: "string"},
              "field" => %{type: "string", description: "The tracked businesses column"},
              "change" => %{type: "string", enum: ~w(added removed changed started stopped down back)},
              "value" => %{type: "string", description: "The element added or removed, or the new value"},
              "prev_value" => %{type: "string"},
              "changed_at" => %{type: "string", format: "date-time"},
              "summary" => %{type: "string", description: "One line a person can read"},
              "http_title" => %{type: "string"},
              "estimated_country" => %{type: "string"},
              "estimated_business_model" => %{type: "string"}
            }
          }
        }
      }
    }
  end

  defp plans_line do
    Enum.map_join(Plans.self_serve(), ", ", fn p -> "#{Plans.label(p)} #{Plans.fmt(Plans.rows(p))}" end)
  end

  defp page_line do
    Enum.map_join(Plans.self_serve(), ", ", fn p -> "#{Plans.label(p)} #{Plans.per_page(p)}" end)
  end

  @doc "OpenAPI property map for one surface, from the column spec."
  def schema_properties(surface) do
    for name <- Columns.api_columns(surface), into: %{} do
      col = Columns.get(name)
      {name, Map.merge(json_type(col.type), %{description: col.doc})}
    end
  end

  defp json_type("Array(" <> _), do: %{type: "array", items: %{type: "string"}}
  defp json_type("Nullable(DateTime)"), do: %{type: ["string", "null"], format: "date-time"}
  defp json_type("DateTime"), do: %{type: "string", format: "date-time"}
  defp json_type("Nullable(Float32)"), do: %{type: ["number", "null"]}
  defp json_type("Nullable(" <> _), do: %{type: ["integer", "null"]}
  defp json_type("UInt8"), do: %{type: "integer"}
  defp json_type(_), do: %{type: "string"}

  defp qp(name, description),
    do: %{name: name, in: "query", required: false, description: description, schema: %{type: "string"}}

  defp std_responses(desc, schema \\ nil) do
    ok =
      if schema,
        do: %{description: desc, content: %{"application/json" => %{schema: %{"$ref": "#/components/schemas/#{schema}"}}}},
        else: %{description: desc}

    %{
      "200" => ok,
      "401" => %{description: "Missing or invalid API key (problem+json)"},
      "403" => %{description: "Monthly rows exhausted (problem+json)"},
      "429" => %{description: "Per-minute rate limit exceeded (problem+json, Retry-After header)"}
    }
  end
end
