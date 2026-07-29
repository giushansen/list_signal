defmodule LS.Enrichment.Jobs do
  @moduledoc """
  Hiring intelligence: open roles, departments, locations and the ATS in use.

  Most companies delegate their careers page to an applicant-tracking system,
  and the big ATSes publish **public JSON job boards**. When we can identify
  the ATS we read that API — structured, complete, one request, no browser.
  Only when there is no recognisable ATS do we fall back to scraping links out
  of the careers page HTML (browser-rendered if the sidecar supplied it).

  Why this data sells: `job_count` and its 30-day delta are the best public
  proxy for company growth (and indirectly for fundraising), and the roles
  themselves name a tech stack that no HTML-fingerprint product can see.

  Returns `{summary_map, [job, ...]}` — the summary becomes columns on
  `businesses`, the list becomes rows in `biz_career`.
  """

  require Logger

  alias LS.HTTP.Client

  @timeout 12_000

  # ATS board URL patterns. `{name, url_builder, parser}`; the slug is captured
  # from any link on the careers page pointing at that ATS.
  @ats [
    {"greenhouse", ~r{boards\.greenhouse\.io/([a-z0-9_-]+)}i,
     &__MODULE__.greenhouse_url/1, :greenhouse},
    {"lever", ~r{jobs\.lever\.co/([a-z0-9_-]+)}i, &__MODULE__.lever_url/1, :lever},
    {"ashby", ~r{jobs\.ashbyhq\.com/([a-z0-9_-]+)}i, &__MODULE__.ashby_url/1, :ashby}
  ]

  @empty_summary %{job_count: nil, ats_platform: "", job_departments: "", job_locations: ""}

  @doc """
  Analyse a company's hiring. `html` is the careers page (from HTTP or the
  browser sidecar). Never raises.
  """
  @spec analyze(String.t(), String.t() | nil, String.t() | nil) :: {map(), [map()]}
  def analyze(domain, careers_html, ip \\ nil) do
    case detect_ats(careers_html) do
      {name, url, kind} ->
        case fetch_json(url) do
          {:ok, payload} -> build(name, parse(kind, payload))
          :error -> {%{@empty_summary | ats_platform: name}, []}
        end

      nil ->
        build("", scrape_html(careers_html, domain, ip))
    end
  rescue
    e ->
      Logger.debug("[JOBS] #{domain} failed: #{Exception.message(e)}")
      {@empty_summary, []}
  end

  # Public so the @ats table can reference them as captures.
  @doc false
  def greenhouse_url(slug), do: "https://boards-api.greenhouse.io/v1/boards/#{slug}/jobs"
  @doc false
  def lever_url(slug), do: "https://api.lever.co/v0/postings/#{slug}?mode=json"
  @doc false
  def ashby_url(slug), do: "https://api.ashbyhq.com/posting-api/job-board/#{slug}"

  # ── ATS detection + parsing ────────────────────────────────────────────────

  defp detect_ats(html) when is_binary(html) do
    Enum.find_value(@ats, fn {name, re, builder, kind} ->
      case Regex.run(re, html, capture: :all_but_first) do
        [slug | _] -> {name, builder.(slug), kind}
        _ -> nil
      end
    end)
  end

  defp detect_ats(_), do: nil

  defp parse(:greenhouse, %{"jobs" => jobs}) do
    Enum.map(jobs, fn j ->
      job(j["title"], get_in(j, ["location", "name"]), j["absolute_url"], j["updated_at"])
    end)
  end

  defp parse(:lever, jobs) when is_list(jobs) do
    Enum.map(jobs, fn j ->
      job(j["text"], get_in(j, ["categories", "location"]), j["hostedUrl"], nil)
    end)
  end

  defp parse(:ashby, %{"jobs" => jobs}) do
    Enum.map(jobs, fn j -> job(j["title"], j["location"], j["jobUrl"], j["publishedAt"]) end)
  end

  defp parse(_, _), do: []

  # Fallback: pull job-ish links straight out of the careers page.
  defp scrape_html(html, domain, _ip) when is_binary(html) do
    ~r/<a[^>]+href=["']([^"']*\/(?:jobs?|careers?|positions?)\/[^"']+)["'][^>]*>(.*?)<\/a>/is
    |> Regex.scan(html, capture: :all_but_first)
    |> Enum.map(fn [href, text] -> job(strip_tags(text), nil, absolute(href, domain), nil) end)
    |> Enum.filter(&(&1.title != ""))
    |> Enum.uniq_by(& &1.title)
    |> Enum.take(200)
  end

  defp scrape_html(_, _, _), do: []

  # ── shaping ────────────────────────────────────────────────────────────────

  defp build(ats, jobs) do
    summary = %{
      job_count: length(jobs),
      ats_platform: ats,
      job_departments: jobs |> Enum.map(&department/1) |> tally(),
      job_locations: jobs |> Enum.map(& &1.location) |> tally()
    }

    {summary, jobs}
  end

  defp job(title, location, url, posted) do
    t = clean(title)

    %{
      title: t,
      location: clean(location),
      url: clean(url),
      posted_at: clean(posted) |> String.slice(0, 10),
      job_id: :erlang.crc32("#{t}|#{clean(location)}")
    }
  end

  # Coarse department from the job title — enough to answer "are they hiring
  # engineers or salespeople", which is the question buyers actually ask.
  defp department(%{title: t}) do
    d = String.downcase(t)

    cond do
      d =~ ~r/engineer|developer|software|devops|sre|data|scientist/ -> "Engineering"
      d =~ ~r/sales|account exec|business development|bdr|sdr/ -> "Sales"
      d =~ ~r/market|growth|content|seo|brand/ -> "Marketing"
      d =~ ~r/support|success|care/ -> "Support"
      d =~ ~r/product manager|product owner|\bpm\b/ -> "Product"
      d =~ ~r/design|ux|ui/ -> "Design"
      d =~ ~r/financ|account|legal|hr|people|recruit/ -> "G&A"
      true -> "Other"
    end
  end

  # "Engineering:12|Sales:4" — compact, sortable, no child table needed.
  defp tally(values) do
    values
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_, n} -> -n end)
    |> Enum.take(10)
    |> Enum.map_join("|", fn {v, n} -> "#{v}:#{n}" end)
  end

  defp fetch_json(url) do
    case Client.fetch_url(url, timeout: @timeout, politeness_retries: 3) do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, payload} -> {:ok, payload}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp clean(nil), do: ""
  defp clean(s) when is_binary(s), do: s |> strip_tags() |> String.trim() |> String.slice(0, 200)
  defp clean(_), do: ""

  defp strip_tags(s), do: String.replace(s, ~r/<[^>]+>/, "")

  defp absolute("http" <> _ = url, _domain), do: url
  defp absolute(path, domain), do: "https://#{domain}#{path}"
end
