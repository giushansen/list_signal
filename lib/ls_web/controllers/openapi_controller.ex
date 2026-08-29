defmodule LSWeb.OpenapiController do
  @moduledoc """
  Serves `/openapi.json`, the machine-readable contract for `/api/v1`.

  Hand-maintained rather than generated: four endpoints do not justify a
  spec-generation dependency, and hand-written descriptions are the ranking
  factor in agent tool-selection. If an endpoint changes, this file changes
  in the same commit (`test/ls_web/api_v1_test.exs` pins the paths).
  """

  use LSWeb, :controller

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
        version: "1.0.0",
        description:
          "Live business intelligence for 14M+ online businesses: tech stacks, Shopify apps, revenue and employee estimates, hiring signals with posting dates, SEO scores, and contact emails. Free tier: 1,000 lookups/month. Contact emails require a paid plan. Auth: 'Authorization: Bearer ls_...' (or X-API-Key). Errors are RFC 9457 problem+json with actionable detail.",
        contact: %{email: "will@listsignal.com", url: "https://listsignal.com/developers"}
      },
      servers: [%{url: "https://listsignal.com"}],
      security: [%{bearerAuth: []}],
      paths: %{
        "/api/v1/company/{domain}" => %{
          get: %{
            operationId: "getCompany",
            summary: "Get one company's full record by domain",
            description:
              "Everything ListSignal knows about a domain: tech stack, Shopify apps, revenue/employee estimates, open jobs with a hiring overview, SEO score, traffic rank, and contact emails (paid plans). 404 when the domain is not yet in the dataset.",
            parameters: [
              %{
                name: "domain",
                in: "path",
                required: true,
                description: "Bare domain, e.g. gymshark.com (no scheme, no path)",
                schema: %{type: "string", example: "gymshark.com"}
              }
            ],
            responses: std_responses("Company record")
          }
        },
        "/api/v1/search" => %{
          get: %{
            operationId: "searchCompanies",
            summary: "Search companies by technology, country, model, revenue, or hiring",
            description:
              "Filtered slice of the dataset, ranked by traffic. All filters combine with AND. Response echoes the accepted filters so a mistyped one is visible immediately.",
            parameters: [
              qp("tech", "Technology name substring, e.g. Shopify, Klaviyo, HubSpot"),
              qp("app", "Shopify app name substring, e.g. ReCharge"),
              qp("country", "ISO-2 country code, e.g. US, FR"),
              qp("business_model", "One of: Ecommerce, SaaS, Agency, Marketplace, Tool, Media, Consulting"),
              qp("revenue", "Revenue bracket, e.g. $1M-$10M"),
              qp("hiring", "true to keep only companies with open jobs"),
              %{name: "limit", in: "query", schema: %{type: "integer", maximum: 100, default: 25}},
              %{name: "offset", in: "query", schema: %{type: "integer", maximum: 10_000, default: 0}}
            ],
            responses: std_responses("Matching companies")
          }
        },
        "/api/v1/technologies" => %{
          get: %{
            operationId: "listTechnologies",
            summary: "All tracked technologies with company counts",
            responses: std_responses("Technology directory")
          }
        },
        "/api/v1/stats" => %{
          get: %{
            operationId: "getDatasetStats",
            summary: "Live dataset statistics",
            description: "Businesses tracked, Shopify stores, technologies, and domains checked in the past hour. Refreshed every 60 seconds. Citable.",
            responses: std_responses("Dataset statistics")
          }
        }
      },
      components: %{
        securitySchemes: %{
          bearerAuth: %{
            type: "http",
            scheme: "bearer",
            description: "API key from listsignal.com Settings. Free tier: 1,000 calls/month."
          }
        }
      }
    }
  end

  defp qp(name, description),
    do: %{name: name, in: "query", required: false, description: description, schema: %{type: "string"}}

  defp std_responses(desc) do
    %{
      "200" => %{description: desc},
      "401" => %{description: "Missing or invalid API key (problem+json)"},
      "403" => %{description: "Monthly quota exhausted (problem+json)"},
      "429" => %{description: "Per-minute rate limit exceeded (problem+json, Retry-After header)"}
    }
  end
end
