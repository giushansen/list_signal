defmodule LS.ApiData do
  @moduledoc """
  Read-only queries behind `/api/v1` and `/mcp`.

  Named columns only (never `SELECT *`: the 2026-07 enrichment cutover
  proved schema drift silently breaks star-selects), page sizes hard-capped
  server-side, and every user-supplied value escaped. Contact emails are
  returned to the caller-facing layer, which decides per-plan whether to
  expose them, so the gating rule lives in one place (`LSWeb.ApiV1JSON`).
  """

  alias LS.Clickhouse

  @max_page 100

  @doc "Full company record for one domain, or nil."
  def company(domain) when is_binary(domain) do
    d = domain |> String.trim() |> String.downcase() |> Clickhouse.escape_public()

    sql = """
    SELECT domain, http_title, business_model, industry, inferred_country,
           estimated_revenue, estimated_employees, http_tech, http_apps,
           product_count, price_avg, job_count, positions_overview,
           seo_score, tranco_rank, http_emails, is_junk,
           toString(as_of) AS as_of
    FROM businesses FINAL
    WHERE domain = '#{d}'
    LIMIT 1
    """

    case Clickhouse.query_raw(sql) do
      {:ok, [row]} -> to_company(row)
      _ -> nil
    end
  end

  @doc """
  Filtered company search. `filters` accepts string keys straight from
  params: tech, app, country (ISO-2), business_model, revenue,
  hiring ("true"), limit, offset. Returns `{rows, applied_filters}` so the
  response can echo what was actually honoured (agents self-correct off it).
  """
  def search(filters) when is_map(filters) do
    conds =
      [
        like("http_tech", filters["tech"]),
        like("http_apps", filters["app"]),
        eq("inferred_country", upcase(filters["country"])),
        eq("business_model", filters["business_model"]),
        eq("estimated_revenue", filters["revenue"]),
        if(filters["hiring"] in ["true", "1", true], do: "job_count > 0"),
        "http_title != ''",
        "is_junk = ''"
      ]
      |> Enum.reject(&is_nil/1)

    limit = filters |> int("limit", 25) |> min(@max_page) |> max(1)
    offset = filters |> int("offset", 0) |> max(0) |> min(10_000)

    sql = """
    SELECT domain, http_title, business_model, industry, inferred_country,
           estimated_revenue, http_tech, job_count, seo_score, tranco_rank,
           http_emails != '' AS has_contact
    FROM businesses FINAL
    WHERE #{Enum.join(conds, " AND ")}
    ORDER BY tranco_rank ASC NULLS LAST
    LIMIT #{limit} OFFSET #{offset}
    """

    case Clickhouse.query_raw(sql, 30_000) do
      {:ok, rows} -> {:ok, Enum.map(rows, &to_search_row/1), %{limit: limit, offset: offset}}
      {:error, e} -> {:error, e}
    end
  end

  @doc "Technology directory with usage counts (cached upstream)."
  def technologies do
    LS.LandingCache.tech_names()
    |> Enum.map(fn {name, count} -> %{name: name, companies: count} end)
  end

  @doc "Live dataset statistics from the 60s-refresh landing cache. Free."
  def stats do
    l = LS.LandingCache.get()

    %{
      # businesses_tracked is the PRODUCT table count (reachable, enriched
      # businesses), not domains-ever-seen. An agent will cite these numbers;
      # they must be the ones a customer can verify in the app.
      businesses_tracked: l.business_count,
      domains_scanned: l.total_domains,
      shopify_stores: l.store_count,
      # tech_count's uniq-over-171M-rows query can time out right after boot
      # and report 0, which would contradict /technologies; the directory
      # list is the same universe and always warm.
      technologies: max(l.tech_count, length(LS.LandingCache.tech_names())),
      shopify_apps: l.app_count,
      domains_checked_past_hour: l.stores_last_hour,
      refreshed_at: l.refreshed_at
    }
  end

  # ── row shaping ───────────────────────────────────────────────────────────

  defp to_company([
         domain, title, model, industry, country, revenue, employees, tech, apps,
         products, price_avg, jobs, positions, seo, rank, emails, is_junk, as_of
       ]) do
    %{
      domain: domain,
      title: title,
      business_model: model,
      industry: industry,
      country: country,
      estimated_revenue: revenue,
      estimated_employees: employees,
      technologies: split(tech),
      shopify_apps: split(apps),
      product_count: num(products),
      price_avg: num(price_avg),
      open_jobs: num(jobs),
      hiring_overview: positions,
      seo_score: num(seo),
      traffic_rank: num(rank),
      emails: split(emails),
      is_junk: is_junk != "",
      last_checked: as_of
    }
  end

  defp to_company(_), do: nil

  defp to_search_row([domain, title, model, industry, country, revenue, tech, jobs, seo, rank, has_contact]) do
    %{
      domain: domain,
      title: title,
      business_model: model,
      industry: industry,
      country: country,
      estimated_revenue: revenue,
      technologies: split(tech),
      open_jobs: num(jobs),
      seo_score: num(seo),
      traffic_rank: num(rank),
      has_contact: has_contact in [1, "1", true]
    }
  end

  defp like(_col, nil), do: nil
  defp like(_col, ""), do: nil
  defp like(col, v), do: "positionCaseInsensitive(#{col}, '#{Clickhouse.escape_public(v)}') > 0"

  defp eq(_col, nil), do: nil
  defp eq(_col, ""), do: nil
  defp eq(col, v), do: "#{col} = '#{Clickhouse.escape_public(v)}'"

  defp upcase(nil), do: nil
  defp upcase(v) when is_binary(v), do: String.upcase(v)

  defp int(filters, key, default) do
    case Integer.parse(to_string(filters[key] || default)) do
      {n, _} -> n
      _ -> default
    end
  end

  defp split(nil), do: []
  defp split(""), do: []
  defp split(s) when is_binary(s), do: s |> String.split("|", trim: true)

  defp num(nil), do: nil
  defp num(n) when is_number(n), do: n

  defp num(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ ->
        case Float.parse(s) do
          {f, ""} -> f
          _ -> nil
        end
    end
  end
end
