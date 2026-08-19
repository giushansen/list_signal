defmodule LS.Verification.Sources.YC do
  @moduledoc """
  Y Combinator's public company directory, read the way their own site reads
  it: the search-only Algolia key embedded in `ycombinator.com/companies`
  (`window.AlgoliaOpts = {"app": ..., "key": ...}`) against the
  `YCCompany_production` index. No account, no private key; the key is scraped
  at run time so a rotation cannot silently break the source.

  Algolia caps browsing at 1 000 hits per query, so we page per `batch` facet
  (≤ 400 companies each). We take website, team_size, batch, one_liner (kept
  as `mission`), industry, status and location.
  """

  alias LS.Verification.{HTTP, Ingest, Domain}

  @page_url "https://www.ycombinator.com/companies"
  @index "YCCompany_production"
  @attrs ~w(name slug website team_size batch one_liner industry subindustry status all_locations launched_at nonprofit)
  @per_page 500

  def run(_opts \\ []) do
    with {:ok, html} <- HTTP.get_body(@page_url, headers: [{"accept", "text/html"}]),
         {:ok, app, key} <- algolia_opts(html),
         {:ok, batches} <- batches(app, key) do
      records =
        batches
        |> Stream.flat_map(fn batch -> hits(app, key, batch) end)
        |> Stream.map(&record/1)
        |> Stream.reject(&is_nil/1)

      Ingest.ingest(:yc, records, url: @page_url, snapshot: Date.utc_today() |> to_string(), name_tier: false)
    end
  end

  @doc "Pull the public Algolia app id + search key out of the companies page (pure)."
  @spec algolia_opts(binary()) :: {:ok, String.t(), String.t()} | {:error, :no_algolia_opts}
  def algolia_opts(html) when is_binary(html) do
    case Regex.run(~r/AlgoliaOpts\s*=\s*\{"app":"([A-Za-z0-9]+)","key":"([A-Za-z0-9=_-]+)"/, html) do
      [_, app, key] -> {:ok, app, key}
      _ -> {:error, :no_algolia_opts}
    end
  end

  defp batches(app, key) do
    case query(app, key, %{query: "", hitsPerPage: 0, facets: ["batch"], maxValuesPerFacet: 1000}) do
      {:ok, %{"facets" => %{"batch" => f}}} -> {:ok, Map.keys(f)}
      {:ok, other} -> {:error, {:no_facets, inspect(other) |> String.slice(0, 200)}}
      err -> err
    end
  end

  defp hits(app, key, batch, page \\ 0) do
    body = %{query: "", hitsPerPage: @per_page, page: page, attributesToRetrieve: @attrs,
             facetFilters: [["batch:#{batch}"]]}

    case query(app, key, body) do
      {:ok, %{"hits" => hits, "nbPages" => nb}} when page + 1 < nb -> hits ++ hits(app, key, batch, page + 1)
      {:ok, %{"hits" => hits}} -> hits
      {:error, e} -> raise "YC batch #{batch}: #{inspect(e)}"
    end
  end

  defp query(app, key, body) do
    HTTP.post_json("https://#{String.downcase(app)}-dsn.algolia.net/1/indexes/#{@index}/query", body,
      headers: [{"x-algolia-application-id", app}, {"x-algolia-api-key", key}], gap_ms: 500)
  end

  @doc "One Algolia hit → a record, or nil when it has no usable website (pure)."
  def record(hit) when is_map(hit) do
    website = hit["website"]
    domain = Domain.from_url(website)
    slug = hit["slug"] || hit["objectID"]

    if is_nil(domain) or is_nil(slug) do
      nil
    else
      %{
        source: :yc,
        source_id: to_string(slug),
        name: to_string(hit["name"] || slug),
        country: "",
        website: website,
        website_domain: domain,
        employees: team_size(hit["team_size"]),
        period: to_string(hit["batch"] || ""),
        extra:
          %{
            "batch" => hit["batch"],
            "mission" => hit["one_liner"],
            "industry" => hit["industry"],
            "hq" => hit["all_locations"],
            "status" => hit["status"],
            "nonprofit" => hit["nonprofit"]
          }
          |> Enum.reject(fn {_, v} -> v in [nil, ""] end)
          |> Map.new(),
        source_url: "https://www.ycombinator.com/companies/#{slug}"
      }
    end
  end

  def record(_), do: nil

  # team_size is self-declared; 0 means "not filled in", not "zero people".
  defp team_size(n) when is_integer(n) and n > 0 and n < 1_000_000, do: n
  defp team_size(_), do: nil
end
