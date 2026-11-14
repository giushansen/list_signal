defmodule LS.Crawl.Lean do
  @moduledoc """
  Lean mode: the crawl on half the workers (owner's decision, 2026-11-14).
  One switch on the master, `LS_CRAWL_MODE=lean`. Unset it and every rule
  below stops applying at the next sighting; nothing is stored that has to
  be undone.

  ## Why these rules and not a name filter

  Measured on prod before the cut (259K first visits of 30 days, every
  DNS, certificate and name feature known before the fetch, logistic and
  boosted models, time split): the best-scored half of first visits held
  65% of the sellable ones, AUC 0.67 (0.61 behind Shopify). The gates
  already in place did the work: 80% of first visits came back as a real
  English or French site. The fetches were going elsewhere. Of a week's
  rows (3% sample by domain range, about 200K rows a day):

      first visits, plain             49K a day   31% newly sellable per fetch
      first visits, Shopify           29K         87% new stores, 23% with email
      revisit, ICP site               34K         no new business
      revisit, Shopify store (28 d)   25K         no new business
      revisit, read fine, no label    39K         no new business
      revisit, junk / other language  28K         4%

  Half of everything was a site read successfully 40 to 75 days earlier,
  fetched again because its certificate renewed. Three workers do about
  82K fetches a day (27 to 28 rows a minute each on their best day), 23K
  of them through Shopify's edge.

  ## The rules

    * A certificate sighting of a site read successfully in the last
      `reread_days/0` is recorded and not queued (`LS.Recrawl.LeanGate`,
      an exact lookup in `enrich_log`). First visits, and sites whose last
      visit failed, pass as before. The scheduler still refreshes tier A
      on its own clock, and tier B and C into the room that is left.
    * A tier A Shopify store is refreshed every `shopify_days/0`, not 28.

  First visits keep going first (`LS.Cluster.WorkQueue.priority/1`), and
  the queue still says when it is losing (`first_visit_health/0`).
  """

  @reread_days 120
  @shopify_days 90

  @doc "True when the master runs the lean crawl (`LS_CRAWL_MODE=lean`)."
  @spec on?(String.t() | nil) :: boolean()
  def on?(env \\ System.get_env("LS_CRAWL_MODE")), do: env == "lean"

  @doc "Days a successful read holds off certificate re-sightings in lean mode."
  @spec reread_days() :: pos_integer()
  def reread_days, do: @reread_days

  @doc "Refresh cadence of a tier A Shopify store in lean mode, in days."
  @spec shopify_days() :: pos_integer()
  def shopify_days, do: @shopify_days
end
