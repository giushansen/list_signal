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

    A  an online business with money: Ecommerce, SaaS, Tool or
       Marketplace with revenue over $1M, open jobs or a catalogue.
       3.1M sites. Every 14 days.
    B  the other online businesses, and the sites the classifier abstained
       on (which may be one). 9.7M. Every 90 days.
    C  everything that sells in person or by hand (local business, agency,
       consulting, manufacturer, media, education, government...) and the
       top 100K ranked sites. 10.3M. Every 180 days.

  Re-cut on 2026-10-23, after the fleet went from 13 workers to 6: the
  first cut (ICP incl. Agency and Consulting, a contact counting as
  motion, 14/60/120) asked for 773K refreshes a day against a 600K
  ceiling and about 300K of real capacity, so the queue grew 25K an hour
  and the scheduler paused itself at its 150K headroom. A contact alone no
  longer buys the fortnight: 2.7M Ecommerce sites had only an email or a
  phone. Nominal demand is now 223K + 107K + 57K = 387K a day, and the
  change-aware rings take unchanged tier-A sites to 28-35 days by
  themselves, so the expected steady state is about 300K. A site that just
  changed goes back to 7 days whatever its tier. Junk and walled sites are
  not refreshed by schedule at all; a certificate re-sighting or the
  browser lane handles them.
  """

  alias LS.Schema.Tables

  @icp ~w(Ecommerce SaaS Tool Marketplace)
  @cadence_days %{a: 14, b: 90, c: 180}
  @top_rank 100_000

  @doc "Business models refreshed as online businesses: the ones a list buyer sells to and that change on the web."
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
      model in @icp and money?(b) -> :a
      model in @icp or model == "" -> :b
      true -> :c
    end
  end

  # Revenue over $1M, open jobs or a catalogue. A contact address or phone
  # is not money: 2.7M Ecommerce sites had nothing else (2026-10-23).
  defp money?(b) do
    (get(b, :estimated_revenue) || "") not in ["", "<$1M"] or
      (get(b, :hr_job_count) || 0) > 0 or
      (get(b, :shop_product_count) || 0) > 0
  end

  defp get(b, key), do: Map.get(b, key) || Map.get(b, Atom.to_string(key))

  @doc "The ICP models as a SQL list."
  def icp_sql, do: Enum.map_join(@icp, ", ", &"'#{&1}'")

  @doc "A ClickHouse expression giving 'a', 'b' or 'c' for a `businesses` row."
  @spec tier_sql() :: String.t()
  def tier_sql do
    "multiIf(tranco_rank IS NOT NULL AND tranco_rank > 0 AND tranco_rank <= #{@top_rank}, 'c', " <>
      "estimated_business_model IN (#{icp_sql()}) AND (estimated_revenue NOT IN ('', '<$1M') OR coalesce(hr_job_count, 0) > 0 " <>
      "OR coalesce(shop_product_count, 0) > 0), 'a', " <>
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
