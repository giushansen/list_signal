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

dev:
	LS_ROLE=master LS_MODE=ctl_live \
		iex --name master@127.0.0.1 --cookie dev_cookie -S mix phx.server

dev-worker:
	LS_ROLE=worker LS_MASTER=master@127.0.0.1 \
		LS_BATCH_SIZE=100 LS_HTTP_CONCURRENCY=20 LS_DNS_CONCURRENCY=50 \
		iex --name worker_dev@127.0.0.1 --cookie dev_cookie -S mix

master:
	LS_ROLE=master LS_MODE=ctl_live \
		iex --name master@$$(hostname -I | awk '{print $$1}') --cookie $(COOKIE) -S mix phx.server

worker:
	LS_ROLE=worker LS_MASTER=$(MASTER) LS_DNS_CONCURRENCY=500 \
		iex --name worker_$$(hostname -s)@$$(hostname -I | awk '{print $$1}') --cookie $(COOKIE) -S mix

clean:
	rm -rf _build deps