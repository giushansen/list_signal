defmodule LS.Enrichment.Sitemap do
  @moduledoc """
  A one-row snapshot of a business's sitemap: how big the site is, how it
  is shaped, how fresh it is, and a fingerprint to notice when it changes.

  ## Why (2026-09-06)

  Page count is one of the best public proxies for organisation size: a
  40-URL brochure and a 40,000-URL site are different companies, whatever
  their homepages say. Product-URL counts cross-check the Shopify catalog,
  blog and careers counts say whether anyone is publishing or hiring, and
  a simhash of the URL set turns "the site was restructured" into a change
  signal. The revenue estimator reads `sitemap_urls` (`signal_site_size`).

  ## Pareto, not completeness

  The robots.txt we already fetch names the sitemap; failing that,
  `/sitemap.xml`. The first file is read (capped at 1 MB). If it is an
  index, up to `@max_children` child sitemaps are read too and the URL
  count is extrapolated from the sampled children when there are more.
  That is at most four small requests for a large site, one for most.

  Pure parsing over hostile XML: regexes, no XML parser, everything capped,
  nothing raises.
  """

  alias LS.HTTP.Client

  @max_bytes 1_048_576
  @max_children 3
  @max_urls_scanned 50_000
  @timeout 10_000

  @type snapshot :: %{
          sitemap_urls: non_neg_integer() | nil,
          sitemap_products: non_neg_integer() | nil,
          sitemap_blog: non_neg_integer() | nil,
          sitemap_children: non_neg_integer() | nil,
          sitemap_lastmod: String.t() | nil,
          sitemap_hash: non_neg_integer() | nil
        }

  @doc false
  def empty,
    do: %{sitemap_urls: nil, sitemap_products: nil, sitemap_blog: nil, sitemap_children: nil, sitemap_lastmod: nil, sitemap_hash: nil}

  @doc """
  Fetch and summarise the sitemap for `domain`. `candidates` are sitemap
  URLs read from robots.txt (may be empty). Same-host URLs only: a
  robots.txt pointing at another host is not followed.
  """
  @spec snapshot(String.t(), String.t() | nil, [String.t()]) :: snapshot()
  def snapshot(domain, ip, candidates \\ []) do
    paths =
      (candidates |> Enum.map(&same_host_path(&1, domain)) |> Enum.reject(&is_nil/1)) ++ ["/sitemap.xml", "/sitemap_index.xml"]

    paths
    |> Enum.uniq()
    |> Enum.take(3)
    |> Enum.find_value(empty(), fn path ->
      case fetch(domain, ip, path) do
        {:ok, body} ->
          case summarise(body, fn child -> fetch_child(domain, ip, child) end) do
            %{sitemap_urls: n} = snap when is_integer(n) and n > 0 -> snap
            _ -> nil
          end

        _ ->
          nil
      end
    end)
  rescue
    _ -> empty()
  end

  defp fetch(domain, ip, path) do
    case Client.fetch(domain, ip, path: path, timeout: @timeout, max_bytes: @max_bytes, politeness_retries: 2) do
      {:ok, %{status: 200, body: body}} when is_binary(body) and body != "" -> {:ok, body}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp fetch_child(domain, ip, url) do
    case same_host_path(url, domain) do
      nil -> :error
      path -> fetch(domain, ip, path)
    end
  end

  @doc false
  # "https://www.acme.com/sitemap_products_1.xml" -> "/sitemap_products_1.xml"
  # when the host is the domain or a subdomain of it; nil otherwise.
  def same_host_path(url, domain) when is_binary(url) and is_binary(domain) do
    uri = URI.parse(String.trim(url))
    host = String.downcase(uri.host || "")
    d = String.downcase(domain)

    cond do
      host == "" -> nil
      host == d or String.ends_with?(host, "." <> d) ->
        (uri.path || "/") <> if(uri.query, do: "?" <> uri.query, else: "")
      true -> nil
    end
  rescue
    _ -> nil
  end

  def same_host_path(_, _), do: nil

  # ── Pure summary ─────────────────────────────────────────────────────────

  @doc """
  Summarise a sitemap or sitemap-index body. `fetch_child` is called with a
  child URL and returns `{:ok, body}` or `:error`; pass `fn _ -> :error end`
  to summarise a single file. Pure apart from that callback.
  """
  @spec summarise(term(), (String.t() -> {:ok, binary()} | :error)) :: snapshot()
  def summarise(body, fetch_child) when is_binary(body) do
    body = binary_part(body, 0, min(byte_size(body), @max_bytes))

    if index?(body) do
      children = child_urls(body)
      sampled = children |> Enum.take(@max_children) |> Enum.map(fetch_child)
      bodies = for {:ok, b} <- sampled, do: b
      urls = bodies |> Enum.flat_map(&urls_of/1) |> Enum.take(@max_urls_scanned)

      # Extrapolate from the sampled children when the index has more.
      total =
        case {length(children), length(bodies)} do
          {n, k} when k > 0 and n > k -> div(length(urls) * n, k)
          _ -> length(urls)
        end

      urls |> stats() |> Map.merge(%{sitemap_urls: total, sitemap_children: length(children)}) |> Map.put(:sitemap_lastmod, newest_lastmod(bodies ++ [body]))
    else
      urls = body |> urls_of() |> Enum.take(@max_urls_scanned)
      urls |> stats() |> Map.merge(%{sitemap_urls: length(urls), sitemap_children: 0, sitemap_lastmod: newest_lastmod([body])})
    end
  rescue
    _ -> empty()
  end

  def summarise(_, _), do: empty()

  defp index?(body), do: Regex.match?(~r/<sitemapindex[\s>]/i, body)

  @doc false
  def child_urls(body) do
    ~r/<sitemap>.*?<loc>\s*([^<\s]{1,2000})\s*<\/loc>.*?<\/sitemap>/is
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.map(&hd/1)
    |> Enum.take(500)
  end

  @doc false
  def urls_of(body) do
    ~r/<url>.*?<loc>\s*([^<\s]{1,2000})\s*<\/loc>/is
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.map(&hd/1)
  end

  defp stats(urls) do
    paths = Enum.map(urls, fn u -> u |> String.downcase() |> path_of() end)

    %{
      sitemap_products: Enum.count(paths, &(String.contains?(&1, "/products/") or String.contains?(&1, "/product/") or String.contains?(&1, "/produkt") or String.contains?(&1, "/produit"))),
      sitemap_blog: Enum.count(paths, &(String.contains?(&1, "/blog") or String.contains?(&1, "/news") or String.contains?(&1, "/article"))),
      sitemap_hash: simhash(paths)
    }
  end

  defp path_of(url) do
    case URI.parse(url) do
      %URI{path: p} when is_binary(p) -> p
      _ -> url
    end
  rescue
    _ -> url
  end

  @doc false
  # Newest <lastmod> across bodies as "YYYY-MM-DD HH:MM:SS", or nil.
  def newest_lastmod(bodies) do
    bodies
    |> Enum.flat_map(fn b -> Regex.scan(~r/<lastmod>\s*(\d{4}-\d{2}-\d{2})/i, b, capture: :all_but_first) end)
    |> Enum.map(&hd/1)
    |> Enum.filter(&match?({:ok, _}, Date.from_iso8601(&1)))
    |> Enum.max(fn -> nil end)
    |> case do
      nil -> nil
      d -> d <> " 00:00:00"
    end
  end

  @doc false
  # 64-bit simhash over path tokens: two crawls of the same site agree even
  # when a few URLs come and go; a restructure flips many bits.
  def simhash([]), do: nil

  def simhash(paths) do
    weights =
      paths
      |> Enum.flat_map(fn p -> p |> String.split(~r{[/\-_.?=&]+}, trim: true) |> Enum.take(8) end)
      |> Enum.frequencies()

    acc = :erlang.make_tuple(64, 0)

    acc =
      Enum.reduce(weights, acc, fn {token, w}, acc ->
        <<h::unsigned-64, _::binary>> = :crypto.hash(:sha256, token)

        Enum.reduce(0..63, acc, fn bit, a ->
          delta = if Bitwise.band(Bitwise.bsr(h, bit), 1) == 1, do: w, else: -w
          put_elem(a, bit, elem(a, bit) + delta)
        end)
      end)

    Enum.reduce(0..63, 0, fn bit, h -> if elem(acc, bit) > 0, do: Bitwise.bor(h, Bitwise.bsl(1, bit)), else: h end)
  end
end
