defmodule LS.Crawl.Tiers do
  @moduledoc """
  Which businesses are refreshed how often, decided once and read by the
  compactor (which marks the slow tiers into the crawl gate's rings) and
  the recrawl scheduler (which enqueues what is due).

  Measured on 2026-10-03 before this existed: of 1.32M fetches a day, 367K
  were refreshes, 3.1K of those on top-100K sites, and 221K on ICP models;
  the effective refresh cadence was about a month for everything, because
  the stable ring stretched unchanged sites to 28-35 days and twice
  unchanged to 60-90. Refreshing every ICP business every two weeks would
  have cost 1.04M fetches a day, 2.8 times the refresh budget. So: three
  tiers, by what a customer buys.

    A  an ICP business with money or motion: revenue over $1M, open jobs,
       a catalogue, a reachable contact. About 6M sites. Every 14 days.
    B  the other ICP businesses, and the sites the classifier abstained on
       (which may be ICP). About 9M. Every 60 days.
    C  non-ICP models (local business, media, community, education,
       government...) and the top 100K ranked sites, which are not the
       target market and do not change as businesses. Every 120 days.

  The change-aware rings sit on top: a tier-A site whose last two crawls
  were unchanged still drifts to 28-35 days by itself, and a site that just
  changed goes back to 7 whatever its tier. Junk and walled sites are not
  refreshed by schedule at all; a certificate re-sighting or the browser
  lane handles them.
  """

  alias LS.Schema.Tables

  @icp ~w(Ecommerce SaaS Tool Marketplace Agency Consulting)
  @cadence_days %{a: 14, b: 60, c: 120}
  @top_rank 100_000

  @doc "Business models that are the target market."
  @spec icp_models() :: [String.t()]
  def icp_models, do: @icp

  @doc "Refresh cadence of a tier, in days."
  @spec cadence_days(:a | :b | :c) :: pos_integer()
  def cadence_days(tier), do: Map.fetch!(@cadence_days, tier)

  @doc """
  The tier of one compiled business row (v2 column names, atom or string
  keys). Pure; the SQL form below must agree with it, and the test holds
  both to the same cases.
  """
  @spec tier(map()) :: :a | :b | :c
  def tier(%{} = b) do
    model = get(b, :estimated_business_model) || ""
    rank = get(b, :tranco_rank)

    cond do
      is_integer(rank) and rank > 0 and rank <= @top_rank -> :c
      model in @icp and motion?(b) -> :a
      model in @icp or model == "" -> :b
      true -> :c
    end
  end

  defp motion?(b) do
    (get(b, :estimated_revenue) || "") not in ["", "<$1M"] or
      (get(b, :hr_job_count) || 0) > 0 or
      (get(b, :shop_product_count) || 0) > 0 or
      List.wrap(get(b, :http_emails)) != [] or
      (get(b, :http_phone) || "") != ""
  end

  defp get(b, key), do: Map.get(b, key) || Map.get(b, Atom.to_string(key))

  @doc "The ICP models as a SQL list."
  def icp_sql, do: Enum.map_join(@icp, ", ", &"'#{&1}'")

  @doc "A ClickHouse expression giving 'a', 'b' or 'c' for a `businesses` row."
  @spec tier_sql() :: String.t()
  def tier_sql do
    "multiIf(tranco_rank IS NOT NULL AND tranco_rank > 0 AND tranco_rank <= #{@top_rank}, 'c', " <>
      "estimated_business_model IN (#{icp_sql()}) AND (estimated_revenue NOT IN ('', '<$1M') OR coalesce(hr_job_count, 0) > 0 " <>
      "OR coalesce(shop_product_count, 0) > 0 OR notEmpty(http_emails) OR http_phone != ''), 'a', " <>
      "estimated_business_model IN (#{icp_sql()}) OR estimated_business_model = '', 'b', 'c')"
  end

  @doc "Domain and tier of every non-junk business compiled in the window."
  @spec compiled_tiers_sql(integer(), integer()) :: String.t()
  def compiled_tiers_sql(since_unix, until_unix) do
    """
    SELECT domain, #{tier_sql()} AS tier
    FROM #{Tables.businesses()}
    WHERE compiled_at >= toDateTime(#{since_unix}) AND compiled_at < toDateTime(#{until_unix})
      AND estimated_junk = ''
    SETTINGS max_threads = 2, max_execution_time = 60
    """
  end
end
