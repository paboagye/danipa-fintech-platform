# ---- Makefile.db.mk ----
ifndef DB_MK_LOADED
DB_MK_LOADED := 1

##@ Database
AGENT_CONT ?= postgres-agent
PG_CONT ?= danipa-postgres-dev
DANIPA_NET ?= danipa-net
DB_USER ?= danipa_owner_dev
DB_NAME ?= danipa_fintech_db_dev
BACKUP_DIR ?= backups/db
APP_ENV ?= dev

define _default_dump_name
$(BACKUP_DIR)/$$(date +'%Y-%m-%d_%H%M%S')_$(DB).sql.gz
endef
DB ?= $(DB_NAME)

.PHONY: pg-whoami pg-dump pg-restore probe-db-perms db-health
pg-whoami: ## Show current_user/db/time
	@PASS="$$(docker exec $(AGENT_CONT) sh -lc "cat /opt/pg-secrets/POSTGRES_PASSWORD")"; \
	docker run --rm --network $(DANIPA_NET) -e PGPASSWORD="$$PASS" postgres:17-alpine \
	psql -h $(PG_CONT) -U $(DB_USER) -d $(DB_NAME) -c "select current_user, current_database(), now();"

pg-dump:  ## Dump $(DB) to gz file (OUT= to override)
	@mkdir -p "$(BACKUP_DIR)"
	@OUT="$${OUT:-$(_default_dump_name)}"; \
	PASS="$$(docker exec $(AGENT_CONT) sh -lc "cat /opt/pg-secrets/POSTGRES_PASSWORD")"; \
	docker run --rm --network $(DANIPA_NET) -e PGPASSWORD="$$PASS" postgres:17-alpine \
	  pg_dump -h $(PG_CONT) -U $(DB_USER) -d "$(DB)" --clean --if-exists --no-owner --no-privileges \
	  | gzip > "$$OUT"; echo "✓ Wrote $$OUT"

pg-restore: ## Restore FILE into $(DB)  (make pg-restore FILE=... [DB=...])
	@test -n "$(FILE)" || { echo "Usage: make pg-restore FILE=<dump.sql[.gz]> [DB=<dbname>]"; exit 2; }
	@test -f "$(FILE)" || { echo "ERROR: file not found: $(FILE)"; exit 2; }
	@PASS="$$(docker exec $(AGENT_CONT) sh -lc "cat /opt/pg-secrets/POSTGRES_PASSWORD")"; \
	if echo "$(FILE)" | grep -qi '\.gz$$'; then DECOMP="gzip -cd $(FILE)"; else DECOMP="cat $(FILE)"; fi; \
	$$DECOMP | docker run --rm --network $(DANIPA_NET) -i -e PGPASSWORD="$$PASS" postgres:17-alpine \
	psql -v ON_ERROR_STOP=1 -h $(PG_CONT) -U $(DB_USER) -d "$${DB:-$(DB)}"; echo "✓ Restore complete"

probe-db-perms: ## Probe DB grants/roles for $(APP_ENV) via infra/postgres/init/<env>/probe_db_perms.sh
	@SCRIPT="infra/postgres/init/$(APP_ENV)/probe_db_perms.sh"; \
	test -f "$$SCRIPT" || { echo "!! not found: $$SCRIPT"; exit 2; }; \
	chmod +x "$$SCRIPT" || true; \
	"$$SCRIPT"

db-health: ## Bring up agent+postgres and run the health check inside the DB container
	@docker compose up -d $(AGENT_CONT) $(PG_CONT)
	@docker compose exec -T $(PG_CONT) bash -lc 'pg_isready -U "$$POSTGRES_USER" -h 127.0.0.1 -p 5432'

endif
