defmodule LS.Clickhouse.CompactV2Test do
  @moduledoc """
  The compaction fold writes the v2 product table (2026-10-01). These pin
  what cannot be seen by running the SQL on a laptop: that the INSERT list
  is the spec, that the synthetic leg can read a v2 row back as history,
  that the new log columns are folded, that the nested-alias trap of
  2026-08-19 is avoided, and that the stable-domain check uses the same
  catalog map as the fold.
  """
  use ExUnit.Case, async: true

  alias LS.Clickhouse.Compact
  alias LS.Schema.Columns

  @sql Compact.compact_sql_for_test(1_700_000_000, 1_700_000_600)
  @full Compact.compact_sql_for_test(0)

  test "the INSERT list is exactly the spec, in order" do
    [_, list] = Regex.run(~r/INSERT INTO businesses \(([^)]*)\)/, @sql)
    assert String.split(list, ", ") == Columns.insert_columns()
  end

  test "every spec column is produced by the fold select" do
    for name <- Columns.names(), do: assert(@sql =~ " AS #{name}", "#{name} missing from the fold")
  end

  test "the log's new page-fact columns and the fingerprint are folded" do
    for col <- ~w(http_fingerprint http_phone http_address http_social_links http_company_id http_nav_links http_shopify_app_handles) do
      assert col in Compact.history_cols()
      assert @sql =~ "s_#{col}"
    end

    assert @sql =~ "JSONExtract(h.http_fingerprint, 'hosts', 'Array(String)')"
  end

  test "emails and social links fold as a union across observations" do
    assert @sql =~ "arrayFlatten(groupArray(splitByChar('|', s_http_emails))))), 1, 20) AS http_emails_all"
    assert @sql =~ "arrayFlatten(groupArray(splitByChar('|', s_http_social_links))))), 1, 20) AS http_social_links"
  end

  test "the synthetic leg replays a v2 row: arrays joined back, estimates mapped, status 200 on the verified row" do
    assert @sql =~ "arrayStringConcat(http_tech, '|')"
    assert @sql =~ "if(leg = 1, '', estimated_business_model) AS s_business_model"
    assert @sql =~ "ifNull(http_last_seen_at, http_last_checked_at)"
    assert @sql =~ "ORDER BY compiled_at DESC LIMIT 1 BY domain"
    assert @sql =~ "if(http_crawlable = 1, [1, 2], [2]) AS leg"
    assert @sql =~ "http_first_seen_at AS s_http_first_seen"
  end

  test "deep-pass timestamps are qualified so they do not nest the aliases above them (Code 184)" do
    assert @sql =~ "maxIf(s0.enriched_at, s0.product_count IS NOT NULL) AS shop_at"
    assert @sql =~ "maxIf(s0.enriched_at, s0.job_count IS NOT NULL) AS hr_at"
    assert @sql =~ ~r/\) AS s0\s+GROUP BY domain/
  end

  test "the fold reads the renamed tables and joins contacts for the touched domains" do
    for t <- ~w(enrich_log http_deep_log http_deep_state http_deep_prices news_items verified_facts ctl_log http_contacts) do
      assert @sql =~ "FROM #{t}", "#{t} not read"
    end

    refute @sql =~ "domains_history"
    refute @sql =~ "biz_enrichment"
    assert @sql =~ "FROM http_contacts WHERE domain IN (SELECT arrayJoin(_touched)) GROUP BY domain"
  end

  test "the catalog scalars are in every form of the fold" do
    for sql <- [@sql, @full] do
      assert sql =~ "(SELECT groupUniqArray(name) FROM tech_catalog) AS _catalog"
      assert sql =~ "AS _alias_from"
      assert sql =~ "has(_catalog, x)"
    end
  end

  test "the sharded and per-domain forms guard every table source" do
    sql = Compact.compact_sql_shard_preview(3, 256)
    guard = "domain IN (SELECT domain FROM businesses WHERE cityHash64(domain) % 256 = 3)"
    assert sql =~ "FROM enrich_log WHERE #{guard})"
    assert sql =~ "FROM http_deep_log WHERE #{guard} AND render_engine != 'failed'"
    assert sql =~ "FROM http_contacts WHERE #{guard} GROUP BY"
    assert sql =~ "FROM ctl_log WHERE #{guard} GROUP BY"
    assert sql =~ "FROM verified_facts WHERE #{guard}\n"

    domains = Compact.compact_sql_domains(["a.com", "b.com"])
    assert domains =~ "domain IN ('a.com','b.com')"
  end

  test "the stable check compares the catalog-mapped window list with the compiled array" do
    sql = Compact.stable_domains_sql(1, 2)
    assert sql =~ "transform(x, _alias_from, _alias_to, x)"
    assert sql =~ "arraySort(http_tech) AS tech_sorted"
    assert sql =~ "n.tech = o.tech_sorted"
    assert sql =~ "FROM enrich_log"
  end

  test "the v1 transform selects every column from the old table deduplicated by as_of" do
    sql = LS.Schema.Migration.v1_transform_sql()
    assert sql =~ "INSERT INTO businesses_v2 ("
    assert sql =~ "FROM businesses AS b\n"
    refute sql =~ "LIMIT 1 BY domain", "a full sort of the v1 table does not fit the master's memory"
    for name <- Columns.names(), do: assert(sql =~ " AS #{name}")
  end

  test "the migration script is additive: no RENAME and no DROP inside it" do
    script = LS.Schema.Migration.script()
    refute script =~ "RENAME TABLE"
    refute script =~ "DROP TABLE"
    assert script =~ "CREATE TABLE IF NOT EXISTS businesses_v2"
    assert script =~ "INSERT INTO tech_catalog"
    assert script =~ "ALTER TABLE domains_history ADD COLUMN IF NOT EXISTS `http_phone`"
  end
end
