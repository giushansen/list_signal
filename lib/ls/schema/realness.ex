defmodule LS.Schema.Realness do
  @moduledoc """
  `estimated_realness`: how much evidence says this domain is an operating
  business, as a score in [0, 1] with the facts that fired in
  `estimated_realness_evidence`.

  Why (2026-10-01): the junk flag is binary and covered under 1% of rows
  while golden sets measured 24% to 35% junk. Customers asked for "real
  businesses"; a score built from facts already in the row lets them pick
  the band and see why a row is in it, and lets the product sell "new
  businesses that survived 30 days with a working store" instead of the
  raw certificate firehose.

  Every fact is a column of the product table, so the same expression
  runs in the fold (over the fold's own expressions), in the v1 transform
  and in a backfill over `businesses` (over column names). A junk verdict
  zeroes the score: a parked domain with MX is still parked.

  Weights are a first cut to be scored against golden v5 before any gate
  depends on them; the evidence string is what makes that scoring
  possible. Sum of weights is capped at 1.
  """

  @business_schema ~w(Organization LocalBusiness Corporation Store OnlineStore ProfessionalService
                      Restaurant MedicalBusiness FinancialService EducationalOrganization
                      TravelAgency RealEstateAgent LegalService HomeAndConstructionBusiness
                      AutoDealer AutomotiveBusiness SportsActivityLocation HealthAndBeautyBusiness
                      FoodEstablishment LodgingBusiness Dentist Physician Hotel)

  # {evidence key, weight, condition template}: `{col}` is replaced by the
  # resolver's SQL for that column. A plain list so it can be data, and the
  # template keeps the module attribute free of functions.
  @facts [
    {"mx", 0.15, "notEmpty({dns_mx})"},
    {"dmarc", 0.05, "{dns_dmarc} != ''"},
    {"contact", 0.15, "(notEmpty({http_emails}) OR {http_phone} != '')"},
    {"address", 0.05, "{http_address} != ''"},
    {"company_id", 0.15, "{http_company_id} != ''"},
    {"schema_org", 0.10, "{http_schema_type} IN (" <> Enum.map_join(@business_schema, ", ", &"'#{&1}'") <> ")"},
    {"age_90d", 0.10, "{ctl_first_seen_at} < now() - INTERVAL 90 DAY"},
    {"activity", 0.10, "(coalesce({shop_product_count}, 0) > 0 OR coalesce({hr_job_count}, 0) > 0)"},
    {"traffic", 0.10, "({tranco_rank} IS NOT NULL OR {majestic_rank} IS NOT NULL)"},
    {"social", 0.05, "notEmpty({http_social_links})"},
    {"registry", 0.10, "{verified_at} IS NOT NULL"}
  ]

  defp cond_sql(template, resolve),
    do: Regex.replace(~r/\{([a-z_]+)\}/, template, fn _, col -> resolve.(col) end)

  @doc "The facts: `{key, weight}` in evidence order."
  def facts, do: Enum.map(@facts, fn {k, w, _} -> {k, w} end)

  @doc "Columns the score reads."
  def inputs,
    do: ~w(dns_mx dns_dmarc http_emails http_phone http_address http_company_id http_schema_type ctl_first_seen_at
           shop_product_count hr_job_count tranco_rank majestic_rank http_social_links verified_at estimated_junk)

  @doc """
  SQL for the score. `resolve` maps a product column name to the SQL that
  yields it with its final type (an alias-free expression in the fold, the
  bare column name over `businesses`).
  """
  @spec score_sql((String.t() -> String.t())) :: String.t()
  def score_sql(resolve) do
    sum = Enum.map_join(@facts, " + ", fn {_, w, t} -> "if(#{cond_sql(t, resolve)}, #{w}, 0)" end)
    "toFloat32(if(#{resolve.("estimated_junk")} != '', 0, least(1.0, #{sum})))"
  end

  @doc "SQL for the evidence string: the keys of the facts that fired, '|' separated, empty for junk."
  @spec evidence_sql((String.t() -> String.t())) :: String.t()
  def evidence_sql(resolve) do
    parts = Enum.map_join(@facts, ", ", fn {k, _, t} -> "if(#{cond_sql(t, resolve)}, '#{k}', '')" end)
    "if(#{resolve.("estimated_junk")} != '', '', arrayStringConcat(arrayFilter(x -> x != '', [#{parts}]), '|'))"
  end
end
