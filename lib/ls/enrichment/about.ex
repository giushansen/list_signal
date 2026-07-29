defmodule LS.Enrichment.About do
  @moduledoc """
  "Who is this company?" — mission statement, headquarters and hiring profile.

  Career pages are the richest public source of company self-description: they
  almost always link an *about / mission / our-story* page, and they list roles
  with locations. So the enrichment lane follows **one** link from the careers
  page (best candidate only) and reads it.

  ## Why not the ML classifier

  `LS.ML.Classifier` embeds text against fixed labels — perfect for "is this
  SaaS or Ecommerce", useless for "extract this company's mission", which is
  not a classification at all. Running sentence-transformers here would cost
  ~200ms per domain to answer a question it cannot answer.

  Instead: pick the sentences a human would (from the About page's leading
  prose, preferring ones with mission language), then let the *existing*
  classifier score industry from the same text when it is worth it. Cheap,
  explainable, and degrades to `nil` rather than to nonsense.

  Every step is best-effort: a missing About page, a redirect loop or a
  JS-only page yields empty fields, never an error.
  """

  require Logger

  alias LS.HTTP.{Client, TextExtractor}

  @timeout 8_000
  @about_link ~r/href=["']([^"']*\/(?:about|about-us|our-story|who-we-are|mission|company|team)[^"']*)["']/i
  # Sentences that read like a mission statement rather than boilerplate.
  @mission_cue ~r/\b(we|our)\b.{0,40}\b(mission|believe|help|build|empower|enable|exist|founded|create)\b/i
  @hq_cue ~r/(?:headquarter(?:s|ed)?|based in|hq)[^.\n]{0,60}/i

  @empty %{about_text: "", mission: "", hq_location: "", job_locations_top: "", positions_overview: ""}

  @doc """
  Extract company profile from the careers page (and one About page it links).

  `jobs` is the list from `LS.Enrichment.Jobs` — used for the location and
  position overview, so no extra fetch is needed for those.
  """
  @spec analyze(String.t(), String.t() | nil, [map()], String.t() | nil) :: map()
  def analyze(domain, careers_html, jobs \\ [], ip \\ nil) do
    about_html = fetch_about(domain, careers_html, ip)
    text = visible_text(about_html) || visible_text(careers_html) || ""

    %{
      about_text: String.slice(text, 0, 1000),
      mission: mission(text),
      hq_location: hq(text, jobs),
      job_locations_top: top_locations(jobs),
      positions_overview: positions(jobs)
    }
  rescue
    e ->
      Logger.debug("[ABOUT] #{domain} failed: #{Exception.message(e)}")
      @empty
  end

  # ── fetching ───────────────────────────────────────────────────────────────

  # One link, one fetch. Follows the same politeness path as every other
  # request; returns nil on anything unexpected.
  defp fetch_about(domain, careers_html, ip) when is_binary(careers_html) do
    with [path | _] <- Regex.run(@about_link, careers_html, capture: :all_but_first),
         path <- normalise(path, domain),
         {:ok, %{status: s, body: body}} when s in 200..399 <-
           Client.fetch(domain, ip, path: path, timeout: @timeout) do
      body
    else
      _ -> nil
    end
  end

  defp fetch_about(_, _, _), do: nil

  # Keep it on the same host: an About link pointing at a parent corporate site
  # would describe a different company.
  defp normalise(path, domain) do
    cond do
      String.starts_with?(path, "/") -> path
      String.contains?(path, domain) -> "/" <> (path |> String.split(domain) |> List.last() |> String.trim_leading("/"))
      String.starts_with?(path, "http") -> "/"
      true -> "/" <> path
    end
  end

  defp visible_text(nil), do: nil
  defp visible_text(html) when is_binary(html) do
    case TextExtractor.extract_visible_text(html, 4000) do
      t when is_binary(t) and byte_size(t) > 80 -> t
      _ -> nil
    end
  end

  # ── extraction ─────────────────────────────────────────────────────────────

  # First sentence that talks about the company in mission terms; falls back to
  # the opening sentence, which on an About page is usually the elevator pitch.
  defp mission(""), do: ""
  defp mission(text) do
    sentences =
      text
      |> String.split(~r/(?<=[.!?])\s+/, trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&(String.length(&1) in 40..300))

    (Enum.find(sentences, &Regex.match?(@mission_cue, &1)) || List.first(sentences) || "")
    |> String.slice(0, 300)
  end

  # Prefer an explicit "headquartered in ..." phrase; otherwise the most common
  # job location, which is a good proxy for where the company actually is.
  defp hq(text, jobs) do
    case Regex.run(@hq_cue, text) do
      [phrase | _] -> phrase |> String.trim() |> String.slice(0, 120)
      _ -> jobs |> Enum.map(& &1[:location]) |> most_common() || ""
    end
  end

  defp top_locations(jobs) do
    jobs
    |> Enum.map(& &1[:location])
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_, n} -> -n end)
    |> Enum.take(5)
    |> Enum.map_join("|", fn {loc, n} -> "#{loc}:#{n}" end)
  end

  # "Engineering:12|Sales:4 (18 open)" — one glanceable string describing what
  # the company is currently building out.
  defp positions(jobs) when jobs == [], do: ""
  defp positions(jobs) do
    top =
      jobs
      |> Enum.map(&seniority/1)
      |> Enum.frequencies()
      |> Enum.sort_by(fn {_, n} -> -n end)
      |> Enum.take(4)
      |> Enum.map_join("|", fn {k, n} -> "#{k}:#{n}" end)

    "#{top} (#{length(jobs)} open)"
  end

  defp seniority(%{title: t}) do
    d = String.downcase(t)

    cond do
      d =~ ~r/\b(chief|cto|ceo|cfo|coo|vp|head of|director)\b/ -> "Leadership"
      d =~ ~r/\b(principal|staff|lead|manager)\b/ -> "Senior+"
      d =~ ~r/\b(senior|sr\.?)\b/ -> "Senior"
      d =~ ~r/\b(junior|jr\.?|intern|graduate|entry)\b/ -> "Junior"
      true -> "Mid"
    end
  end

  defp most_common([]), do: nil
  defp most_common(values) do
    values
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.frequencies()
    |> Enum.max_by(fn {_, n} -> n end, fn -> {nil, 0} end)
    |> elem(0)
  end
end
