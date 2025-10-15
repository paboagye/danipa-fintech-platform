
# ![Danipa Logo](images/danipa_logo.png)

# Danipa Fintech Platform – Application & Vault Management Guide

This guide explains how to **build, run, and manage the Danipa Fintech Platform** services, including **Vault TLS & secrets**, **Config Server**, **Eureka**, **Fintech Service**, and supporting infrastructure.

It applies to **Docker Compose environments** where Vault, Config, and services run together with Kafka, Redis, and Postgres.

---

## 📌 Purpose

- Standardize workflow with a **Makefile** for all services.
- Automate **Vault TLS certificate issuance**, unsealing, and secrets seeding.
- Provide repeatable steps to **bring up/down the stack**, **check health**, and **debug services**.
- Simplify developer onboarding and local testing.

---

## 🔑 Prerequisites

- Docker & Docker Compose installed.
- `make` installed locally.
- Root CA file available: `infra/vault/tls/root_ca.crt`.
- Vault initialized with keys under `infra/vault/keys/`.

---

## ⚙️ Key Makefile Targets

### 🔹 Platform Orchestration

- `make up` → bring up **all services**.
- `make up-core` → bring up **Vault, Config, Eureka, Fintech, DB, Redis, Kafka, Keycloak**.
- `make down` → stop all services.
- `make logs SERVICE=fintech-service` → tail logs for a container.
- `make bash SERVICE=config-server` → shell into a container.
- `make restart SERVICE=eureka-server` → restart one service.
- `make ps` → show running services.

---

### 🔹 Environment & Health

- `make env` → print important environment variables.
- `make health` → run health checks for Vault, Config, Eureka, Fintech.
- `make wait-core` → wait until core services report healthy.

---

### 🔹 Vault TLS & Certificate Management

- `make vault-cert CN=<hostname> SANS="alt1 alt2"` → issue and reload Vault TLS certificate.
- `make vault-status` → check Vault seal status inside the container.
- `make vault-unseal` → unseal Vault with env var `UNSEAL_KEY` or file `infra/vault/keys/vault-unseal.key`.
- `make vault-health [CN=...]` → check Vault HTTPS API health.

---

### 🔹 Vault Secrets Management

- `make secrets-dev` → seed secrets for **dev** environment from `dev.json`.
- `make secrets-staging` → seed secrets for staging.
- `make secrets-prod` → seed secrets for production.
- `make secrets-verify` → dry-run across all envs to validate Vault writes.

---

### 🔹 Developer Shortcuts

- `make dev-up-fast` → bring up core stack, wait, and check health.
- `make e2e` → bring up stack and seed dev secrets in one step.

---

## 🔍 Verification

Example: check Fintech service health

```bash
make health-fintech
```

✅ Expected output:

```json
{
  "status": "UP",
  "components": {
    "db": { "status": "UP" },
    "diskSpace": { "status": "UP" }
  }
}
```

---

## 🛡️ Best Practices

- Always run `make secrets-verify` before seeding prod secrets.
- Keep `infra/vault/tls/` and `infra/vault/keys/` secure and versioned separately.
- Rotate Vault certs proactively before expiry.
- Use `make logs` and `make bash` for debugging services.

---

## 🔧 Troubleshooting

- If Vault reports `sealed=true`, run `make vault-unseal`.
- During startup, health checks may fail briefly with `connection refused`. Retry after a few seconds.
- Use `make compose-config` to debug the final merged docker-compose config.

---

> **Summary**:  
> This guide standardizes the workflow for **running the entire Danipa Fintech Platform locally**, covering Vault TLS & secrets, service orchestration, and developer workflows in one place.
