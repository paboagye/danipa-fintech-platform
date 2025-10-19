<p align="center">
  <img src="docs/img/makefile-banner-dark.png" alt="Danipa Makefile Suite" width="80%"/>
</p>

<h1 align="center">Danipa Fintech Platform — Modular Makefile Suite</h1>

<p align="center">
  <img src="docs/img/danipa_logo.png" alt="Danipa" height="54"/>
</p>

> **Goal:** split the monolithic `Makefile` into small, focused modules included from a thin root file.
> This mirrors the new `db-health` pattern and keeps targets discoverable, maintainable, and reusable.

---

## 🧭 What you get

- **Clear structure**: one root `Makefile` + many `infra/makefile/Makefile.*.mk` includes
- **Composability**: enable/disable feature sets with `include` guards
- **Dev UX**: categorized help, consistent icons, and safe defaults
- **Parity**: works on Linux/macOS/WSL; CRLF-safe where relevant

---

## 📦 Layout

```
Makefile                      # thin root (help + includes)
infra/makefile/
  ├─ Makefile.core.mk         # base vars, helpers, help
  ├─ Makefile.docker.mk       # docker/compose helpers
  ├─ Makefile.vault.mk        # vault ops, certs, seeds
  ├─ Makefile.db.mk           # DB bootstrap, dump/restore, psql helpers
  ├─ Makefile.db-health.mk    # ✅ already in use (health probe)
  ├─ Makefile.elk.mk          # elastic/kibana/logstash helpers
  ├─ Makefile.actuator.mk     # actuator queries (internal + external)
  ├─ Makefile.fintech.mk      # fintech-service & agent lifecycles
  ├─ Makefile.hosts.mk        # hosts file helpers
  └─ Makefile.git.mk          # submodules & repo utilities
docs/img/
  ├─ danipa_logo.png
  └─ makefile-banner-dark.png
```

> **Tip:** keep each file below ~300–400 lines. Prefer small, task-focused modules over one big kitchen sink.

---

## 🧩 Root `Makefile` (example)

```make
SHELL := /bin/bash
.DEFAULT_GOAL := help
.ONESHELL:

ifneq (,$(wildcard .env))
include .env
export
endif

# --- include order matters: defs → features → extras ---
include infra/makefile/Makefile.core.mk      # vars, hdr/help, wait_http, icons
include infra/makefile/Makefile.docker.mk    # compose/net targets
include infra/makefile/Makefile.vault.mk     # vault ops, certs, seeds
include infra/makefile/Makefile.db.mk        # db bootstrap/dump/restore
include infra/makefile/Makefile.db-health.mk # health probe (existing)
include infra/makefile/Makefile.elk.mk       # elastic/kibana/logstash
include infra/makefile/Makefile.actuator.mk  # actuator (internal/external)
include infra/makefile/Makefile.fintech.mk   # service + agent
include infra/makefile/Makefile.hosts.mk     # hosts helpers
include infra/makefile/Makefile.git.mk       # submodules, diffs

.PHONY: help
help:
	@awk 'BEGIN {FS = ":.*##"; printf "\nDanipa Fintech Platform - Makefile\n\nUsage:\n  make \033[36m<target>\033[0m\n\nTargets:\n"} 	/^[a-zA-Z0-9_\-]+:.*##/ { printf "  \033[36m%-28s\033[0m %s\n", $$1, $$2 } 	/^##@/                 { printf "\n\033[1m%s\033[0m\n", substr($$0,5) } ' $(MAKEFILE_LIST)
```

---

## 🛠️ Migration steps

1. **Carve out core helpers**
   - Move `hdr`, `wait_http`, `JQ`, common URLs/paths to `Makefile.core.mk`.
2. **Split by concern**
   - Docker/Compose → `Makefile.docker.mk`
   - Vault (init/unseal/certs/seeds) → `Makefile.vault.mk`
   - DB (bootstrap/dump/restore/psql) → `Makefile.db.mk`
   - ELK (health, snapshot, restore) → `Makefile.elk.mk`
   - Actuator helpers → `Makefile.actuator.mk`
   - Fintech service/agent → `Makefile.fintech.mk`
   - Hosts utilities → `Makefile.hosts.mk`
   - Git/Submodules → `Makefile.git.mk`
3. **Keep `db-health` as-is**
   - It’s already modular. Ensure it stays CRLF-safe.
4. **Tag targets with `##`** for nice help output.
5. **Guard optional blocks** with `ifndef X_MK_LOADED` markers to avoid double-includes.

---

## 🚀 Quickstart

```bash
# See all targets (from all includes)
make help

# Bring up core stack
make up-core

# Run Postgres health (modular include you already have)
make db-health

# Seed DEV secrets (Vault)
make secrets-dev

# Snapshot ES
make es-snapshot-create
```

---

## 🧪 Conventions & icons

- Sections: `##@ Category` (shows as header in `make help`)
- Each target: `target: ## Description`
- Icons (suggested): 🔐 Vault • 🐘 Postgres • 🐳 Docker • 📦 ELK • ⚙️ Actuator • 🧩 Core • 🌐 Hosts • 🧭 Git

---

## 🆘 Troubleshooting

- **Clock skew warnings** when editing on Windows → run:  
  `sed -i 's/$//' infra/makefile/*.mk`
- **Compose service not found** → verify service keys in `docker-compose.yml`
- **Vault TLS issues** → confirm CA file and `--resolve` pins in scripts

---

## ✅ Done already

- `Makefile.db-health.mk` working and CRLF-normalized
- Verified `postgres-agent` + `danipa-postgres-dev` connectivity from the health check

---

## 📌 Next up

- Extract: core, docker, vault, db, elk, actuator, fintech, hosts, git
- Replace inline targets in the root Makefile with the `include` lines above
- Keep category order and small file sizes for maintainability

---

<p align="center"><em>Danipa • Developer Experience, but make it delightful.</em></p>
