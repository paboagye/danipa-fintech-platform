# ![Danipa Logo](../images/danipa_logo.png)

# Danipa Fintech Service Setup & Runbook

This document explains how to configure, run, seed, and maintain the **Danipa Fintech Service**.  
It complements the [Platform Stack Runbook](../Danipa_PlatformStackRunbook.md) and Vault guide.

---

## 📦 Service Overview

`danipa-fintech-service` is the **core Spring Boot 3 microservice** of the Danipa Fintech Platform.  
It provides:

- MTN MoMo integration (Remittance, Collection, Disbursements APIs)  
- Secure payment orchestration (future PayPal, Stripe support)  
- Central domain logic for fintech workflows  
- REST API endpoints with Swagger/OpenAPI docs  

It runs under Docker Compose for local/dev, connected to Vault (secrets) and Postgres (persistence).

---

## 📌 Prerequisites

- **Docker** and **Docker Compose**  
- **Java 24** (for local build/run outside Docker)  
- **Maven**  
- **Postgres 17** (or use the platform `danipa-postgres-dev` container)  
- **Vault** initialized and seeded with environment secrets  
- `.env.dev` file in repo root with values (see example below)  

---

## ⚙️ Configuration

### Environment Variables

Example `.env.dev` (root of repo):

```env
# App
SPRING_PROFILES_ACTIVE=dev

# Vault
VAULT_HOST=localhost
VAULT_PORT=18300
VAULT_ROLE_ID=<injected-role-id>
VAULT_SECRET_ID=<injected-secret-id>

# Postgres
POSTGRES_HOST=localhost
POSTGRES_PORT=5433
POSTGRES_DB=danipa_dev
POSTGRES_USER=danipa_app_dev
POSTGRES_PASSWORD=changeMeDevApp!

# Kafka
SPRING_CLOUD_STREAM_KAFKA_BINDER_BROKERS=localhost:9092
```

### application.yml (excerpt)

```yaml
server:
  port: 8080

spring:
  application:
    name: danipa-fintech-service
  datasource:
    url: jdbc:postgresql://${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}
    username: ${POSTGRES_USER}
    password: ${POSTGRES_PASSWORD}
  jpa:
    hibernate:
      ddl-auto: validate
    properties:
      hibernate:
        format_sql: true
  cloud:
    vault:
      enabled: true
      host: ${VAULT_HOST}
      port: ${VAULT_PORT}
      scheme: http
      authentication: APPROLE
      app-role:
        role-id: ${VAULT_ROLE_ID}
        secret-id: ${VAULT_SECRET_ID}
      kv:
        enabled: true
        backend: secret
        default-context: app
```

---

## 🚀 Running Locally

### 1. Build the Service
```powershell
mvn clean package -DskipTests
```

### 2. Run with Docker Compose
```powershell
docker compose -f docker-compose.dev.yml up -d danipa-fintech-service
```

### 3. Run Natively
```powershell
mvn spring-boot:run -Dspring-boot.run.profiles=dev
```

---

## 🌱 Database Setup

The platform provides `danipa-postgres-dev` on port `5433`.

Verify connectivity:
```powershell
psql -h localhost -p 5433 -U danipa_owner_dev -d danipa_dev
```

Schemas and roles are created via **schema tracker migrations**.  

---

## 🔐 Secrets via Vault

The service pulls secrets from Vault (`secret/<domain>/<env>`). Example paths:

- `secret/config/dev` → Config credentials  
- `secret/postgres/dev` → Database credentials  
- `secret/momo/dev` → MTN MoMo API credentials  

Verify:
```powershell
docker exec -e VAULT_ADDR=http://127.0.0.1:8300 -e VAULT_TOKEN=$env:VAULT_TOKEN `
  danipa-vault sh -lc "vault kv get secret/momo/dev"
```

---

## ✅ Verification

### Health Check
```powershell
curl http://localhost:8080/api/actuator/health/readiness
```

### Swagger UI
Visit [http://localhost:8080/swagger-ui.html](http://localhost:8080/swagger-ui.html)

---

## 🔧 Maintenance

- **Logs**  
  ```powershell
  docker logs -f danipa-fintech-service
  ```

- **Rotate DB or MoMo secrets**  
  Update Vault → re-seed JSON → restart service

- **DB migrations**  
  Apply schema tracker SQL or Liquibase changelogs

- **Scaling**  
  Adjust Docker Compose replicas or deploy to ACA/AKS in Azure

---

## 🚨 Troubleshooting

### Service fails to start: "No vault token"
- Ensure `VAULT_ROLE_ID` and `VAULT_SECRET_ID` are valid in `.env.dev`
- Confirm Vault is running and seeded

### Database errors
- Check Postgres container is healthy
- Validate credentials in Vault match `.env.dev`

### Port conflicts
- Ensure `8080` (service) and `5433` (Postgres) are free
- Update `.env.dev` and compose mapping if needed

---

## 📚 References

- [Platform Stack Runbook](../Danipa_PlatformStackRunbook.md)  
- [Vault Setup & Runbook](../../infra/vault/README.md)  
- [Spring Cloud Vault](https://docs.spring.io/spring-cloud-vault/docs/current/reference/html/)  
- [MTN MoMo API Docs](https://momodeveloper.mtn.com/)  
