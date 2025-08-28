# ![Danipa Logo](../images/danipa_logo.png)

# Danipa Config Server Setup & Runbook

This document explains how to configure, run, and maintain the **Danipa Config Server**.  
It complements the [Platform Stack Runbook](../Danipa_Platform_Stack_Runbook.md) and Vault guide.

---

## 📦 Service Overview

`danipa-config-server` is the **centralized configuration service** for the Danipa Fintech Platform.  
It provides:

- Centralized management of environment configs (dev, staging, prod)  
- Integration with **Vault** (secrets) and **Git repo** (application YAMLs)  
- Config refresh via **Spring Cloud Bus** (Kafka)  
- Secure basic authentication for config endpoints  

It runs under Docker Compose or standalone, serving configs to Fintech Service, Eureka, and others.

---

## 📌 Prerequisites

- **Docker** and **Docker Compose**  
- **Java 24** (for local build/run outside Docker)  
- **Maven**  
- **Vault** initialized and seeded with secrets (if used)  
- **Config repo** accessible (local bind mount or GitHub with token)  
- `.env.dev` file in repo root with values (see example below)  

---

## ⚙️ Configuration

### Environment Variables

Example `.env.dev`:

```env
# App
SPRING_PROFILES_ACTIVE=dev

# Config Server
CONFIG_USER=cfg-user
CONFIG_PASS=cfg-pass
CONFIG_HEALTH_URL=http://127.0.0.1:8088/actuator/health
CONFIG_HEALTH_CURL=sh -c "curl -fsS -u $$CONFIG_USER:$$CONFIG_PASS $$CONFIG_HEALTH_URL | grep -q '\"status\":\"UP\"'"

# Vault
VAULT_HOST=vault
VAULT_PORT=8200
VAULT_ROLE_ID=<injected-role-id>
VAULT_SECRET_ID=<injected-secret-id>

# Git repo (fallback if vault not used)
CONFIG_REPO_URI=file:///config-repo
CONFIG_REPO_PATHS=danipa-fintech-service,danipa-eureka-server
```

### application.yml (excerpt)

```yaml
server:
  port: 8088

spring:
  application:
    name: danipa-config-server
  profiles:
    active: composite
  config:
    server:
      composite:
        - type: vault
          host: ${VAULT_HOST:vault}
          port: ${VAULT_PORT:8200}
          scheme: http
          backend: secret
          defaultKey: danipa/config
          kvVersion: 2
          authentication: APPROLE
          app-role:
            role-id: ${VAULT_ROLE_ID}
            secret-id: ${VAULT_SECRET_ID}
        - type: git
          uri: ${CONFIG_REPO_URI:file:///config-repo}
          searchPaths: ${CONFIG_REPO_PATHS:}
          cloneOnStart: true
  security:
    user:
      name: ${CONFIG_USER}
      password: ${CONFIG_PASS}
```

---

## 🚀 Running Locally

### 1. Build the Service
```powershell
mvn clean package -DskipTests
```

### 2. Run with Docker Compose
```powershell
docker compose --env-file .env.dev -f docker-compose.yml up -d danipa-config-server
```

### 3. Run Natively
```powershell
mvn spring-boot:run -Dspring-boot.run.profiles=dev
```

---

## 🔐 Secrets & Config Repo

The Config Server pulls configuration from:  

- **Vault** → `secret/<domain>/<env>` (preferred)  
- **Git repo** → `/config-repo/<service>/<profile>.yml`  

Example paths:  

- Vault: `secret/config/dev` → app credentials  
- Git: `danipa-fintech-service/danipa-fintech-service-dev.yml`  

Verify Vault:
```powershell
docker exec -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN=$env:VAULT_TOKEN `
  danipa-vault sh -lc "vault kv get secret/config/dev"
```

---

## ✅ Verification

### Health Check
```powershell
curl -u cfg-user:cfg-pass http://localhost:8088/actuator/health
```

### Exposed Mappings
```powershell
curl -u cfg-user:cfg-pass http://localhost:8088/actuator/mappings
```

### Example Config Fetch
```powershell
curl -u cfg-user:cfg-pass http://localhost:8088/danipa-fintech-service/dev
```

---

## 🔧 Maintenance

- **Logs**  
  ```powershell
  docker logs -f danipa-config-server
  ```

- **Rotate credentials**  
  Update Vault secrets or Git repo → restart config server

- **Refresh configs dynamically**  
  Use Spring Cloud Bus (Kafka) to broadcast refresh events  

- **Switching environments**  
  ```powershell
  docker compose --env-file .env.staging up -d
  docker compose --env-file .env.prod up -d
  ```

---

## 🚨 Troubleshooting

### Config server won’t start
- Ensure Vault or Git repo is reachable  
- Check `.env.dev` values are exported correctly  

### Health check fails
- Confirm credentials match (`CONFIG_USER` / `CONFIG_PASS`)  
- Run `docker inspect danipa-config-server | jq .[].State.Health`  

### Repo not found
- Verify `./config-repo` exists locally (for bind mount)  
- If using GitHub, check `CONFIG_REPO_URI` and token validity  

---

## 📚 References

- [Platform Stack Runbook](../Danipa_Platform_Stack_Runbook.md)  
- [Vault Setup & Runbook](../../infra/vault/README.md)  
- [Spring Cloud Config](https://docs.spring.io/spring-cloud-config/docs/current/reference/html/)  
