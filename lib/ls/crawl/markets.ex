defmodule LS.Crawl.Markets do
  @moduledoc """
  The markets the crawl spends fetches on: English- and French-speaking
  countries plus the generic suffixes those businesses use.

  ## Why (2026-11-02, owner's decision)

  The customers buy lists of businesses they can write to in English or
  French. Measured on the seven days to 11-02 (2.68 M fetches): 22.5% of
  all fetches came back in another language (11.5% on .com and the other
  generic suffixes, 11.1% on country suffixes outside these markets), and
  another 12.4% returned no page at all. The sellable rows those fetches
  produced (email plus a classified model) were 36% of the total, which the
  owner does not sell. Every fetch costs a slot on a fleet that cannot go
  faster per IP, so a domain outside these markets is parsed, its
  certificate sighting is recorded, and it is never queued.

  Two gates use this list:

  - `LS.CTL.Poller` asks `crawl_tld?/1` before enqueueing a new domain;
  - `LS.Clickhouse.stale_domains_sql/3` refreshes only pages last read in
    English or French (`refresh_language_sql/0`), so businesses outside
    the markets age out of the refresh schedule instead of costing 14 to
    180-day revisits.

  The worker-side `LS.HTTP.DomainFilter` list is wider (it still admits
  .de or .jp); it only runs on what the master queued, so this list is the
  one that decides.
  """

  # Generic suffixes used by English- and French-speaking businesses, then
  # the country suffixes of every market where English or French is the
  # language of business. .xyz and .top are left out on yield
  # (LS.HTTP.DomainFilter measured .top at 21%).
  #
  # 2026-11-03, owner: keep every English- or French-speaking market, the
  # buyers are there. Measured on the 7 days before the gate (enrich_log):
  # .in 75% English, 1,466 sellable rows a week from 5.6K fetches (26%,
  # above .com's 15%); .ae 89%, .pk 80%, .my 74%, .co.ke 91%, .ma 82%.
  # BuiltWith's customers are about half US and 7 to 8% each UK and India
  # (idatalabs, enlyft). The large non-market suffixes stay out on yield:
  # .nl 14% English and 2% sellable per fetch, .de 13% and 1.2%, .it, .se,
  # .dk, .es, .no, .fi all under 3%; together they cost 240K fetches a week,
  # most of a node, for 3K sellable rows against .com's 260K.
  @tlds ~w(
    com net org io co ai app dev biz info shop store online site tech
    us uk co.uk org.uk me.uk ltd.uk plc.uk ca au com.au net.au org.au nz co.nz org.nz net.nz
    ie sg com.sg hk com.hk za co.za
    in co.in pk com.pk ph com.ph my com.my ng com.ng ke co.ke gh com.gh lk mt com.mt
    ae qa gg je im gi jm tt bs mu
    fr be ch lu mc eu re nc pf ma tn dz sn ci cm ht mg
  )
  @set MapSet.new(@tlds)

  @doc "Every suffix the crawl admits."
  @spec tlds() :: [String.t()]
  def tlds, do: @tlds

  @doc "Whether a new domain on this public suffix is worth a fetch."
  @spec crawl_tld?(String.t()) :: boolean()
  def crawl_tld?(tld) when is_binary(tld), do: MapSet.member?(@set, String.downcase(tld))
  def crawl_tld?(_), do: false

  @doc "SQL predicate on `http_language` selecting pages a customer can read."
  @spec refresh_language_sql() :: String.t()
  def refresh_language_sql, do: "(http_language LIKE 'en%' OR http_language LIKE 'fr%')"
end
