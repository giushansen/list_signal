.PHONY: help setup dev dev-worker master worker clean

COOKIE ?= ls_prod
MASTER ?= master@10.0.0.1

help:
	@echo "ListSignal — Domain Intelligence (Distributed)"
	@echo ""
	@echo "  make setup       - Install deps + build assets"
	@echo "  make dev         - Local master (CTL + queue + dashboard at localhost:4000)"
	@echo "  make dev-worker  - Local worker (connects to master@127.0.0.1)"
	@echo "  make master      - Production master node"
	@echo "  make worker      - Production worker node"
	@echo "  make clean       - Clean build"

setup:
	mix deps.get
	mix assets.setup
	mix assets.build

# Local dev defaults:
#   LS_DNS_SERVER   — dev Macs have no local Unbound (prod pins 127.0.0.1)
#   LS_ADMIN_EMAILS — unlocks /admin for the seeded user
dev:
	LS_ROLE=master LS_MODE=ctl_live \
		LS_DNS_SERVER=1.1.1.1 LS_ADMIN_EMAILS=admin@listsignal.com \
		iex --name master@127.0.0.1 --cookie dev_cookie -S mix phx.server

dev-worker:
	LS_ROLE=worker LS_MASTER=master@127.0.0.1 LS_DNS_SERVER=1.1.1.1 \
		LS_BATCH_SIZE=100 LS_HTTP_CONCURRENCY=20 LS_DNS_CONCURRENCY=50 \
		iex --name worker_dev@127.0.0.1 --cookie dev_cookie -S mix

# Enrichment lane (pipeline 2). Needs the browser sidecar for blocked/JS pages:
#   make browser-sidecar   (in another terminal)
dev-enrichment:
	LS_ROLE=worker LS_LANES=enrichment LS_MASTER=master@127.0.0.1 \
		LS_DNS_SERVER=1.1.1.1 LS_BROWSER_URL=http://127.0.0.1:8900 \
		iex --name worker_enrich@127.0.0.1 --cookie dev_cookie -S mix

# Both lanes on one node, as a big worker or the home NUC would run.
dev-worker-both:
	LS_ROLE=worker LS_LANES=discovery,enrichment LS_MASTER=master@127.0.0.1 \
		LS_DNS_SERVER=1.1.1.1 \
		LS_BATCH_SIZE=100 LS_HTTP_CONCURRENCY=20 LS_DNS_CONCURRENCY=50 \
		LS_BROWSER_URL=http://127.0.0.1:8900 \
		iex --name worker_both@127.0.0.1 --cookie dev_cookie -S mix

# camoufox/nodriver sidecar (max 3 concurrent renders, 1s per target IP).
browser-sidecar:
	LS_BROWSER_PORT=8900 \
		~/.listsignal-browser/venv/bin/python ../devops/listsignal/browser_sidecar.py

master:
	LS_ROLE=master LS_MODE=ctl_live \
		iex --name master@$$(hostname -I | awk '{print $$1}') --cookie $(COOKIE) -S mix phx.server

worker:
	LS_ROLE=worker LS_MASTER=$(MASTER) LS_DNS_CONCURRENCY=500 \
		iex --name worker_$$(hostname -s)@$$(hostname -I | awk '{print $$1}') --cookie $(COOKIE) -S mix

clean:
	rm -rf _build deps