# ---- Makefile.db-tools.mk ----
ifndef DB_TOOLS_MK_LOADED
DB_TOOLS_MK_LOADED := 1

##@ Database Tools (pgAdmin, dump/restore, quick psql)

# ------- shared defaults (override from .env or CLI) -------
DANIPA_NET            ?= danipa-net
AGENT_CONT            ?= postgres-agent
PG_CONT               ?= danipa-postgres-dev

DB_USER               ?= danipa_owner_dev
DB_NAME               ?= danipa_fintech_db_dev

# Backups
BACKUP_DIR            ?= backups/db
# Optional override per call: make pg-dump DB=my_other_db
DB                    ?= $(DB_NAME)

# pgAdmin wiring
PGADMIN_GROUP         ?= Danipa
PG_NAME               ?= Postgres-Dev
PG_HOST               ?= $(PG_CONT)
PG_PORT               ?= 5432
FORCE_PGADMIN_REIMPORT?= 0

# Helper: timestamped dump filename when OUT= not provided
define _dbtools_default_dump_name
$(BACKUP_DIR)/$$(date +'%Y-%m-%d_%H%M%S')_$(DB).sql.gz
endef

.PHONY: pgadmin-json pgadmin-restart pg-connect pg-query pg-whoami pg-dump pg-restore

# ---- write pgAdmin servers.json next to repo root ./pgadmin ----
pgadmin-json: ## Generate pgAdmin servers.json for $(PG_HOST):$(PG_PORT)
	@mkdir -p ./pgadmin
	@echo "-> Writing ./pgadmin/servers.json (Group=$(PGADMIN_GROUP), Host=$(PG_HOST):$(PG_PORT))"
	@cat > ./pgadmin/servers.json <<-JSON
	{
	  "Servers": {
	    "1": {
	      "Group": "$(PGADMIN_GROUP)",
	      "Name": "$(PG_NAME)",
	      "Host": "$(PG_HOST)",
	      "Port": $(PG_PORT),
	      "MaintenanceDB": "$(DB_NAME)",
	      "Username": "$(DB_USER)",
	      "SSLMode": "prefer"
	    }
	  }
	}
	JSON

# ---- bounce pgAdmin so it picks the new servers.json up ----
pgadmin-restart: ## Restart pgAdmin (optionally nukes its data volume if FORCE_PGADMIN_REIMPORT=1)
	@if [ "$(FORCE_PGADMIN_REIMPORT)" = "1" ]; then \
	  echo "-> Forcing pgAdmin to re-import servers.json (removing pgAdmin data volume)"; \
	  cid=$$(docker compose --profile dev ps -q pgadmin 2>/dev/null || true); \
	  [ -n "$$cid" ] && docker compose --profile dev rm -sf pgadmin >/dev/null || true; \
	  vol=$$(docker volume ls -q | grep -E '_pgadmin_data$$' | head -n1); \
	  [ -n "$$vol" ] && { echo "   Removing volume: $$vol"; docker volume rm -f "$$vol" || true; } || echo "   (No pgAdmin data volume found)"; \
	fi
	@docker compose --profile dev up -d pgadmin
	@echo "-> Waiting for pgAdmin health..."
	@for i in $$(seq 1 40); do \
	  st=$$(docker ps --filter name=danipa-pgadmin --format '{{.Status}}'); \
	  echo "$$st" | grep -qi healthy && { echo "   ✓ pgAdmin healthy"; exit 0; }; \
	  sleep 2; \
	done; \
	echo "WARN: pgAdmin not healthy yet; open http://localhost:8081 to check."

# ---- quick interactive psql using Vault-rendered password from postgres-agent ----
pg-connect: ## Open interactive psql to $(PG_CONT) as $(DB_USER) on $(DB_NAME)
	@PASS="$$(docker exec $(AGENT_CONT) sh -lc "cat /opt/pg-secrets/POSTGRES_PASSWORD")"; \
	[ -n "$$PASS" ] || { echo "ERROR: no password read from agent"; exit 1; }; \
	echo "-> Connecting to $(PG_CONT) as $(DB_USER) on $(DB_NAME) ..."; \
	docker run -it --rm --network $(DANIPA_NET) -e PGPASSWORD="$$PASS" postgres:17-alpine \
	  psql -h $(PG_CONT) -U $(DB_USER) -d $(DB_NAME)

# ---- run a single SQL command non-interactively ----
# usage: make pg-query SQL="select current_user, now();"
pg-query: ## Run a single SQL statement against $(DB_NAME) (SQL="...")
	@PASS="$$(docker exec $(AGENT_CONT) sh -lc "cat /opt/pg-secrets/POSTGRES_PASSWORD")"; \
	[ -n "$$PASS" ] || { echo "ERROR: no password read from agent"; exit 1; }; \
	docker run --rm --network $(DANIPA_NET) -e PGPASSWORD="$$PASS" postgres:17-alpine \
	  psql -h $(PG_CONT) -U $(DB_USER) -d $(DB_NAME) -c "$(SQL)"

pg-whoami: ## Convenience: whoami + db + time
	@$(MAKE) --no-print-directory pg-query SQL="select current_user, current_database(), now();"

# ---- dump/restore helpers ----
pg-dump:  ## Dump $(DB) to gz SQL (OUT=path.sql.gz to override; default under $(BACKUP_DIR))
	@mkdir -p "$(BACKUP_DIR)"
	@OUT="$${OUT:-$(_dbtools_default_dump_name)}"; \
	PASS="$$(docker exec $(AGENT_CONT) sh -lc "cat /opt/pg-secrets/POSTGRES_PASSWORD")"; \
	[ -n "$$PASS" ] || { echo "ERROR: no password read from agent"; exit 1; }; \
	echo "-> Dumping $(DB) from $(PG_CONT) to $$OUT ..."; \
	docker run --rm --network $(DANIPA_NET) -e PGPASSWORD="$$PASS" postgres:17-alpine \
	  pg_dump -h $(PG_CONT) -U $(DB_USER) -d "$(DB)" \
	    --clean --if-exists --no-owner --no-privileges \
	| gzip > "$$OUT"; \
	echo "✓ Wrote $$OUT"

# usage:
#   make pg-restore FILE=backups/db/2025-10-03_133500_danipa_fintech_db_dev.sql.gz
# optional:
#   make pg-restore FILE=... DB=my_other_db
pg-restore:  ## Restore FILE into $(DB) (auto-detects .gz)
	@test -n "$(FILE)" || { echo "Usage: make pg-restore FILE=<dump.sql[.gz]> [DB=<dbname>]"; exit 2; }
	@test -f "$(FILE)" || { echo "ERROR: file not found: $(FILE)"; exit 2; }
	@PASS="$$(docker exec $(AGENT_CONT) sh -lc "cat /opt/pg-secrets/POSTGRES_PASSWORD")"; \
	[ -n "$$PASS" ] || { echo "ERROR: no password read from agent"; exit 1; }; \
	echo "-> Restoring $(FILE) into database '$(DB)' on $(PG_CONT) ..."; \
	if echo "$(FILE)" | grep -qi '\.gz$$'; then DECOMP="gzip -cd $(FILE)"; else DECOMP="cat $(FILE)"; fi; \
	$$DECOMP \
	| docker run --rm --network $(DANIPA_NET) -i -e PGPASSWORD="$$PASS" postgres:17-alpine \
	    psql -v ON_ERROR_STOP=1 -h $(PG_CONT) -U $(DB_USER) -d "$(DB)"; \
	echo "✓ Restore complete"

probe-db-perms: ## Probe DB grants/roles for $(APP_ENV) via infra/postgres/init/<env>/probe_db_perms.sh
	@APP_ENV="$${APP_ENV:-dev}"; \
	SCRIPT="infra/postgres/init/$${APP_ENV}/probe_db_perms.sh"; \
	[ -f "$$SCRIPT" ] || { echo "ERROR: $$SCRIPT not found"; exit 2; }; \
	AGENT_CONT="$(AGENT_CONT)" \
	PG_CONT="$(PG_CONT)" \
	DANIPA_NET="$(DANIPA_NET)" \
	DB_USER="$(DB_USER)" \
	DB_NAME="$(DB_NAME)" \
	bash "$$SCRIPT"

endif
