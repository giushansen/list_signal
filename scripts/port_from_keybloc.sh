#!/bin/bash
# ============================================================================
# PORT PIPELINE MODULES FROM KEYBLOC → LISTSIGNAL
# ============================================================================
# Copies 14 enrichment modules, renames Keybloc→LS, patches CTL poller
# to feed WorkQueue instead of CSVWriter.
#
# Usage:  cd ~/Projects/list_signal && bash scripts/port_from_keybloc.sh ~/Projects/keybloc
# ============================================================================

set -euo pipefail
KB="${1:?Usage: $0 /path/to/keybloc}"
[[ ! -d "$KB/lib/keybloc" ]] && echo "✗ Not KeyBloc: $KB" && exit 1

rename() { sed 's/Keybloc\./LS./g; s/defmodule Keybloc/defmodule LS/g; s/alias Keybloc/alias LS/g; s/lib\/keybloc\//lib\/ls\//g' "$1" > "$2" && echo "  ✓ $2"; }

mkdir -p lib/ls/{ctl,dns,http,bgp}/signatures

echo "CTL:"
rename "$KB/lib/keybloc/ctl/poller.ex" lib/ls/ctl/poller.ex
rename "$KB/lib/keybloc/ctl/domain_parser.ex" lib/ls/ctl/domain_parser.ex
rename "$KB/lib/keybloc/ctl/shared_hosting_filter.ex" lib/ls/ctl/shared_hosting_filter.ex
rename "$KB/lib/keybloc/ctl/scorer.ex" lib/ls/ctl/scorer.ex

echo "DNS:"
rename "$KB/lib/keybloc/dns/resolver.ex" lib/ls/dns/resolver.ex
rename "$KB/lib/keybloc/dns/scorer.ex" lib/ls/dns/scorer.ex

echo "HTTP:"
rename "$KB/lib/keybloc/http/client.ex" lib/ls/http/client.ex
rename "$KB/lib/keybloc/http/tech_detector.ex" lib/ls/http/tech_detector.ex
rename "$KB/lib/keybloc/http/page_extractor.ex" lib/ls/http/page_extractor.ex
rename "$KB/lib/keybloc/http/ip_rate_limiter.ex" lib/ls/http/ip_rate_limiter.ex
rename "$KB/lib/keybloc/http/domain_filter.ex" lib/ls/http/domain_filter.ex
rename "$KB/lib/keybloc/http/performance_tracker.ex" lib/ls/http/performance_tracker.ex

echo "BGP:"
rename "$KB/lib/keybloc/bgp/resolver.ex" lib/ls/bgp/resolver.ex
rename "$KB/lib/keybloc/bgp/scorer.ex" lib/ls/bgp/scorer.ex

echo ""
echo "Patching CTL poller (WorkQueue instead of CSVWriter)..."

# Remove CSVWriter from aliases
sed -i 's/alias LS\.CTL\.{CSVWriter, /alias LS.CTL.{/g' lib/ls/ctl/poller.ex
sed -i 's/, CSVWriter}/}/g' lib/ls/ctl/poller.ex
sed -i '/alias LS\.CTL\.CSVWriter$/d' lib/ls/ctl/poller.ex

# Change ctl_track to capture return value
sed -i 's/Cache\.ctl_track(domain, cert_data\.ctl_subdomain_count)/track_result = Cache.ctl_track(domain, cert_data.ctl_subdomain_count)/g' lib/ls/ctl/poller.ex

# Replace CSVWriter.write with conditional WorkQueue.enqueue (only on :new)
sed -i 's/CSVWriter\.write(cert_data_with_scores)/if track_result == :new, do: LS.Cluster.WorkQueue.enqueue(cert_data_with_scores)/g' lib/ls/ctl/poller.ex

# Also handle the backfill variant if present
sed -i 's/CSVWriter\.write(Map\.merge(cert_data, scores))/if track_result == :new, do: LS.Cluster.WorkQueue.enqueue(Map.merge(cert_data, scores))/g' lib/ls/ctl/poller.ex

echo "  ✓ poller.ex patched"

echo ""
echo "Signatures:"
for f in tld.csv issuer.csv subdomain.csv shared_hosting_platforms.txt cctlds.txt; do
  [[ -f "$KB/lib/keybloc/ctl/signatures/$f" ]] && cp "$KB/lib/keybloc/ctl/signatures/$f" lib/ls/ctl/signatures/ && echo "  ✓ ctl/$f"
done
for f in txt.csv mx.csv; do
  [[ -f "$KB/lib/keybloc/dns/signatures/$f" ]] && cp "$KB/lib/keybloc/dns/signatures/$f" lib/ls/dns/signatures/ && echo "  ✓ dns/$f"
done
for f in tech.csv tools.csv cdn.csv blocked.csv server.csv content_type.csv response_time.csv high_value_tlds.txt; do
  [[ -f "$KB/lib/keybloc/http/signatures/$f" ]] && cp "$KB/lib/keybloc/http/signatures/$f" lib/ls/http/signatures/ && echo "  ✓ http/$f"
done
for f in asn_org.csv country.csv prefix.csv; do
  [[ -f "$KB/lib/keybloc/bgp/signatures/$f" ]] && cp "$KB/lib/keybloc/bgp/signatures/$f" lib/ls/bgp/signatures/ && echo "  ✓ bgp/$f"
done

echo ""
STRAY=$(grep -rn "Keybloc" lib/ls/ 2>/dev/null || true)
[[ -n "$STRAY" ]] && echo "⚠  Fix: $STRAY" || echo "✅ Done. $(find lib/ls -name '*.ex' | wc -l) modules, zero Keybloc refs."
echo ""
echo "NOT ported (removed by design — no files in ListSignal):"
echo "  ✗ csv_writer.ex csv_reader.ex pipeline.ex resume_helper.ex"
echo "  ✗ filename_timestamp.ex single_domain.ex cache/warmer.ex backfill.ex"
