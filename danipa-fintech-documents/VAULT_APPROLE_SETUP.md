# ![Danipa Logo](images/danipa_logo.png)

# Danipa Vault AppRole Setup — Cheatsheet

This quick guide recreates the **policy** and **AppRole** for the Config Server (and other services) to read development secrets from Vault.

It’s written to be copy/paste friendly for **PowerShell**, **Git Bash**, and **inside the Vault container**.

---

## 0) Prereqs

- Vault running and unsealed
- Root/admin token available
- Environment set:

---

## 1) Known Ports & Addresses

- **Host API (Windows/macOS/Linux):** `http://127.0.0.1:18300`
- **Inside container:** `http://127.0.0.1:8300`
- **Container name:** `danipa-vault`
- **KV mount:** `secret` (KV v2)
- **Dev secret convention:** `secret/<domain>/dev` (data API path: `v1/secret/data/<domain>/dev`)

> Make sure Vault is **initialized**, **unsealed**, and you have a **root/admin token** in `VAULT_TOKEN` before proceeding.

---

## 2) Export environment (host shell)

### PowerShell
```powershell
$env:VAULT_ADDR  = "http://127.0.0.1:18300"
$env:VAULT_TOKEN = "<root-or-admin-token>"
```

### Git Bash
```bash
export VAULT_ADDR=http://127.0.0.1:18300
export VAULT_TOKEN=<root-or-admin-token>
```

### Inside the container
```bash
docker exec -it danipa-vault sh -lc 'export VAULT_ADDR=http://127.0.0.1:8300; export VAULT_TOKEN=<root-or-admin-token>; sh'
```

---

## 3) Enable AppRole (idempotent)

### CLI (host)
```bash
vault auth enable approle || true
```

### cURL (host)
```bash
curl -sS -X POST "$VAULT_ADDR/v1/sys/auth/approle" \
  -H "X-Vault-Token: $VAULT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"type":"approle"}' | jq . || true
```

> If you see “path is already in use at approle/”, you’re good.

---

## 4) Create policy (read-only dev secrets)

Policy name: **`danipa-config`**

### Option A – one-liner (CLI)
```bash
vault policy write danipa-config - <<'EOF'
# Read data for any domain under /dev (KV v2 data path)
path "secret/data/*/dev" {
  capabilities = ["read"]
}

# (optional) List to support directory-style listings under dev
path "secret/metadata/*/dev" {
  capabilities = ["list"]
}
EOF
```

### Option B – file + CLI
Create `danipa-config.hcl`:
```hcl
path "secret/data/*/dev" {
  capabilities = ["read"]
}

path "secret/metadata/*/dev" {
  capabilities = ["list"]
}
```

Then:
```bash
vault policy write danipa-config danipa-config.hcl
```

### Verify
```bash
vault policy read danipa-config
```

---

## 5) Create AppRole bound to the policy

Role name: **`danipa-config-role`**

> Token TTLs here are conservative for local/dev. Adjust for staging/prod.

### CLI
```bash
vault write auth/approle/role/danipa-config-role \
  token_policies="danipa-config" \
  token_ttl="24h" \
  token_max_ttl="72h" \
  secret_id_num_uses=10 \
  secret_id_ttl="24h"
```

### Verify role
```bash
vault read auth/approle/role/danipa-config-role
```

---

## 6) Fetch Role ID and Secret ID

These two values are what the **Config Server** uses when `authentication: APPROLE` is configured.

### Role ID
```bash
vault read -format=json auth/approle/role/danipa-config-role/role-id | jq -r .data.role_id
```

### Secret ID (generate a new one)
```bash
vault write -format=json -f auth/approle/role/danipa-config-role/secret-id | jq -r .data.secret_id
```

> Save these as `VAULT_ROLE_ID` and `VAULT_SECRET_ID` in your service environment (or secret store).

---

## 7) Test login with AppRole

### Login
```bash
vault write -format=json auth/approle/login \
  role_id="<ROLE_ID>" \
  secret_id="<SECRET_ID>" \
  | jq -r .auth.client_token
```

Export the returned client token and try a read:

```bash
export APPROLE_TOKEN="<token-from-login>"
curl -sS -H "X-Vault-Token: $APPROLE_TOKEN" \
  "$VAULT_ADDR/v1/secret/data/config/dev" | jq .
```

Expected JSON contains your `config` data (e.g., `CONFIG_USER`, `CONFIG_PASS`, etc.).

---

## 8) Integrate with Spring Cloud Config Server

In `application.yml` for **danipa-config-server**:
```yaml
spring:
  config:
    server:
      composite:
        - type: vault
          host: ${VAULT_HOST:127.0.0.1}
          port: ${VAULT_PORT:18300}
          scheme: http
          backend: secret
          defaultKey: danipa/config
          kvVersion: 2
          profileSeparator: ","
          authentication: APPROLE
          app-role:
            role-id: ${VAULT_ROLE_ID}
            secret-id: ${VAULT_SECRET_ID}
```

Environment variables (host/dev):
```bash
export VAULT_HOST=127.0.0.1
export VAULT_PORT=18300
export VAULT_ROLE_ID=<copied-from-step-5>
export VAULT_SECRET_ID=<copied-from-step-5>
```

---

## 9) Useful maintenance commands

- **Rotate SecretID (invalidate old SecretIDs):**
  ```bash
  vault write -f auth/approle/role/danipa-config-role/secret-id
  ```

- **List SecretIDs (requires accessor perms):**
  ```bash
  vault list auth/approle/role/danipa-config-role/secret-id
  ```

- **Revoke by SecretID accessor:**
  ```bash
  vault write auth/approle/role/danipa-config-role/secret-id-accessor/destroy accessor="<ACCESSOR>"
  ```

- **Tweak TTLs / usage limits:**
  ```bash
  vault write auth/approle/role/danipa-config-role \
    token_ttl="12h" token_max_ttl="48h" \
    secret_id_ttl="12h" secret_id_num_uses=5
  ```

- **Delete role (careful):**
  ```bash
  vault delete auth/approle/role/danipa-config-role
  ```

---

## 10) Troubleshooting

- **`path is already in use at approle/`**  
  AppRole already enabled; proceed.

- **`permission denied` on read**  
  Verify policy and that your token is derived from AppRole with `danipa-config` attached. Check you’re hitting the **data** path (`v1/secret/data/...`) for KV v2 reads.

- **`no data found`**  
  Ensure seeds exist at `secret/<domain>/dev` (KV v2), e.g., `secret/config/dev` populated via `v1/secret/data/config/dev` with `{ "data": { ... } }`.

- **Unhealthy container / port issues**  
  Confirm `VAULT_ADDR` matches the correct port (host: **18300**, container: **8300**). Check `docker logs -f danipa-vault`.

---

## 11) Quick verification script (PowerShell)

```powershell
$env:VAULT_ADDR  = "http://127.0.0.1:18300"
$env:VAULT_TOKEN = "<root-or-admin-token>"

# Ensure approle is enabled
try { vault auth enable approle | Out-Null } catch {}

# Policy (inline)
@"
path "secret/data/*/dev" {
  capabilities = ["read"]
}
path "secret/metadata/*/dev" {
  capabilities = ["list"]
}
"@ | Set-Content -Path danipa-config.hcl -NoNewline

vault policy write danipa-config danipa-config.hcl

# Role (idempotent-ish)
vault write auth/approle/role/danipa-config-role `
  token_policies="danipa-config" `
  token_ttl="24h" token_max_ttl="72h" `
  secret_id_num_uses=10 secret_id_ttl="24h"

# Fetch IDs
$ROLE_ID   = (vault read -format=json auth/approle/role/danipa-config-role/role-id | ConvertFrom-Json).data.role_id
$SECRET_ID = (vault write -format=json -f auth/approle/role/danipa-config-role/secret-id | ConvertFrom-Json).data.secret_id

"ROLE_ID=$ROLE_ID"
"SECRET_ID=$SECRET_ID"

# Login test
$LOGIN  = vault write -format=json auth/approle/login role_id="$ROLE_ID" secret_id="$SECRET_ID" | ConvertFrom-Json
$TOKEN  = $LOGIN.auth.client_token
"APPROLE_TOKEN=$TOKEN"

# Try read config/dev
Invoke-RestMethod -Headers @{ "X-Vault-Token" = $TOKEN } `
  -Uri "$($env:VAULT_ADDR)/v1/secret/data/config/dev" -Method GET | ConvertTo-Json -Depth 5
```

---

**That’s it.** With the policy and role created, the Config Server (and other clients) can authenticate via **AppRole** and read the `dev` secrets they need.
