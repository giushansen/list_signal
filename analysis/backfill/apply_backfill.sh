#!/bin/bash
# Apply backfill v1 on the master: helper Join tables + guarded, sharded
# mutations on `businesses`. Run AFTER /home/ls/backup.sh (done: prod_20260814_154004).
# Guards repeated in SQL even though the compute pass already applied them —
# defense in depth, per the never-blank-another-writer rule.
set -e
CH="clickhouse-client -d ls --max_memory_usage=2000000000 --max_threads=2"

$CH --query "DROP TABLE IF EXISTS bf1_junk"
$CH --query "CREATE TABLE bf1_junk (domain String, j String) ENGINE = Join(ANY, LEFT, domain)"
$CH --query "INSERT INTO bf1_junk FORMAT TSV" < /tmp/bf_junk.tsv

$CH --query "DROP TABLE IF EXISTS bf1_class"
$CH --query "CREATE TABLE bf1_class (domain String, bm String, conf Float32) ENGINE = Join(ANY, LEFT, domain)"
$CH --query "INSERT INTO bf1_class FORMAT TSV" < /tmp/bf_class.tsv

$CH --query "DROP TABLE IF EXISTS bf1_rev"
$CH --query "CREATE TABLE bf1_rev (domain String, r String, conf Float32) ENGINE = Join(ANY, LEFT, domain)"
$CH --query "INSERT INTO bf1_rev FORMAT TSV" < /tmp/bf_rev.tsv

echo "helper tables: junk=$($CH --query 'SELECT count() FROM bf1_junk') class=$($CH --query 'SELECT count() FROM bf1_class') rev=$($CH --query 'SELECT count() FROM bf1_rev')"

for SHARD in $(seq 0 15); do
  echo "=== shard $SHARD $(date +%H:%M:%S)"
  # junk: only fill empty flags
  $CH --query "
    ALTER TABLE businesses UPDATE
      is_junk = joinGet('ls.bf1_junk', 'j', domain)
    WHERE cityHash64(domain) % 16 = $SHARD
      AND is_junk = ''
      AND joinGet('ls.bf1_junk', 'j', domain) != ''
    SETTINGS mutations_sync = 1"
  # class: only unclassified/weak rows; head conf becomes the stored confidence
  $CH --query "
    ALTER TABLE businesses UPDATE
      business_model = joinGet('ls.bf1_class', 'bm', domain),
      classification_confidence = joinGet('ls.bf1_class', 'conf', domain)
    WHERE cityHash64(domain) % 16 = $SHARD
      AND (business_model = '' OR classification_confidence < 0.55)
      AND joinGet('ls.bf1_class', 'bm', domain) != ''
      AND joinGet('ls.bf1_class', 'conf', domain) >= 0.5
    SETTINGS mutations_sync = 1"
  # revenue: only demote the brand-contaminated top band
  $CH --query "
    ALTER TABLE businesses UPDATE
      estimated_revenue = joinGet('ls.bf1_rev', 'r', domain),
      revenue_confidence = joinGet('ls.bf1_rev', 'conf', domain)
    WHERE cityHash64(domain) % 16 = $SHARD
      AND estimated_revenue IN ('\$100M-\$1B','\$1B+')
      AND joinGet('ls.bf1_rev', 'r', domain) IN ('<\$1M','\$1M-\$10M')
      AND joinGet('ls.bf1_rev', 'conf', domain) >= 0.5
    SETTINGS mutations_sync = 1"
done

echo "=== verification"
$CH --query "SELECT 'junk', is_junk, count() FROM businesses WHERE is_junk != '' GROUP BY is_junk ORDER BY 3 DESC FORMAT TSV"
$CH --query "SELECT 'head_rows', countIf(business_model != '' AND classification_confidence >= 0.5) FROM businesses FORMAT TSV"
$CH --query "SELECT 'still_pending', count() FROM system.mutations WHERE table='businesses' AND NOT is_done FORMAT TSV"
