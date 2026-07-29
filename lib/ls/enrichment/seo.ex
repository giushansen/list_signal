defmodule LS.Enrichment.SEO do
  @moduledoc """
  On-page SEO audit and 0-100 score, computed from HTML we already fetched.

  Two inputs, both optional:

    * the page HTML — content/meta checks (title, description, H1, canonical,
      JSON-LD, Open Graph, image alt coverage, word count, links, robots)
    * `perf` from the browser sidecar — real Core Web Vitals when camoufox
      rendered the page (`%{lcp_ms:, cls:, ttfb_ms:}`); omitted for plain HTTP

  The score is deliberately simple and auditable: each check contributes a
  fixed weight, `seo_issues` lists every failed check by name. Customers get a
  number they can sort on *and* the reason behind it — a black-box score
  nobody can explain is not sellable.
  """

  @doc """
  Audit a page. Returns SEO columns ready to merge into a `businesses` row.

  `seo_score` is 0-100 over the checks that could be evaluated, so a page
  without performance data is not punished for lacking it.
  """
  @spec audit(String.t() | nil, map()) :: map()
  def audit(html, perf \\ %{})

  def audit(html, perf) when is_binary(html) and html != "" do
    checks = content_checks(html) ++ perf_checks(perf)

    earned = checks |> Enum.filter(&elem(&1, 1)) |> Enum.map(&elem(&1, 2)) |> Enum.sum()
    possible = checks |> Enum.map(&elem(&1, 2)) |> Enum.sum()
    failed = checks |> Enum.reject(&elem(&1, 1)) |> Enum.map(&elem(&1, 0))

    %{
      seo_score: if(possible > 0, do: round(earned / possible * 100), else: nil),
      seo_issues: Enum.join(failed, "|"),
      seo_word_count: word_count(html),
      seo_alt_ratio: alt_ratio(html),
      perf_lcp_ms: perf[:lcp_ms],
      perf_cls: perf[:cls],
      perf_ttfb_ms: perf[:ttfb_ms]
    }
  end

  def audit(_, _), do: %{seo_score: nil, seo_issues: "", seo_word_count: nil,
                         seo_alt_ratio: nil, perf_lcp_ms: nil,
                         perf_cls: nil, perf_ttfb_ms: nil}

  # ── checks: {name, passed?, weight} ────────────────────────────────────────

  defp content_checks(html) do
    title = capture(html, ~r/<title[^>]*>(.*?)<\/title>/is)
    desc = capture(html, ~r/<meta[^>]+name=["']description["'][^>]+content=["']([^"']*)/i)
    words = word_count(html)

    [
      {"title_missing", present?(title), 12},
      # 10-60 chars is the range that renders without truncation in results.
      {"title_length", len_between(title, 10, 60), 6},
      {"meta_description_missing", present?(desc), 10},
      {"meta_description_length", len_between(desc, 50, 160), 5},
      {"h1_missing", has?(html, ~r/<h1[\s>]/i), 10},
      {"h1_multiple", count_all(html, ~r/<h1[\s>]/i) <= 1, 4},
      {"canonical_missing", has?(html, ~r/rel=["']canonical["']/i), 8},
      {"structured_data_missing", has?(html, ~r/application\/ld\+json/i), 10},
      {"og_tags_missing", has?(html, ~r/property=["']og:/i), 8},
      {"twitter_card_missing", has?(html, ~r/name=["']twitter:/i), 3},
      {"viewport_missing", has?(html, ~r/name=["']viewport["']/i), 6},
      {"lang_missing", has?(html, ~r/<html[^>]+lang=/i), 4},
      {"alt_text_coverage", (alt_ratio(html) || 1.0) >= 0.8, 6},
      {"thin_content", words >= 300, 8},
      {"robots_noindex", not has?(html, ~r/name=["']robots["'][^>]+noindex/i), 10}
    ]
  end

  # Thresholds are Google's "good" Core Web Vitals bands.
  defp perf_checks(%{lcp_ms: lcp} = perf) when is_number(lcp) do
    [
      {"lcp_slow", lcp <= 2500, 10},
      {"cls_high", (perf[:cls] || 0) <= 0.1, 5},
      {"ttfb_slow", (perf[:ttfb_ms] || 0) <= 800, 5}
    ]
  end

  defp perf_checks(_), do: []

  # ── helpers ────────────────────────────────────────────────────────────────

  defp capture(html, re) do
    case Regex.run(re, html, capture: :all_but_first) do
      [v | _] -> String.trim(v)
      _ -> nil
    end
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_), do: true

  defp len_between(nil, _, _), do: false
  defp len_between(s, lo, hi), do: String.length(s) >= lo and String.length(s) <= hi

  defp has?(html, re), do: Regex.match?(re, html)

  defp count_all(html, re), do: Regex.scan(re, html) |> length()

  defp alt_ratio(html) do
    imgs = count_all(html, ~r/<img[\s>]/i)
    if imgs == 0, do: nil, else: Float.round(count_all(html, ~r/<img[^>]+alt=["'][^"']+/i) / imgs, 3)
  end

  defp word_count(html) do
    html
    |> String.replace(~r/<(script|style)[^>]*>.*?<\/\1>/is, " ")
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.split(~r/\s+/, trim: true)
    |> length()
  end
end
