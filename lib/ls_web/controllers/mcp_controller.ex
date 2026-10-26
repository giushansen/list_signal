defmodule LSWeb.McpController do
  @moduledoc """
  A stateless Model Context Protocol server over Streamable HTTP.

  One POST endpoint speaking JSON-RPC 2.0, implementing the minimum that
  makes ListSignal usable from Claude, Cursor, and other MCP clients:
  `initialize`, `tools/list`, `tools/call` (plus `ping` and no-op
  `notifications/*`). Stateless by design: no sessions, no SSE stream, every
  request self-contained and authenticated by the same API key as
  `/api/v1`: which the spec permits and which keeps this deployable on the
  existing single web node.

  Tool design follows the "few consolidated tools" rule: three tools that
  answer whole questions, named with the `listsignal_` prefix so they read
  unambiguously in a client's tool list, with descriptions written for the
  model that has to choose them.
  """

  use LSWeb, :controller
  alias LS.ApiData

  @protocol_version "2025-06-18"

  @tools [
    %{
      name: "listsignal_get_company",
      description:
        "Get everything ListSignal knows about one company by its website domain: the full product record under stable field names (http_tech: technologies, plugins and apps; estimated_revenue and estimated_employees with confidence and evidence; estimated_country; hr_job_count and hr_departments; shop_product_count and prices for stores; dns_email_provider; http_emails and http_phone on paid plans, each email with its kind (named, role, free_mail, sister) and the page it was found on in `email_details`, the naming pattern the named ones imply in `email_pattern`, and the named people found on the site in `people` with title and source page) plus `changes`, the last 20 recorded changes (a technology added or removed, hiring started, a revenue band moved, the website going down). Use when the user asks about a specific company or website.",
      inputSchema: %{
        type: "object",
        properties: %{
          domain: %{type: "string", description: "Bare domain, e.g. gymshark.com"}
        },
        required: ["domain"]
      }
    },
    %{
      name: "listsignal_search_companies",
      description:
        "Find companies by technology or app (one http_tech name), DNS vendor, mailbox provider, country, business model, industry, revenue or employee band, hiring status, Shopify, a named email, or first-seen date. Filters combine with AND. Returns up to 100 companies per call, by default in the product's target ranking (small real businesses with contact details first; sort=tranco for traffic order); use offset to page. Use for questions like 'find SaaS companies in France using HubSpot that are hiring' or 'Shopify stores on Google Workspace with more than 500 products'.",
      inputSchema: %{
        type: "object",
        properties: %{
          tech: %{type: "string", description: "One technology, plugin or app name as it appears in http_tech, e.g. Shopify, Klaviyo, HubSpot, Yoast SEO, Judge.me"},
          app: %{type: "string", description: "Same as tech, kept for older clients"},
          dns_tech: %{type: "string", description: "A vendor visible in DNS, e.g. Mailchimp, SendGrid, Salesforce"},
          email_provider: %{type: "string", description: "Mailbox provider: Google Workspace, Microsoft 365, Zoho Mail, Proton Mail"},
          country: %{type: "string", description: "ISO-2 country code, e.g. US, FR"},
          business_model: %{
            type: "string",
            description: "Ecommerce, SaaS, Agency, Marketplace, Tool, Media, Consulting, LocalBusiness"
          },
          industry: %{type: "string", description: "Industry label, e.g. Fintech, Fashion"},
          revenue: %{type: "string", description: "Revenue band: <$1M, $1M-$10M, $10M-$100M, $100M-$1B, $1B+"},
          min_realness: %{type: "string", description: "Minimum estimated_realness (0 to 1); 0.5 keeps businesses with mail, a contact and 90 days of certificates, 0.7 the strongly evidenced ones"},
          employees: %{type: "string", description: "Employee band: 1-10, 11-50, 51-500, 501-5000, 5001+"},
          hiring: %{type: "string", description: "'true' to keep only companies with open jobs"},
          shopify: %{type: "string", description: "'true' to keep only Shopify stores"},
          has_named_email: %{type: "string", description: "'true' to keep only companies with a person's address on their domain"},
          first_seen_after: %{type: "string", description: "ISO date; first seen in certificate logs on or after it"},
          last_checked_after: %{type: "string", description: "ISO date; checked on or after it"},
          sort: %{type: "string", description: "relevance (default: the target ranking, small real businesses first), tranco, first_seen, last_checked, products, jobs"},
          limit: %{type: "integer", description: "1-100, default 25"},
          offset: %{type: "integer", description: "For paging, default 0"}
        }
      }
    },
    %{
      name: "listsignal_changes",
      description:
        "The change feed, newest first: what moved on which company and when. A technology, plugin or app added or removed (field http_tech), hiring started or stopped (hr_job_count), a revenue or employee band that changed (estimated_revenue, estimated_employees), a website that went down or came back (http_status), a store's catalogue, theme or currency that changed (shop_product_count, shop_theme, shop_currency), an email found for the first time (http_emails). Filters combine with AND; the period defaults to the last 7 days. Use for 'which SaaS companies in Germany started hiring this week', 'who added Klaviyo in the last 30 days', 'what changed at gymshark.com'.",
      inputSchema: %{
        type: "object",
        properties: %{
          field: %{type: "string", description: "What moved, e.g. http_tech, hr_job_count, estimated_revenue, estimated_employees, http_status, shop_product_count, shop_theme, http_emails, estimated_business_model"},
          change: %{type: "string", description: "Which way: added, removed, changed, started, stopped, down, back"},
          value: %{type: "string", description: "The value that was added or removed, e.g. Klaviyo, Shopify, HubSpot"},
          domain: %{type: "string", description: "One company's bare domain, to list its changes"},
          country: %{type: "string", description: "ISO-2 country code of the company, e.g. US"},
          business_model: %{type: "string", description: "Ecommerce, SaaS, Agency, Marketplace, Tool, Media, Consulting, LocalBusiness"},
          period: %{type: "string", description: "7d (default), 30d or 90d"},
          limit: %{type: "integer", description: "1-100, default 50"},
          offset: %{type: "integer", description: "For paging, default 0"}
        }
      }
    },
    %{
      name: "listsignal_query",
      description:
        "One bounded read over the whole dataset for analysis: the same filters as search (several countries, models or bands as comma-separated lists; has_named_email, has_email, first_seen_after, last_checked_after), a sort (relevance, tranco, first_seen, last_checked, products, jobs), a fields list, an optional group_by with counts (estimated_business_model, estimated_country, estimated_revenue, estimated_employees, estimated_industry, dns_email_provider, ctl_tld), and the total count of matching companies. Up to 500 rows per call, ten seconds of execution. Use for 'how many US Shopify stores have a named email, by revenue band' or 'the 300 newest French SaaS companies with their technologies'.",
      inputSchema: %{
        type: "object",
        properties: %{
          tech: %{type: "string", description: "One technology, plugin or app name as it appears in http_tech"},
          dns_tech: %{type: "string", description: "A vendor visible in DNS"},
          email_provider: %{type: "string", description: "Mailbox provider: Google Workspace, Microsoft 365, Zoho Mail, Proton Mail"},
          country: %{type: "string", description: "ISO-2 codes, comma-separated, e.g. US,CA"},
          business_model: %{type: "string", description: "Comma-separated: Ecommerce, SaaS, Agency, Marketplace, Tool, Media, Consulting, LocalBusiness"},
          industry: %{type: "string", description: "Industry label"},
          revenue: %{type: "string", description: "Comma-separated bands: <$1M, $1M-$10M, $10M-$100M, $100M-$1B, $1B+"},
          employees: %{type: "string", description: "Comma-separated bands: 1-10, 11-50, 51-500, 501-5000, 5001+"},
          hiring: %{type: "string", description: "'true' to keep only companies with open jobs"},
          shopify: %{type: "string", description: "'true' to keep only Shopify stores"},
          has_email: %{type: "string", description: "'true' to keep only companies with a published address"},
          has_named_email: %{type: "string", description: "'true' to keep only companies with a person's address on their domain (not info@, hello@...)"},
          min_realness: %{type: "string", description: "Minimum estimated_realness, 0 to 1"},
          first_seen_after: %{type: "string", description: "ISO date; companies first seen in certificate logs on or after it"},
          last_checked_after: %{type: "string", description: "ISO date; companies checked on or after it"},
          sort: %{type: "string", description: "relevance (default), tranco, first_seen, last_checked, products, jobs"},
          fields: %{type: "string", description: "Comma-separated columns to return, from the search columns; domain is always included"},
          group_by: %{type: "string", description: "One of estimated_business_model, estimated_country, estimated_revenue, estimated_employees, estimated_industry, dns_email_provider, ctl_tld; returns the top 50 values with counts"},
          limit: %{type: "integer", description: "0-500, default 100; 0 returns only the total and groups"},
          offset: %{type: "integer", description: "For paging, default 0"}
        }
      }
    },
    %{
      name: "listsignal_dataset_stats",
      description:
        "Live statistics about the ListSignal dataset: total businesses tracked, Shopify stores, technologies, and domains checked in the past hour. Use to size the dataset or cite fresh numbers.",
      inputSchema: %{type: "object", properties: %{}}
    }
  ]

  def handle(conn, params) do
    case params do
      %{"method" => method} = req ->
        respond(conn, req["id"], method, req["params"] || %{})

      _ ->
        rpc_error(conn, nil, -32600, "Invalid Request: expected a JSON-RPC 2.0 message with a 'method'.")
    end
  end

  # MCP clients GET the endpoint to open an SSE stream; stateless servers may
  # decline it, and clients then fall back to plain request/response.
  def reject_get(conn, _params) do
    conn |> put_status(405) |> json(%{error: "SSE not offered; POST JSON-RPC messages to this endpoint."})
  end

  defp respond(conn, id, "initialize", _params) do
    track(conn, "mcp_initialize")

    result(conn, id, %{
      protocolVersion: @protocol_version,
      capabilities: %{tools: %{}},
      serverInfo: %{name: "listsignal", title: "ListSignal", version: "1.0.0"},
      instructions:
        "ListSignal is live business intelligence for 14M+ online businesses. Use listsignal_search_companies to build filtered company lists, listsignal_get_company for one company's full profile, and listsignal_dataset_stats for dataset numbers. Contact emails require a paid plan."
    })
  end

  defp respond(conn, id, "tools/list", _params), do: result(conn, id, %{tools: @tools})

  defp respond(conn, id, "tools/call", %{"name" => name} = params) do
    args = params["arguments"] || %{}

    case call_tool(name, args, conn.assigns.api_plan) do
      {:ok, payload} ->
        track(conn, "mcp_" <> name)
        LS.ApiKeys.record_usage_async(conn.assigns.api_key.id)

        LS.ApiAudit.log_async(%{
          user_id: conn.assigns.api_user.id,
          email: conn.assigns.api_user.email,
          plan: conn.assigns.api_plan,
          key_prefix: conn.assigns.api_key.prefix,
          surface: "mcp",
          endpoint: name,
          target: args["domain"],
          filters: Map.drop(args, ["domain"]),
          result_count: payload[:count] || (if payload[:domain], do: 1, else: 0)
        })

        result(conn, id, %{
          content: [%{type: "text", text: Jason.encode!(payload)}],
          isError: false
        })

      {:tool_error, message} ->
        # Tool-level failures go in-band (isError) so the model can read
        # them and self-correct, per spec; protocol errors stay JSON-RPC.
        result(conn, id, %{content: [%{type: "text", text: message}], isError: true})
    end
  end

  defp respond(conn, id, "ping", _params), do: result(conn, id, %{})

  # Notifications (no id) get 202 + empty body per Streamable HTTP.
  defp respond(conn, nil, "notifications/" <> _, _params), do: send_resp(conn, 202, "")

  defp respond(conn, id, method, _params),
    do: rpc_error(conn, id, -32601, "Method not found: #{method}. This server implements initialize, tools/list, tools/call, and ping.")

  # ── tools ─────────────────────────────────────────────────────────────────

  defp call_tool("listsignal_get_company", %{"domain" => domain}, plan) when is_binary(domain) do
    case ApiData.company(domain) do
      nil ->
        {:tool_error,
         "Domain '#{String.slice(domain, 0, 100)}' is not in the dataset yet. New domains appear within hours of getting a TLS certificate. Check the spelling (bare domain, e.g. 'gymshark.com')."}

      record ->
        {:ok, gate(record, plan)}
    end
  end

  defp call_tool("listsignal_get_company", _args, _plan),
    do: {:tool_error, "Missing required argument 'domain' (bare domain, e.g. 'gymshark.com')."}

  defp call_tool("listsignal_search_companies", args, _plan) do
    case ApiData.search(args) do
      {:ok, rows, applied} ->
        {:ok, %{companies: rows, count: length(rows), limit: applied.limit, offset: applied.offset}}

      {:error, _} ->
        {:tool_error, "Search temporarily unavailable; retry with backoff."}
    end
  end

  # Added 2026-10-17: the signals were on the dashboard and in /api/v1/changes
  # but not here, so an agent asking "who started hiring this week" had no
  # tool for the one thing the product is named after.
  defp call_tool("listsignal_changes", args, _plan) do
    case ApiData.changes(args) do
      {:ok, rows, applied} ->
        {:ok, %{changes: rows, count: length(rows), limit: applied.limit, offset: applied.offset, period: applied.period}}

      {:error, _} ->
        {:tool_error, "Changes temporarily unavailable; retry with backoff."}
    end
  end

  defp call_tool("listsignal_dataset_stats", _args, _plan), do: {:ok, ApiData.stats()}

  # Analysis over the whole table (2026-10-26): totals, group counts, sort
  # and chosen fields, bounded in rows, threads and seconds. Emails are not
  # among the search columns, so the plan gate has nothing to hide here.
  defp call_tool("listsignal_query", args, _plan) do
    case ApiData.query(args) do
      {:ok, result} -> {:ok, result}
      {:error, _} -> {:tool_error, "Query failed or exceeded its ten-second budget; narrow the filters or drop group_by."}
    end
  end

  defp call_tool(name, _args, _plan),
    do: {:tool_error, "Unknown tool '#{name}'. Available: listsignal_get_company, listsignal_search_companies, listsignal_changes, listsignal_query, listsignal_dataset_stats."}

  @doc false
  def tools, do: @tools

  @doc false
  def gate(record, plan) when plan in ["starter", "pro"], do: record

  def gate(record, _free) do
    emails = record[:http_emails] || record[:emails] || []
    key = if Map.has_key?(record, :http_emails), do: :http_emails, else: :emails

    record
    |> Map.put(:email_count, length(emails))
    |> Map.put(key, "gated: contact emails require a paid plan (listsignal.com/pricing)")
    |> then(&if(Map.has_key?(&1, :http_phone), do: Map.put(&1, :http_phone, "gated"), else: &1))
  end

  # ── JSON-RPC plumbing ─────────────────────────────────────────────────────

  defp result(conn, id, result), do: json(conn, %{jsonrpc: "2.0", id: id, result: result})

  defp rpc_error(conn, id, code, message),
    do: json(conn, %{jsonrpc: "2.0", id: id, error: %{code: code, message: message}})

  defp track(conn, event), do: LS.Umami.track_async(event, %{plan: conn.assigns.api_plan})
end
