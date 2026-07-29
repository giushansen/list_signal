defmodule LS.Enrichment.Shopify do
  @moduledoc """
  Catalog intelligence for Shopify stores via the public `/products.json` API.

  Every Shopify store exposes its catalog as JSON without authentication, so
  this needs **no browser** — a plain HTTP GET through `LS.HTTP.Client` (and
  therefore through the per-IP politeness limiter) returns structured product
  data. That makes the most commercially valuable commerce signals cheap
  enough to run on the ordinary worker fleet.

  Metrics produced (all 1:1 per domain, so they live as columns on
  `businesses`, not in a child table):

    * `product_count`     — store size; the headline number buyers filter on
    * `price_min/avg/max` — price positioning / AOV proxy
    * `new_products_30d`  — is the store actually active and growing
    * `last_product_at`   — liveness; a better dead-store signal than HTTP
    * `oos_ratio`         — out-of-stock share, inventory health
    * `discount_depth`    — mean markdown vs `compare_at_price`
    * `vendor_count`      — multi-brand retailer vs single-brand DTC
    * `catalog_age_days`  — store maturity

  Only the first `@max_pages` pages are read: 250 products give stable
  statistics, and full catalogues of 10k+ products would cost far more
  politeness budget than the extra precision is worth.
  """

  require Logger

  alias LS.HTTP.Client

  @per_page 250
  @max_pages 2
  # Per-domain caps on what we KEEP (we already fetch up to 500 for the
  # aggregates). A few stores publish tens of thousands of SKUs; storing them
  # all would dominate biz_products without adding signal.
  @max_products_stored 250
  @max_collections_stored 100
  @timeout 10_000
  # A 250-product page is ~570 KB — over the client's 512 KB HTML guard, which
  # would truncate the JSON and make it undecodable (silently reading as "no
  # catalog"). Structured endpoint, so raise the cap deliberately.
  @max_json_bytes 4_000_000

  @empty %{
    product_count: nil, price_min: nil, price_avg: nil, price_max: nil,
    new_products_30d: nil, last_product_at: nil, oos_ratio: nil,
    discount_depth: nil, vendor_count: nil, catalog_age_days: nil,
    product_types: ""
  }

  @doc """
  Fetch a Shopify catalog. Returns `%{summary, products, collections}` — the
  aggregates for `businesses`, plus the individual products and collections for
  `biz_products` / `biz_collections`. Returns empty parts for any
  non-Shopify domain or on any failure — never raises, never blocks a batch.
  """
  @spec analyze(String.t(), String.t() | nil) :: map()
  def analyze(domain, ip \\ nil) do
    # `ip` is optional in the signature, so resolve it here when the caller did
    # not supply one — LS.HTTP.Client refuses IP-less fetches (it cannot rate
    # limit them), which would otherwise make every such call return "no catalog".
    ip = ip || resolve(domain)

    case fetch_products(domain, ip) do
      [] ->
        %{summary: @empty, products: [], collections: []}

      products ->
        %{
          summary: summarise(products),
          products: product_rows(products, domain),
          collections: fetch_collections(domain, ip)
        }
    end
  rescue
    e ->
      Logger.debug("[SHOPIFY] #{domain} failed: #{Exception.message(e)}")
      %{summary: @empty, products: [], collections: []}
  end

  @doc "True when the discovery pipeline's tech detection saw Shopify."
  @spec shopify?(String.t() | nil) :: boolean()
  def shopify?(http_tech) when is_binary(http_tech), do: String.contains?(http_tech, "Shopify")
  def shopify?(_), do: false

  # ── fetching ───────────────────────────────────────────────────────────────

  defp fetch_products(domain, ip) do
    Enum.reduce_while(1..@max_pages, [], fn page, acc ->
      case fetch_page(domain, ip, page) do
        [] -> {:halt, acc}
        list when length(list) < @per_page -> {:halt, acc ++ list}
        list -> {:cont, acc ++ list}
      end
    end)
  end

  defp fetch_page(domain, ip, page) do
    path = "/products.json?limit=#{@per_page}&page=#{page}"

    with {:ok, %{status: 200, body: body}} <-
           Client.fetch(domain, ip, path: path, timeout: @timeout, max_bytes: @max_json_bytes),
         {:ok, %{"products" => products}} <- Jason.decode(body) do
      products
    else
      _ -> []
    end
  end

  # ── the catalog itself ─────────────────────────────────────────────────────

  # We already hold every product in memory to compute the aggregates, so
  # keeping them costs one extra insert and answers the question the aggregates
  # cannot: *what* does this store actually sell? "product_count: 500,
  # price_max: 45000" does not tell a customer whether to prospect a rug shop.
  #
  # Capped per domain: a handful of stores publish tens of thousands of SKUs and
  # would otherwise dominate the table for no extra signal.
  defp product_rows(products, domain) do
    now = timestamp()

    products
    |> Enum.take(@max_products_stored)
    |> Enum.map(fn p ->
      variants = p["variants"] || []
      prices = variants |> Enum.map(&to_float(&1["price"])) |> Enum.reject(&is_nil/1)

      %{
        domain: domain,
        product_id: to_int(p["id"]),
        title: str(p["title"]),
        handle: str(p["handle"]),
        vendor: str(p["vendor"]),
        product_type: str(p["product_type"]),
        price: min_of(prices),
        available: if(Enum.any?(variants, &(&1["available"] == true)), do: 1, else: 0),
        variant_count: length(variants),
        image_count: length(p["images"] || []),
        created_at: p["created_at"] |> parse_dt() |> fmt_dt(),
        seen_at: now
      }
    end)
  end

  # Collections are a separate public endpoint. They are the store's own
  # merchandising taxonomy — far more meaningful than the free-text
  # `product_type` field, which many stores leave blank.
  defp fetch_collections(domain, ip) do
    now = timestamp()

    with {:ok, %{status: 200, body: body}} <-
           Client.fetch(domain, ip,
             path: "/collections.json?limit=#{@per_page}",
             timeout: @timeout,
             max_bytes: @max_json_bytes),
         {:ok, %{"collections" => collections}} <- Jason.decode(body) do
      collections
      |> Enum.take(@max_collections_stored)
      |> Enum.map(fn c ->
        %{
          domain: domain,
          collection_id: to_int(c["id"]),
          title: str(c["title"]),
          handle: str(c["handle"]),
          products_count: to_int(c["products_count"]),
          updated_at: c["updated_at"] |> parse_dt() |> fmt_dt(),
          seen_at: now
        }
      end)
    else
      _ -> []
    end
  end

  defp str(nil), do: ""
  defp str(v) when is_binary(v), do: v |> String.replace(["\t", "\n", "\r"], " ") |> String.slice(0, 300)
  defp str(v), do: to_string(v)

  defp to_int(n) when is_integer(n), do: n
  defp to_int(n) when is_binary(n), do: case(Integer.parse(n), do: ({i, _} -> i; _ -> 0))
  defp to_int(_), do: 0

  defp resolve(domain) do
    case LS.DNS.Resolver.lookup(domain) do
      {:ok, %{a: [ip | _]}} -> ip
      _ -> nil
    end
  end

  defp timestamp, do: NaiveDateTime.utc_now() |> NaiveDateTime.to_string() |> String.slice(0, 19)

  # ── summarising ────────────────────────────────────────────────────────────

  defp summarise(products) do
    prices = products |> Enum.flat_map(&variant_prices/1) |> Enum.reject(&is_nil/1)
    created = products |> Enum.map(&parse_dt(&1["created_at"])) |> Enum.reject(&is_nil/1)
    variants = Enum.flat_map(products, &(&1["variants"] || []))
    cutoff = DateTime.add(DateTime.utc_now(), -30 * 86_400, :second)

    %{
      product_count: length(products),
      price_min: min_of(prices),
      price_avg: avg_of(prices),
      price_max: max_of(prices),
      new_products_30d: Enum.count(created, &(DateTime.compare(&1, cutoff) == :gt)),
      last_product_at: created |> max_dt() |> fmt_dt(),
      oos_ratio: ratio(variants, &(&1["available"] == false)),
      discount_depth: discount_depth(variants),
      vendor_count: products |> Enum.map(& &1["vendor"]) |> Enum.reject(&blank?/1) |> Enum.uniq() |> length(),
      catalog_age_days: catalog_age(created),
      product_types:
        products
        |> Enum.map(& &1["product_type"])
        |> Enum.reject(&blank?/1)
        |> Enum.uniq()
        |> Enum.take(20)
        |> Enum.join("|")
    }
  end

  defp variant_prices(product) do
    (product["variants"] || []) |> Enum.map(&to_float(&1["price"]))
  end

  # Mean markdown across variants that actually carry a compare-at price.
  defp discount_depth(variants) do
    discounts =
      variants
      |> Enum.map(fn v -> {to_float(v["price"]), to_float(v["compare_at_price"])} end)
      |> Enum.filter(fn {p, c} -> is_number(p) and is_number(c) and c > 0 and c > p end)
      |> Enum.map(fn {p, c} -> (c - p) / c end)

    avg_of(discounts)
  end

  defp catalog_age(created) do
    case min_dt(created) do
      nil -> nil
      oldest -> DateTime.diff(DateTime.utc_now(), oldest, :second) |> div(86_400)
    end
  end

  # ── small helpers ──────────────────────────────────────────────────────────

  defp ratio([], _fun), do: nil
  defp ratio(list, fun), do: Float.round(Enum.count(list, fun) / length(list), 3)

  defp avg_of([]), do: nil
  defp avg_of(nums), do: Float.round(Enum.sum(nums) / length(nums), 2)

  defp min_of([]), do: nil
  defp min_of(nums), do: Float.round(Enum.min(nums), 2)

  defp max_of([]), do: nil
  defp max_of(nums), do: Float.round(Enum.max(nums), 2)

  defp min_dt([]), do: nil
  defp min_dt(dts), do: Enum.min_by(dts, &DateTime.to_unix/1)

  defp max_dt([]), do: nil
  defp max_dt(dts), do: Enum.max_by(dts, &DateTime.to_unix/1)

  defp fmt_dt(nil), do: nil
  defp fmt_dt(dt), do: dt |> DateTime.to_naive() |> NaiveDateTime.to_string() |> String.slice(0, 19)

  defp parse_dt(nil), do: nil
  defp parse_dt(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end
  defp parse_dt(_), do: nil

  defp to_float(nil), do: nil
  defp to_float(n) when is_number(n), do: n / 1
  defp to_float(s) when is_binary(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> nil
    end
  end
  defp to_float(_), do: nil

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false
end
