# ![Danipa Logo](./images/danipa_logo.png)

# Danipa Fintech Platform -- Unified Setup & Runbook

This document is the **single source of truth** for configuring,
running, and maintaining the Danipa Fintech Platform.\
It integrates previous runbooks (Config Server, Vault, Key Management
Strategy) into one comprehensive guide.

------------------------------------------------------------------------

## 📖 Overview

The **Danipa Fintech Platform** is a Spring Boot 3 microservice
ecosystem designed for secure and scalable financial applications.\
It integrates **MTN MoMo APIs (Remittance, Collections,
Disbursements)**, with a roadmap for PayPal, Stripe, and additional
fintech services.

Core services:

-   **Config Server** -- Centralized configuration via Git + Vault
    (composite backend).\
-   **Eureka Server** -- Service discovery and registry.\
-   **Fintech Service** -- Core API service (MoMo flows, payment
    orchestration).\
-   **Vault** -- Secrets management with AppRole and Vault Agents.\
-   **Postgres** -- Persistence (with Flyway migrations and RLS).\
-   **Kafka, Redis, ELK stack** -- Event bus, caching, observability.

------------------------------------------------------------------------

## 🔑 Key Management Strategy

We use **Vault AppRole + Vault Agents** with template rendering for all
services.\
No sensitive values are stored in `docker-compose.yml` or `.env.*`
files.

-   **Vault AppRole IDs/Secrets** live under `infra/vault/approle/*`.\
-   **Vault Agents** authenticate via AppRole and render secrets into
    `/opt/secrets/config-client.env`.\
-   **Spring services** source secrets by sourcing this env file before
    starting.\
-   **Postgres** password files are injected at runtime by
    `postgres-agent`.

This ensures: - **No hardcoded credentials**.\
- **Secrets auto-rotation** without container restarts (via
`kill -HUP 1`).\
- **Separation of concerns** (services don't talk to Vault directly).

------------------------------------------------------------------------

## 📂 Repository Layout

    danipa-fintech-platform/
    ├── infra/
    │   ├── vault/
    │   │   ├── approle/          # Role ID & Secret ID per service (dev/stg/prod)
    │   │   ├── agents/           # Vault Agent .hcl configs (per service)
    │   │   ├── templates/        # Vault Agent templates (.ctmpl)
    │   │   └── seeds/            # JSON secrets for dev seeding
    │   └── logo_color_eps.png    # Danipa logo
    ├── danipa-config-server/     # Config Server
    ├── danipa-eureka-server/     # Eureka
    ├── danipa-fintech-service/   # Core fintech service
    ├── docker-compose.yml        # Full infra + services definition
    └── README.md                 # This file (integrated runbook)

------------------------------------------------------------------------

## ⚙️ Vault Agents

Each service has a dedicated Vault Agent config in
`infra/vault/agents/`:

-   **config-server-agent.hcl** → renders `config-client.env` for Config
    Server.\
-   **eureka-agent.hcl** → renders `config-client.env` for Eureka.\
-   **fintech-agent.hcl** → renders `config-client.env` for Fintech
    Service.\
-   **postgres-agent.hcl** → injects `POSTGRES_PASSWORD` file for
    Postgres.

Templates in `infra/vault/templates/*.ctmpl` define which secrets are
rendered. Example:

``` hcl
# config-client.fintech.env.ctmpl
{{- with secret "secret/data/danipa-fintech-service,dev" -}}
SPRING_DATASOURCE_URL="{{ .Data.data.SPRING_DATASOURCE_URL }}"
SPRING_DATASOURCE_USERNAME="{{ .Data.data.SPRING_DATASOURCE_USERNAME }}"
SPRING_DATASOURCE_PASSWORD="{{ .Data.data.SPRING_DATASOURCE_PASSWORD }}"
{{- end }}
```

Vault Agent automatically reloads configs if secrets change.

------------------------------------------------------------------------

## 🐳 Docker Compose

Services defined in `docker-compose.yml`:

-   **vault** -- dev Vault instance.\
-   **config-server** + **config-server-agent**.\
-   **eureka-server** + **eureka-agent**.\
-   **fintech-service** + **fintech-agent**.\
-   **postgres-dev** + **postgres-agent** (password injected).\
-   **redis, kafka, elasticsearch, logstash, kibana** -- infra stack.\
-   **pgadmin** (optional dev convenience).

### Example: Config Server Startup

``` yaml
command:
  - sh
  - -lc
  - |
    if [ -f /opt/secrets/.vault-token ]; then
      export SPRING_CLOUD_VAULT_TOKEN="$(cat /opt/secrets/.vault-token)"
    fi
    . /opt/secrets/config-client.env 2>/dev/null || true
    exec java -jar /app/app.jar
```

------------------------------------------------------------------------

## 🌱 Vault Seeding

Development secrets are bootstrapped using `infra/vault/seeds/dev.json`:

``` json
{
  "paths": {
    "danipa-fintech-service,dev": {
      "POSTGRES_USER_DEV": "danipa_owner_dev",
      "POSTGRES_PASSWORD_DEV": "changeMeDev!",
      "SPRING_DATASOURCE_URL": "jdbc:postgresql://postgres-dev:5432/danipa_fintech_db_dev",
      "SPRING_DATASOURCE_USERNAME": "danipa_app_dev",
      "SPRING_DATASOURCE_PASSWORD": "changeMeAppDev!",
      "OAUTH_CLIENT_SECRET": "DLgD3Se22sFiThFduyI1Z6BRpTxTw5bifBdBp5D4r60="
    }
  }
}
```

Seeded via:

``` powershell
cd infra/vault/scripts
./write-dev-secrets.ps1 -JsonPath ../seeds/dev.json -VaultUri "http://127.0.0.1:18300" -Token <root_token>
```

------------------------------------------------------------------------

## 🔐 Security Model

-   **Dev/CI** → AppRole + Vault Agent, Basic auth between services.\
-   **Prod** → Vault Agent + mTLS between services.\
-   **Rotation** → Secrets are short-lived, Vault Agent refreshes
    automatically.\
-   **No credentials** appear in compose, .env, or repo files.

------------------------------------------------------------------------

## 🚀 Deployment Notes

-   **Local Dev** -- `docker compose --profile dev up`.\
-   **Staging/Prod** -- use `postgres-staging`, `postgres-prod`
    profiles.\
-   **Config Server** can scale horizontally since Vault Agent renders
    per pod.\
-   **Future** -- upgrade to OIDC/JWT auth for Config Server and
    services.

------------------------------------------------------------------------

## 📘 Next Steps

1.  Test end-to-end service startup
    (`vault → config-server → eureka → fintech`).\
2.  Verify secrets rotate and reload correctly (`vault kv put …`).\
3.  Add staging/prod AppRole IDs under `infra/vault/approle/`.\
4.  Move toward **mTLS in prod** for Config Server & Eureka.

------------------------------------------------------------------------

© 2025 Danipa Business Systems Inc. -- All Rights Reserved.
