# ![Danipa Logo](../images/danipa_logo.png)

# Danipa Vault Setup & Runbook

This document explains how to configure, run, seed, and validate **HashiCorp Vault** for the Danipa Fintech Platform.  
It complements the main [Platform Runbook](../Danipa_Platform_Stack_Runbook.pdf) and environment docs.

---

## 📦 Service Overview

Vault is used as the central secrets manager for:
- Config Server credentials (CONFIG_USER, CONFIG_PASS, etc.)
- Actuator credentials
- Postgres credentials per environment
- MTN MoMo API credentials

It runs in Docker, persists data via a named volume, and is exposed on a **non-default port** to avoid conflicts.

---

## 📌 Prerequisites

-   **Docker** and **Docker Compose** installed
-   **PowerShell** (for Windows users)
-   `curl` or `Invoke-RestMethod` available
-   `.env.dev` file in the project root
    (`danipa-fintech-platform/.env.dev`)
-   Seed files available in `infra/vault/seeds/`

---

## ⚙️ Configuration

### `docker-compose.vault.yml`

```yaml
services:
  vault:
    image: hashicorp/vault:1.16
    container_name: danipa-vault
    environment:
      VAULT_API_ADDR: "http://127.0.0.1:18300"
      VAULT_LOCAL_CONFIG: |
        {
          "ui": true,
          "disable_mlock": true,
          "listener": [{
            "tcp": {
              "address": "0.0.0.0:8300",
              "tls_disable": true
            }
          }],
          "storage": { "file": { "path": "/vault/data" } }
        }
    ports:
      - "18300:8300"
    cap_add:
      - IPC_LOCK
    volumes:
      - vault-data:/vault/data
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://127.0.0.1:8300/v1/sys/health"]
      interval: 10s
      timeout: 5s
      retries: 10

volumes:
  vault-data:
```

> **Note:**  
> Default Vault ports (`8200/8201`) conflicted on Windows. We remapped:  
> - **API:** `18300` (host) → `8300` (container)  
> - **Cluster:** `18301` (host) → `8301` (container, optional)  

---

## 🚀 Setup & Initialization

### 1. Start Vault
```powershell
docker compose -f docker-compose.vault.yml up -d
docker logs -f danipa-vault
```

### 2. Initialize Vault
Run inside container:
```powershell
docker exec -e VAULT_ADDR=http://127.0.0.1:8300 -it danipa-vault vault operator init -key-shares=1 -key-threshold=1
```

Copy:
- **Unseal Key** (only needed once, keep secure)
- **Root Token** (set as `VAULT_TOKEN`)

### 3. Export Environment
```powershell
$env:VAULT_ADDR  = "http://127.0.0.1:18300"
$env:VAULT_TOKEN = "<root-token-from-init>"
```

---

## 🌱 Seeding Secrets

### Seed File (`seeds/dev.json`)

```json
{
  "secrets": {
    "config": {
      "CONFIG_USER": "cfg-user",
      "CONFIG_PASS": "cfg-pass",
      "SPRING_PROFILES_ACTIVE": "dev"
    },
    "actuator": {
      "ACTUATOR_USER": "act",
      "ACTUATOR_PASS": "act-pass"
    },
    "postgres": {
      "POSTGRES_USER_DEV": "danipa_owner_dev",
      "POSTGRES_PASSWORD_DEV": "changeMeDev!",
      "POSTGRES_DB_DEV": "danipa_dev",
      "POSTGRES_APP_USER_DEV": "danipa_app_dev",
      "POSTGRES_APP_PASS_DEV": "changeMeDevApp!",
      "PG_PORT_DEV": "5433"
    },
    "momo": {
      "MOMO_API_USER_ID": "xxxx-uuid",
      "MOMO_API_KEY": "xxxx-key",
      "MOMO_REMITTANCE_SUBSCRIPTION_KEY": "xxxx-remit",
      "MOMO_COLLECTION_SUBSCRIPTION_KEY": "xxxx-collect",
      "MOMO_DISBURSEMENTS_SUBSCRIPTION_KEY": "xxxx-disburse",
      "MOMO_CALLBACK_URL": "https://api.danipa.com/ms/{provider}/{eventType}/{referenceId}"
    }
  }
}
```

### Seed Script (PowerShell One-Liner)

```powershell
$headers = @{ 'X-Vault-Token' = $env:VAULT_TOKEN }
$secrets = (Get-Content .\seeds\dev.json -Raw | ConvertFrom-Json).secrets
foreach ($entry in $secrets.PSObject.Properties) {
  $name  = $entry.Name
  $value = $entry.Value
  $body  = @{ data = $value } | ConvertTo-Json -Depth 10 -Compress
  Invoke-RestMethod -Method POST -Uri "$($env:VAULT_ADDR)/v1/secret/data/$name/dev" -Headers $headers -ContentType 'application/json' -Body $body | Out-Null
  Write-Host "✓ Wrote secret/$name/dev"
}
```

---

## ✅ Verification

### Healthcheck
```powershell
curl $env:VAULT_ADDR/v1/sys/health
```

Expect:
```json
{"initialized":true,"sealed":false,"standby":false,"version":"1.16.3"}
```

### Retrieve a Secret
```powershell
docker exec -e VAULT_ADDR=http://127.0.0.1:8300 -e VAULT_TOKEN=$env:VAULT_TOKEN `
  danipa-vault sh -lc "vault kv get secret/config/dev"
```

---

## 🔧 Key Rotation & Maintenance

- **Restart cleanly:**
  ```powershell
  docker compose -f docker-compose.vault.yml down
  docker volume rm vault_vault-data   # WARNING: deletes all secrets!
  ```

- **Rotate Vault Root Token**

    ``` powershell
    vault token create
    ```
- **Rotate Application Secrets**

    -   Update `seeds/<env>.json` (e.g `dev.json`) and re-run the seed script.
    -   Re-run seeding script
    -   Restart dependent services

- **Backup**

    -   Backup `vault/data` volume regularly
    -   Store **unseal keys** and **root token** securely

- **Audit logs:**  
  `docker logs -f danipa-vault`
- **UI Access:**  
  Visit `http://localhost:18300/ui` in a browser.

---

## 📌 Notes
- Config Server is wired to Vault using `APPROLE` (preferred for non-root use).  
- Root token is only for initial seeding/testing.  
- For staging/prod, provision separate `approle` roles with minimal access.  
- Secrets are namespaced by **`/<domain>/<env>`** convention:
  - `secret/config/dev`
  - `secret/actuator/dev` 
  - `secret/postgres/dev`
  - `secret/momo/dev`

---

## 🚨 Troubleshooting

### Port already in use

Error:

    Error initializing listener of type tcp: listen tcp4 0.0.0.0:8200: bind: address already in use

Solution: - Ensure no local Vault is running on `8200`. - Change mapped
host port in `docker-compose.vault.yml`.

---

### "no data provided" when seeding

Cause: incorrect JSON body.

Solution: - Ensure
`$body = @{ data = $value } | ConvertTo-Json -Depth 10 -Compress`

------------------------------------------------------------------------

### Permission denied (`/vault/data/core`)

Cause: volume ownership issue.

Solution:

``` powershell
docker compose -f docker-compose.vault.yml down -v
docker compose -f docker-compose.vault.yml up -d
```

---
## 📚 References

-   [HashiCorp Vault Docs](https://developer.hashicorp.com/vault/docs)
-   [Spring Cloud
    Vault](https://docs.spring.io/spring-cloud-vault/docs/current/reference/html/)
-   [Spring Cloud Config
    Server](https://docs.spring.io/spring-cloud-config/docs/current/reference/html/)
