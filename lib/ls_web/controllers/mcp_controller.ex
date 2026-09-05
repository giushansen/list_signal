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
        "Get everything ListSignal knows about one company by its website domain: technologies used, Shopify apps, estimated revenue and employees, open jobs with hiring breakdown, SEO score, traffic rank, and contact emails (paid plans). Use when the user asks about a specific company or website.",
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
        "Find companies by technology, Shopify app, country, business model, revenue bracket, or hiring status. Filters combine with AND. Returns up to 100 ranked companies per call (use offset to page). Use for questions like 'find SaaS companies in France using HubSpot that are hiring'.",
      inputSchema: %{
        type: "object",
        properties: %{
          tech: %{type: "string", description: "Technology name, e.g. Shopify, Klaviyo, HubSpot"},
          app: %{type: "string", description: "Shopify app name, e.g. ReCharge"},
          country: %{type: "string", description: "ISO-2 country code, e.g. US, FR"},
          business_model: %{
            type: "string",
            description: "Ecommerce, SaaS, Agency, Marketplace, Tool, Media, or Consulting"
          },
          revenue: %{type: "string", description: "Revenue bracket, e.g. $1M-$10M"},
          hiring: %{type: "string", description: "'true' to keep only companies with open jobs"},
          limit: %{type: "integer", description: "1-100, default 25"},
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

  defp call_tool("listsignal_dataset_stats", _args, _plan), do: {:ok, ApiData.stats()}

  defp call_tool(name, _args, _plan),
    do: {:tool_error, "Unknown tool '#{name}'. Available: listsignal_get_company, listsignal_search_companies, listsignal_dataset_stats."}

  @doc false
  def gate(record, plan) when plan in ["starter", "pro"], do: record

  def gate(record, _free) do
    record
    |> Map.put(:email_count, length(record.emails))
    |> Map.put(:emails, "gated: contact emails require a paid plan (listsignal.com/pricing)")
  end

  # ── JSON-RPC plumbing ─────────────────────────────────────────────────────

  defp result(conn, id, result), do: json(conn, %{jsonrpc: "2.0", id: id, result: result})

  defp rpc_error(conn, id, code, message),
    do: json(conn, %{jsonrpc: "2.0", id: id, error: %{code: code, message: message}})

  defp track(conn, event), do: LS.Umami.track_async(event, %{plan: conn.assigns.api_plan})
end
