defmodule LSWeb.TechController do
  @moduledoc "SEO pages: stores using a given technology (`/tech/:slug`)."
  use LSWeb, :controller
  plug :cache_headers

  def show(conn, %{"slug" => slug}) do
    # Resolve against the real http_tech values first; naive capitalisation breaks
    # every non-Title-Case tech ("vue-js" -> "Vue Js" never matches "Vue.js").
    tech_name =
      LS.Clickhouse.canonical_tech_name(slug) ||
        (slug |> String.split("-") |> Enum.map(&String.capitalize/1) |> Enum.join(" "))

    search_term = slug |> String.replace("-", " ")

    # One cache entry per tech, 6h. The assembly below runs SEVEN full scans
    # of a 118M-row table (a 9s store query plus six distributions) — fine
    # once, fatal per crawler hit: post-mutation cold caches took every
    # /tech/* page past the origin timeout and Google saw dead pages. A
    # public SEO page whose data drifts daily must never recompute per view.
    %{
      stores: stores, store_count: store_count, actual_name: actual_name,
      stats: stats, countries: countries, languages: languages,
      hosting: hosting, registrars: registrars, co_techs: co_techs
    } =
      LS.UICache.fetch(:tech_page, tech_name, fn ->
        assemble_tech_page(tech_name, search_term)
      end)

    conn
    |> assign(:page_title, tech_page_title(actual_name, stats.total))
    |> assign(:page_description, tech_page_description(actual_name, stats.total))
    |> assign(:tech_name, actual_name)
    |> assign(:slug, slug)
    |> assign(:stores, stores)
    |> assign(:store_count, store_count)
    |> assign(:stats, stats)
    |> assign(:countries, countries)
    |> assign(:languages, languages)
    |> assign(:hosting, hosting)
    |> assign(:registrars, registrars)
    |> assign(:co_techs, co_techs)
    |> assign(:json_ld, tech_json_ld(actual_name, stats))
    |> put_layout(html: {LSWeb.Layouts, :public})
    |> render(:show)
  end


  defp assemble_tech_page(tech_name, search_term) do
    {stores, store_count, actual_name} = case LS.Clickhouse.stores_by_tech_full(tech_name, 100) do
      {:ok, rows} when rows != [] ->
        parsed = Enum.map(rows, &parse_full_row/1)
        {parsed, length(parsed), tech_name}
      _ ->
        case LS.Clickhouse.stores_by_tech_full_ilike(search_term, 100) do
          {:ok, rows} when rows != [] ->
            parsed = Enum.map(rows, &parse_full_row/1)
            {parsed, length(parsed), tech_name}
          _ -> {[], 0, tech_name}
        end
    end

    # These 6 ClickHouse queries are independent, so run them concurrently.
    # On high-volume techs each query scans many rows; sequentially this was the
    # dominant page cost (~0.8s). In parallel the page waits on the slowest one only.
    [countries_r, languages_r, hosting_r, registrars_r, co_techs_r, stats_r] =
      [
        fn -> LS.Clickhouse.tech_country_distribution(actual_name) end,
        fn -> LS.Clickhouse.tech_language_distribution(actual_name) end,
        fn -> LS.Clickhouse.tech_hosting_distribution(actual_name) end,
        fn -> LS.Clickhouse.tech_registrar_distribution(actual_name) end,
        fn -> LS.Clickhouse.tech_co_occurring(actual_name) end,
        fn -> LS.Clickhouse.tech_stats(actual_name) end
      ]
      |> Task.async_stream(& &1.(), max_concurrency: 6, timeout: 15_000, on_timeout: :kill_task)
      |> Enum.map(fn
        {:ok, result} -> result
        _ -> {:error, :unavailable}
      end)

    countries = case countries_r do
      {:ok, rows} -> Enum.map(rows, fn [c, cnt] -> %{country: c, flag: country_to_flag(c), count: cnt} end)
      _ -> []
    end

    languages = case languages_r do
      {:ok, rows} -> Enum.map(rows, fn [l, cnt] -> %{language: l, flag: language_to_flag(l), count: cnt} end)
      _ -> []
    end

    hosting = case hosting_r do
      {:ok, rows} -> Enum.map(rows, fn [h, cnt] -> %{provider: h, count: cnt} end)
      _ -> []
    end

    registrars = case registrars_r do
      {:ok, rows} -> Enum.map(rows, fn [r, cnt] -> %{registrar: r, count: cnt} end)
      _ -> []
    end

    co_techs = case co_techs_r do
      {:ok, rows} -> Enum.map(rows, fn [t, cnt] -> %{tech: t, count: cnt} end)
      _ -> []
    end

    stats = build_stats(stats_r)

    %{
      stores: stores, store_count: store_count, actual_name: actual_name,
      stats: stats, countries: countries, languages: languages,
      hosting: hosting, registrars: registrars, co_techs: co_techs
    }
  end

  @unknown_stats %{total: nil, avg_response_time: nil, responding_count: nil, top_100k_count: nil}

  @doc """
  Map the `tech_stats` aggregate onto the page's stats map.

  `nil` means "we could not measure this", NOT zero. The previous fallback
  substituted the 100-row listing cap for `total` and literal 0s for the counts,
  which is how /tech/google-analytics ended up advertising "100+ stores using
  Google Analytics, 0 online" for a tech with ~1.5M matching rows. Every consumer
  renders nothing rather than inventing a number.
  """
  def build_stats({:ok, [[total, avg_rt, responding, top100k]]}) do
    %{
      total: total,
      avg_response_time: avg_rt,
      responding_count: responding,
      top_100k_count: top100k
    }
  end

  def build_stats(_unavailable), do: @unknown_stats

  defp tech_page_title(name, nil), do: "#{name} — Shopify Stores Using #{name}"
  defp tech_page_title(name, total), do: "#{name} — #{format_count(total)} Stores Using #{name}"

  defp tech_page_description(name, nil) do
    "See which Shopify stores use #{name}, plus country distribution, hosting providers, " <>
      "and technology insights — only on ListSignal."
  end

  defp tech_page_description(name, total) do
    "#{format_count(total)} Shopify stores use #{name}. See who uses #{name}, country distribution, " <>
      "hosting providers, and technology insights — only on ListSignal."
  end

  @doc "Thousands-separated integer. Exposed for the template and its tests."
  def format_count(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  def format_count(n) when is_float(n), do: format_count(round(n))
  def format_count(_), do: nil

  defp parse_full_row(row) do
    country = Enum.at(row, 3) || ""
    mx = Enum.at(row, 11) || ""
    created = Enum.at(row, 8)
    %{
      domain: Enum.at(row, 0) || "",
      title: Enum.at(row, 1) || "",
      tech: Enum.at(row, 2) || "",
      country: country,
      country_flag: country_to_flag(country),
      tranco_rank: Enum.at(row, 4),
      response_time: Enum.at(row, 5),
      language: Enum.at(row, 6) || "",
      language_flag: language_to_flag(Enum.at(row, 6) || ""),
      registrar: Enum.at(row, 7) || "",
      created_at: created,
      domain_age: compute_domain_age(created),
      http_status: Enum.at(row, 9),
      hosting: Enum.at(row, 10) || "",
      mail_provider: extract_mail_provider(mx),
      emails: (Enum.at(row, 12) || "") |> String.split("|") |> Enum.reject(&(&1 == "")),
      majestic_rank: Enum.at(row, 13)
    }
  end

  defp extract_mail_provider(""), do: nil
  defp extract_mail_provider(mx_str) do
    primary = mx_str |> String.split("|") |> List.first("") |> String.downcase()
    Enum.find_value(mail_providers(), fn {pattern, name} ->
      if String.contains?(primary, pattern), do: name
    end)
  end

  defp mail_providers do
    %{
      "google" => "Google Workspace", "outlook" => "Microsoft 365",
      "zoho" => "Zoho Mail", "protonmail" => "ProtonMail",
      "icloud" => "Apple iCloud", "yandex" => "Yandex Mail",
      "fastmail" => "Fastmail", "shopify" => "Shopify Mail",
      "secureserver" => "GoDaddy", "titan" => "Titan Email",
      "mailgun" => "Mailgun", "sendgrid" => "SendGrid",
      "mimecast" => "Mimecast", "pphosted" => "Proofpoint"
    }
  end

  defp compute_domain_age(nil), do: nil
  defp compute_domain_age(created_at) when is_binary(created_at) do
    case Date.from_iso8601(String.slice(created_at, 0, 10)) do
      {:ok, date} ->
        days = Date.diff(Date.utc_today(), date)
        cond do
          days < 30 -> "#{days}d"
          days < 365 -> "#{div(days, 30)}m"
          true -> "#{div(days, 365)}y"
        end
      _ -> nil
    end
  end
  defp compute_domain_age(_), do: nil

  defp country_to_flag(""), do: ""
  defp country_to_flag(code) when byte_size(code) == 2 do
    code |> String.upcase() |> String.to_charlist()
    |> Enum.map(&(&1 + 0x1F1A5)) |> List.to_string()
  rescue
    _ -> ""
  end
  defp country_to_flag(_), do: ""

  @lang_flags %{
    "en" => "\u{1F1EC}\u{1F1E7}", "fr" => "\u{1F1EB}\u{1F1F7}", "de" => "\u{1F1E9}\u{1F1EA}",
    "es" => "\u{1F1EA}\u{1F1F8}", "pt" => "\u{1F1E7}\u{1F1F7}", "it" => "\u{1F1EE}\u{1F1F9}",
    "nl" => "\u{1F1F3}\u{1F1F1}", "ja" => "\u{1F1EF}\u{1F1F5}", "ko" => "\u{1F1F0}\u{1F1F7}",
    "zh" => "\u{1F1E8}\u{1F1F3}", "ru" => "\u{1F1F7}\u{1F1FA}", "ar" => "\u{1F1F8}\u{1F1E6}",
    "sv" => "\u{1F1F8}\u{1F1EA}", "da" => "\u{1F1E9}\u{1F1F0}", "no" => "\u{1F1F3}\u{1F1F4}",
    "fi" => "\u{1F1EB}\u{1F1EE}", "tr" => "\u{1F1F9}\u{1F1F7}", "pl" => "\u{1F1F5}\u{1F1F1}"
  }

  defp language_to_flag(""), do: ""
  defp language_to_flag(nil), do: ""
  defp language_to_flag(lang) do
    code = lang |> String.downcase() |> String.slice(0, 2)
    Map.get(@lang_flags, code, "")
  end

  defp cache_headers(conn, _opts) do
    conn
    |> put_resp_header("cache-control", "public, s-maxage=86400, max-age=3600, stale-while-revalidate=3600")
    |> put_resp_header("vary", "Accept-Encoding")
  end

  defp tech_json_ld(name, %{total: nil}) do
    Jason.encode!(%{
      "@context" => "https://schema.org",
      "@type" => "SoftwareApplication",
      "name" => name,
      "applicationCategory" => "BusinessApplication",
      "description" => "#{name} usage across Shopify stores tracked by ListSignal."
    })
  end

  defp tech_json_ld(name, stats) do
    Jason.encode!(%{
      "@context" => "https://schema.org",
      "@type" => "SoftwareApplication",
      "name" => name,
      "applicationCategory" => "BusinessApplication",
      "description" => "#{name} is used by #{format_count(stats.total)} Shopify stores tracked by ListSignal.",
      "aggregateRating" => %{
        "@type" => "AggregateRating",
        "ratingCount" => stats.total,
        "bestRating" => "5"
      }
    })
  end
end
