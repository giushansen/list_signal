defmodule LS.Schema.Tables do
  @moduledoc """
  The ClickHouse table names, in one place (data model v2, 2026-10-01).

  Naming rule, decided with the owner in `docs/data-model-standards.md`:

    * `<pipeline>_log`: append-only observations, one row per sighting,
      never updated. `enrich_log` (was domains_history), `http_deep_log`
      (was biz_enrichment_log), `ctl_log` (was ctl_sightings),
      `verified_log` (was verified_source_records).
    * `changes_log`: the one derived event table (was biz_signal).
    * `<pipeline>_<things>`: current state, one row per key:
      `shop_products`, `shop_collections`, `hr_jobs`, `http_contacts`,
      `http_pages`.
    * `domains` (every domain ever seen, was domains_current) and
      `businesses` (the product table) are the two nouns without prefix.

  Every query in the code base reads the name from here, never as a bare
  literal, so a rename is one edit and the migration list below is the
  record of what moved.
  """

  @renames [
    {"domains_history", "enrich_log"},
    {"domains_current", "domains"},
    {"biz_enrichment_log", "http_deep_log"},
    {"biz_enrichment", "http_deep_state"},
    {"biz_products", "shop_products"},
    {"biz_collections", "shop_collections"},
    {"biz_career", "hr_jobs"},
    {"biz_contact", "http_contacts"},
    {"biz_pricing", "http_deep_prices"},
    {"biz_news", "news_items"},
    {"biz_page_fetch", "http_deep_fetch_log"},
    {"ctl_sightings", "ctl_log"},
    {"verified_source_records", "verified_log"},
    {"verification_domain_keys", "verified_keys"},
    {"verification_runs", "verified_runs"},
    {"verification_ch_accounts", "verified_ch_accounts"},
    {"verification_inpi_ratios", "verified_inpi_ratios"}
  ]

  @doc "`[{old, new}]` for the one-time RENAME TABLE and for Metabase/doc updates."
  def renames, do: @renames

  @doc "The new name of a v1 table (identity for tables that did not move)."
  def renamed(old) do
    case List.keyfind(@renames, old, 0) do
      {_, new} -> new
      nil -> old
    end
  end

  def enrich_log, do: "enrich_log"
  def domains, do: "domains"
  def businesses, do: "businesses"
  def http_deep_log, do: "http_deep_log"
  def http_deep_state, do: "http_deep_state"
  def http_pages, do: "http_pages"
  def http_contacts, do: "http_contacts"
  def http_deep_prices, do: "http_deep_prices"
  def shop_products, do: "shop_products"
  def shop_collections, do: "shop_collections"
  def hr_jobs, do: "hr_jobs"
  def hr_boards, do: "hr_boards"
  def news_items, do: "news_items"
  def ctl_log, do: "ctl_log"
  def changes_log, do: "changes_log"
  def tech_catalog, do: "tech_catalog"
  def verified_facts, do: "verified_facts"
  def verified_log, do: "verified_log"
  def verified_keys, do: "verified_keys"
  def verified_runs, do: "verified_runs"
end
