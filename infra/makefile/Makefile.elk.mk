# ---- Makefile.elk.mk ----
ifndef ELK_MK_LOADED
ELK_MK_LOADED := 1

##@ ELK (Elasticsearch / Kibana / Logstash)

# -------- Defaults --------
ES_URL        ?= http://localhost:9200
KIBANA_URL    ?= http://localhost:5601
LOGSTASH_URL  ?= http://logstash:9600

WAIT_STATUS         ?= yellow
SNAPSHOT_REPO       ?= danipa-backups
ES_SNAPSHOT_FS_PATH ?= /usr/share/elasticsearch/snapshots
DATE                := $(shell date +%Y%m%d%H%M%S)
SNAP_NAME           ?= manual-$(DATE)

# Curl/auth flags
CURL_FLAGS := -fsS
ifdef ES_INSECURE
  CURL_FLAGS += -k
endif

ifdef ES_API_KEY
  AUTH_HDR := -H "Authorization: ApiKey $(ES_API_KEY)"
endif
ifdef ES_USER
  BASIC_AUTH := -u $(ES_USER):$(ES_PASSWORD)
endif

# --- Run curl either on host or in a tiny container attached to danipa-net ---
ifeq ($(USE_DOCKER_CURL),1)
  NET ?= danipa-net
  CURL_IMG ?= curlimages/curl:8.10.1
  curl_es = docker run --rm --network $(NET) $(CURL_IMG) $(CURL_FLAGS) $(AUTH_HDR) $(BASIC_AUTH)

  # Prefer internal DNS if defaults say localhost
  ifneq (,$(findstring localhost,$(ES_URL)))
    ES_URL := http://elasticsearch:9200
  endif
  ifneq (,$(findstring localhost,$(KIBANA_URL)))
    KIBANA_URL := http://kibana:5601
  endif
  ifneq (,$(findstring localhost,$(LOGSTASH_URL)))
    LOGSTASH_URL := http://logstash:9600
  endif
else
  curl_es = curl $(CURL_FLAGS) $(AUTH_HDR) $(BASIC_AUTH)
endif

.PHONY: elk-help elk-env es-health kibana-health logstash-health elk-health es-wait elk-detect \
        es-snapshot-repo-fs es-snapshot-repo-s3 es-snapshot-repo-get \
        es-snapshot-create es-snapshot-status es-snapshot-list es-snapshot-verify \
        es-restore-latest es-restore es-restore-verify elk-snapshot-validate

elk-help: ## Show categorized help for ELK targets only
	@awk 'BEGIN {FS=":.*##"; ORS=""; print "\n\033[1mELK targets\033[0m\n"} \
	/^##@/ { gsub(/^##@ /,"",$$0); printf "\n\033[1m%s\033[0m\n", $$0 } \
	/^[a-zA-Z0-9_.-]+:.*##/ { printf "  \033[36m%-24s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST); echo

elk-env: ## Print effective ELK environment variables
	@echo "ES_URL=$(ES_URL)"; \
	echo "KIBANA_URL=$(KIBANA_URL)"; \
	echo "LOGSTASH_URL=$(LOGSTASH_URL)"; \
	echo "WAIT_STATUS=$(WAIT_STATUS)"; \
	echo "SNAPSHOT_REPO=$(SNAPSHOT_REPO)"; \
	echo "ES_SNAPSHOT_FS_PATH=$(ES_SNAPSHOT_FS_PATH)"; \
	echo "INDICES=$(INDICES)"; \
	echo "SNAP_NAME=$(SNAP_NAME)"; \
	echo "ES_API_KEY=$(if $(ES_API_KEY),<set>,<empty>)"; \
	echo "ES_USER=$(if $(ES_USER),<set>,<empty>)"; \
	echo "ES_PASSWORD=$(if $(ES_PASSWORD),<set>,<empty>)"; \
	echo "ES_INSECURE=$(if $(ES_INSECURE),1,0)"

##@ Health
elk-detect: ## Detect HTTP/HTTPS and auth requirements for ES
	@echo ">> Probing $(ES_URL) (dockerized=$(if $(USE_DOCKER_CURL),yes,no))"
	@$(call curl_es) -m 5 $(ES_URL) || true
	@echo "\n>> /_cluster/health"
	@$(call curl_es) -m 5 "$(ES_URL)/_cluster/health" || true
	@echo "\nHints:"
	@echo " - If you see JSON and status, it's HTTP/no-auth."
	@echo " - If you see 'security_exception', set ES_API_KEY or ES_USER/ES_PASSWORD."
	@echo " - If TLS errors occur, switch ES_URL to https://... and set ES_INSECURE=1 (dev only)."

es-health: ## Print Elasticsearch cluster status (red/yellow/green)
	@echo ">> Elasticsearch cluster health ($(ES_URL))"
	@$(call curl_es) "$(ES_URL)/_cluster/health?pretty" | jq -r '.status'

kibana-health: ## Print Kibana overall level from /api/status
	@echo ">> Kibana status ($(KIBANA_URL))"
	@$(call curl_es) "$(KIBANA_URL)/api/status" | jq -r '.status.overall.level' || true

logstash-health: ## Print Logstash node status from /_node
	@echo ">> Logstash node ($(LOGSTASH_URL))"
	@$(call curl_es) "$(LOGSTASH_URL)/_node" | jq -r '.status' || true

elk-health: es-health kibana-health logstash-health ## Run health checks for ES, Kibana, and Logstash

es-wait: ## Wait until ES cluster health reaches $(WAIT_STATUS) or green (timeout ~120s)
	@echo ">> Waiting for cluster status $(WAIT_STATUS) ..."
	@for i in $$(seq 1 60); do \
	  s=$$($(call curl_es) "$(ES_URL)/_cluster/health" | jq -r '.status'); \
	  echo "attempt $$i: status=$$s"; \
	  [[ "$$s" == "$(WAIT_STATUS)" || "$$s" == "green" ]] && exit 0; \
	  sleep 2; \
	done; \
	echo "Cluster not $(WAIT_STATUS)/green after timeout" && exit 1

##@ Snapshot repository
es-snapshot-repo-fs: ## Create/Update a filesystem snapshot repo at $(ES_SNAPSHOT_FS_PATH)
	@echo ">> Create/Update FS snapshot repo $(SNAPSHOT_REPO) at $(ES_SNAPSHOT_FS_PATH)"
	@$(call curl_es) -X PUT "$(ES_URL)/_snapshot/$(SNAPSHOT_REPO)" \
	 -H "Content-Type: application/json" \
	 -d '{"type":"fs","settings":{"location":"$(ES_SNAPSHOT_FS_PATH)","compress":true}}' | jq

es-snapshot-repo-s3: ## Create/Update an S3 snapshot repo (requires S3_BUCKET, optional S3_BASE_PATH, S3_REGION)
	@if [ -z "$$S3_BUCKET" ]; then echo "S3_BUCKET required"; exit 1; fi
	@echo ">> Create/Update S3 snapshot repo $(SNAPSHOT_REPO) in bucket $$S3_BUCKET"
	@$(call curl_es) -X PUT "$(ES_URL)/_snapshot/$(SNAPSHOT_REPO)" \
	 -H "Content-Type: application/json" \
	 -d '{"type":"s3","settings":{"bucket":"'"$$S3_BUCKET"'","base_path":"'"$$S3_BASE_PATH"'", "region":"'"$$S3_REGION"'"}}' | jq

es-snapshot-repo-get: ## Show the current snapshot repository configuration
	@$(call curl_es) "$(ES_URL)/_snapshot/$(SNAPSHOT_REPO)?pretty" | jq

##@ Snapshot
es-snapshot-create: es-wait ## Create a snapshot ($(SNAP_NAME)) and wait for completion
	@echo ">> Creating snapshot $(SNAP_NAME) in repo $(SNAPSHOT_REPO)"
	@$(call curl_es) -X PUT "$(ES_URL)/_snapshot/$(SNAPSHOT_REPO)/$(SNAP_NAME)?wait_for_completion=true" \
	 -H "Content-Type: application/json" \
	 -d '{"indices":"*","ignore_unavailable":true,"include_global_state":true}' | jq '.snapshot.state'

es-snapshot-status: ## Show in-flight snapshot status
	@$(call curl_es) "$(ES_URL)/_snapshot/_status?pretty" | jq

es-snapshot-list: ## List snapshots (latest first)
	@$(call curl_es) "$(ES_URL)/_cat/snapshots/$(SNAPSHOT_REPO)?s=end_time:desc&h=id,start_time,end_time,state" | column -t

es-snapshot-verify: ## Verify a specific snapshot by name (requires SNAP_NAME)
	@if [ -z "$(SNAP_NAME)" ]; then echo "SNAP_NAME required"; exit 1; fi
	@echo ">> Verify snapshot $(SNAP_NAME)"
	@$(call curl_es) "$(ES_URL)/_snapshot/$(SNAPSHOT_REPO)/$(SNAP_NAME)?pretty" | jq -r '.snapshots[0].state'

##@ Restore
es-restore-latest: ## Restore the latest SUCCESS snapshot (indices=$(INDICES)) and wait
	@echo ">> Finding latest snapshot in $(SNAPSHOT_REPO)"
	@SN=$$($(call curl_es) "$(ES_URL)/_cat/snapshots/$(SNAPSHOT_REPO)?s=end_time:desc&h=id,state" | awk '$$2=="SUCCESS"{print $$1; exit}'); \
	if [ -z "$$SN" ]; then echo "No successful snapshots found"; exit 1; fi; \
	echo "Restoring snapshot: $$SN"; \
	$(call curl_es) -X POST "$(ES_URL)/_snapshot/$(SNAPSHOT_REPO)/$$SN/_restore" \
	 -H "Content-Type: application/json" \
	 -d '{"indices":"$(INDICES)","ignore_unavailable":true,"include_global_state":true,"partial":false,"rename_pattern":".*","rename_replacement":"$$0"}' | jq; \
	$(MAKE) es-wait

# Restore by explicit name: make es-restore SNAP_NAME=manual-20250101T010203 INDICES="logs-*"
es-restore: ## Restore a named snapshot (requires SNAP_NAME; set INDICES to scope) and wait
	@if [ -z "$(SNAP_NAME)" ]; then echo "SNAP_NAME required"; exit 1; fi
	@echo ">> Restoring $(SNAP_NAME) (indices=$(INDICES))"
	@$(call curl_es) -X POST "$(ES_URL)/_snapshot/$(SNAPSHOT_REPO)/$(SNAP_NAME)/_restore" \
	 -H "Content-Type: application/json" \
	 -d '{"indices":"$(INDICES)","ignore_unavailable":true,"include_global_state":true,"partial":false}' | jq
	@$(MAKE) es-wait

es-restore-verify: ## List indices after restore
	@echo ">> Indices after restore"
	@$(call curl_es) "$(ES_URL)/_cat/indices?v"

##@ Composite
elk-snapshot-validate: es-health es-snapshot-create es-snapshot-verify es-snapshot-list ## Create & validate a snapshot
	@echo ">> Snapshot validation complete for $(SNAP_NAME) in repo $(SNAPSHOT_REPO)"
endif
