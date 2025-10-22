
# ![Danipa Logo](https://raw.githubusercontent.com/paboagye/danipa-assets/main/images/danipa_logo.png)

# 🧭 Danipa Fintech Platform — Modular Makefile Suite

The **Danipa Fintech Platform** Makefile suite modularizes build, bootstrap, and operations tasks for the ecosystem — including Docker/Compose, Vault, Keycloak, Config Server, Eureka, Fintech microservices, ELK, and Database utilities.

It provides **category-driven help**, **idempotent actions**, and **developer-friendly shortcuts** for both day-to-day operations and CI/CD automation.

---

# ![Makefile Banner](https://raw.githubusercontent.com/paboagye/danipa-assets/main/images/makefile-banner-dark.png)

---

## 📘 Overview

Each Makefile module under `infra/makefile/` contributes a feature area.  
Running `make help` aggregates all visible targets, grouped by category (with icons).

```bash
make help
```

Example (truncated):

```
Boostrap Keycloak & Vault
  bootstrap-keycloak-vault      Bootstrap Keycloak realm and seed Vault secrets
...
```

---

## 🗺️ Layout

```
Makefile                      # Root (thin orchestrator; .env loader; help)
infra/makefile/
  ├─ Makefile.core.mk         # Core vars, UX/help, shared conventions
  ├─ Makefile.compose.mk      # 🐳 Docker / Compose lifecycle & helpers
  ├─ Makefile.vault.mk        # 🔐 Vault management, auth, policies, seeding
  ├─ Makefile.common.mk       # 🧰 Shared helpers (imported once)
  ├─ Makefile.config.mk       # ⚙️ Config Server (compose, build, actuator)
  ├─ Makefile.eureka.mk       # 🛰️ Eureka Server (compose, build, actuator)
  ├─ Makefile.fintech.mk      # 💸 Fintech Service (agent, compose, actuator)
  ├─ Makefile.bootstrap.mk    # 🧭 Bootstrap (Keycloak & Vault + certs)
  ├─ Makefile.elk.mk          # 📦 ELK (Elasticsearch/Kibana/Logstash)
  ├─ Makefile.db-tools.mk     # 🐘 DB Tools (pgAdmin, psql, dump/restore)
  ├─ Makefile.db-health.mk    # 🩺 DB health checks / probes
  └─ Makefile.submodules.mk   # 🌐 Git submodules helpers
```

> **Note:** The order above mirrors the `include` order in your **root Makefile**.

---

## 🧭 Bootstrap (Keycloak & Vault)  <!-- from Makefile.bootstrap.mk -->

### Targets
- `bootstrap` — Composite convenience entry (idempotent).
- `bootstrap-keycloak-vault` — Bootstrap **Keycloak realm/clients** & **seed Vault secrets** (calls `infra/vault/scripts/bootstrap-keycloak-and-vault.sh` → `write-secrets.sh`).
- `bootstrap-keycloak-vault-dry-run` — Show planned steps without changing state.
- `bootstrap-keycloak-vault-verify` — Verify Keycloak well-known + Vault KV tree.
- `vault-bootstrap` — Alias to `bootstrap-keycloak-vault`.

### Usage

```bash
# Dry run
make bootstrap-keycloak-vault-dry-run

# Full apply
make bootstrap-keycloak-vault

# Verify
make bootstrap-keycloak-vault-verify
```

**Environment overrides** (examples):

```bash
VAULT_ADDR=https://vault.local.danipa.com \
VAULT_CACERT=infra/vault/tls/root_ca.crt \
KEYCLOAK_URL=https://keycloak.local.danipa.com \
SEEDS_DIR=infra/vault/seeds/dev \
CURL_FORCE_RESOLVE=1 \
make bootstrap-keycloak-vault
```

---

## 🐳 Docker / Compose  <!-- from Makefile.compose.mk -->

```bash
make network                # Create external Docker network (idempotent)
make up                     # Bring up all services (detached)
make up-core                # Bring up core stack
make down                   # Stop and remove containers
make ps                     # Show compose services
make logs SERVICE=fintech-service
make bash SERVICE=fintech-service
make restart SERVICE=config-server
make compose-config         # Print merged compose file config (debug)
make clean-volumes          # Remove containers + anonymous volumes
make prune                  # Prune dangling images/networks/volumes
```

**Examples**

```bash
make up-core
make logs SERVICE=danipa-fintech-service
make bash SERVICE=keycloak
```

---

## 🔐 Vault Management (init, unseal, health, certs, seeding)  <!-- from Makefile.vault.mk -->

### Initialization / Unseal
```bash
make vault-init
make vault-unseal
make vault-unseal-3
make vault-status
```

### Health / Cert
```bash
make vault-health
make vault-cert
make vault-cert-dry-run
make vault-cert-verify
```

### Seeding / Policies
```bash
make vault-seed
make vault-verify
make vault-policy-attach
make vault-clean
```

### Auth / Tokens
```bash
make vault-login-root
make vault-login VAULT_LOGIN_TOKEN=<token>
make vault-mint-token
make vault-whoami
make vault-logout
```

### Inspection / Mounts
```bash
make vault-mounts
make vault-ls-any SECRET_PATH=secret/danipa/fintech
make vault-ls-parent
make vault-put SECRET_PATH=secret/danipa/fintech/dev/demo K=foo V=bar
make vault-del SECRET_PATH=secret/danipa/fintech/dev/demo
make vault-purge SECRET_PATH=secret/danipa/fintech/dev/demo
```

### Inspection / Browse
```bash
make vault-env                     # Debug: show exact env & command
make vault-ls SECRET_PATH=secret/danipa/fintech
make vault-read SECRET_PATH=secret/danipa/fintech/dev/demo
make vault-read-json SECRET_PATH=secret/...
make vault-read-json-raw SECRET_PATH=secret/...
make vault-token                   # Show token (first 16 chars)
make vault-cli                     # Interactive shell with VAULT_* preset
```

---

## ⚙️ Config Server  <!-- from Makefile.config.mk -->

### Compose
```bash
make config-service-up
make config-service-logs
make config-bash
```

### Build
```bash
make build-config
make show-config-git
```

### Actuator (inside container, HTTPS + CA)
```bash
make config-act-health
make config-act-info
make config-act-env
make config-act-metrics
make config-refresh
make config-busrefresh
```

### Actuator (external)
```bash
make config-ext-health
make config-ext-info
make config-ext-env
make config-ext-refresh
make config-ext-busrefresh
```

**Example**

```bash
CONFIG_ACT_EXT_BASE=https://config.local.danipa.com make config-ext-health
```

---

## 🛰️ Eureka Server  <!-- from Makefile.eureka.mk -->

### Compose
```bash
make eureka-service-up
make eureka-service-logs
make eureka-bash
```

### Build
```bash
make build-eureka
make show-eureka-git
```

### Actuator
```bash
make eureka-act-health
make eureka-act-info
make eureka-act-env
```

### Actuator (external)
```bash
make eureka-ext-health
make eureka-ext-info
make eureka-ext-env
```

---

## 💸 Fintech Service  <!-- from Makefile.fintech.mk -->

### Compose & Lifecycle
```bash
make fintech-agent-up
make fintech-service-up
make fintech-up
make fintech-service-logs
```

### Build
```bash
make build-fintech
make show-fintech-git
```

### Actuator (inside container)
```bash
make fintech-act-health
make fintech-act-info
make fintech-act-env
make fintech-act-metrics
make fintech-act-metric NAME=jvm.memory.used Q='?tag=area:heap'
make fintech-act-mappings
make fintech-act-beans
make fintech-act-configprops
make fintech-act-refresh
make fintech-act-busrefresh
```

### Actuator (inside container, HTTP convenience)
```bash
make fintech-refresh
make fintech-busrefresh
```

### Troubleshooting
```bash
make fintech-env-check
```

**Examples**
```bash
FIN_SERVICE=danipa-fintech-service make fintech-service-logs
make fintech-act-metric NAME=http.server.requests Q='?tag=uri:/ms/actuator/health'
```

---

## 📦 ELK (Elasticsearch / Logstash / Kibana)  <!-- from Makefile.elk.mk -->

### Health
```bash
make elk-detect
make es-health
make kibana-health
make logstash-health
make elk-health
make es-wait WAIT_STATUS=yellow
```

### Snapshot repository
```bash
make es-snapshot-repo-fs
make es-snapshot-repo-s3 S3_BUCKET=my-bucket S3_REGION=us-east-1
make es-snapshot-repo-get
```

### Snapshot
```bash
make es-snapshot-create SNAP_NAME=pre-deploy-$(date +%F)
make es-snapshot-status
make es-snapshot-list
make es-snapshot-verify SNAP_NAME=my-snapshot
```

### Restore
```bash
make es-restore-latest INDICES='*'
make es-restore SNAP_NAME=my-snapshot INDICES='index-*'
make es-restore-verify
```

### Composite
```bash
make elk-snapshot-validate
```

---

## 🐘 Database Tools  <!-- from Makefile.db-tools.mk -->

```bash
make pgadmin-json
make pgadmin-restart
make pg-connect
make pg-query SQL='select now();'
make pg-whoami
make pg-dump OUT=backup.sql.gz
make pg-restore FILE=backup.sql.gz
make probe-db-perms
make db-health
```

**Examples**
```bash
DB_NAME=danipa_fintech_db_dev DB_USER=danipa_app_dev make pg-connect
make pg-dump OUT=backup.$(date +%F).sql.gz
```

---

## 🌐 Git Submodules  <!-- from Makefile.submodules.mk -->

```bash
make submodules-sync
make submodules-check
make submodules-diff
```

---

## 🧠 Tips & FAQ

- `make help` → shows **all categories** with icons.
- `make <target> -n` → dry-run any target.
- Use `.env` to persist environment variables.
- Most targets are **idempotent**; re-running is safe.

---

<p align="center"><em>Danipa • Developer Experience, Secure by Design</em></p>
