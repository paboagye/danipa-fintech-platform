# Danipa • Vault Seeding & Policy Automation

This repository ships a single script that seeds KV v2 secrets and provisions **read-only policies + AppRoles** across environments.

**Script:** `infra/vault/scripts/write-secrets.sh`

> **Purpose (Danipa standard):** keep environment bootstrap consistent, auditable, and secure. The script is idempotent and safe to run multiple times.

---

## Prerequisites

- Vault is reachable (default: `http://127.0.0.1:18300`).
- You have an **admin/root token** exported as `TOKEN`.
- Seed files exist at `infra/vault/seeds/<env>.json`.

> **Security note:** Never commit real secrets. Keep production values in your local environment or a secure secret store.

---

## Environment Flags (inputs)

| Variable        | Default                   | Description |
|-----------------|---------------------------|-------------|
| `TOKEN`         | _(required)_              | Admin/root token used to seed and manage policies. |
| `VAULT_ADDR`    | `http://127.0.0.1:18300`  | Vault URL. |
| `MOUNT`         | `secret`                  | KV v2 mount path. |
| `ENVS`          | `dev,staging,prod`        | Comma-separated env list to process. |
| `DRY_RUN`       | `false`                   | Print actions without writing to Vault. |
| `SHOW_VALUES`   | `false`                   | Print raw secret values (debug only). |
| `VERIFY_ONLY`   | `false`                   | **Verify policies/AppRole caps only — no writes.** |

---

## What the script does

1. Ensures the KV v2 mount exists (`$MOUNT`), upgrades to v2 if needed.
2. Seeds secrets from `infra/vault/seeds/<env>.json` into `secret/data/<path>`.
3. Writes a **slash-mirror** for any `danipa-config-server,<profile>` to `danipa-config-server/<profile>`.
4. Upserts an ACL policy per env: `read-config-server-secrets-<env>` including the crucial **slash wildcard**:
   ```hcl
   path "secret/data/danipa-config-server/*" { capabilities = ["read"] }
   ```
5. Creates an AppRole `config-server-<env>` and writes creds to:
   ```
   infra/vault/approle/config-server-<env>/{role_id,secret_id}
   ```
6. **Verification step:** confirms the policy includes the wildcard and that the AppRole can:
   - `read` comma path: `secret/data/danipa-config-server,composite`
   - `read` slash path: `secret/data/danipa-config-server/composite`
   - `list` metadata: `secret/metadata/danipa-config-server`

---

## Common commands (script-only)

### Full seed for all envs
```bash
TOKEN="<root>" infra/vault/scripts/write-secrets.sh
```

### Seed a single env
```bash
TOKEN="<root>" ENVS=staging infra/vault/scripts/write-secrets.sh
```

### Verify-only (no writes)
```bash
TOKEN="<root>" VERIFY_ONLY=true ENVS=dev,staging,prod infra/vault/scripts/write-secrets.sh
# Output shows: wildcard: present | caps: OK
```

### Dry run
```bash
TOKEN="<root>" DRY_RUN=true infra/vault/scripts/write-secrets.sh
```

---

## Using the Makefile wrapper

You can also use the Makefile wrapper to keep commands short and consistent.

Examples:
```bash
# Verify policies / approle caps (all envs)
make vault-verify TOKEN="<root>"

# Seed all envs
make vault-seed TOKEN="<root>"

# Seed just staging
make vault-seed-staging TOKEN="<root>"
```

A full usage guide for the Makefile is available in **Danipa Makefile Usage** (download link below).

---

## Sanity checks (manual)

Read via **comma**:
```bash
VAULT="http://127.0.0.1:18300"
APP_TOKEN="<client_token from approle/login>"

curl -sS -H "X-Vault-Token: $APP_TOKEN" \
  "$VAULT/v1/secret/data/danipa-config-server,composite" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["data"]["data"]["CONFIG_REPO_URI"])'
```

Read via **slash**:
```bash
curl -sS -H "X-Vault-Token: $APP_TOKEN" \
  "$VAULT/v1/secret/data/danipa-config-server/composite" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["data"]["data"]["CONFIG_REPO_URI"])'
```

Capabilities self-check:
```bash
curl -sS -H "X-Vault-Token: $APP_TOKEN" -H 'Content-Type: application/json' -X POST \
  -d '{"paths":["secret/data/danipa-config-server,composite","secret/data/danipa-config-server/composite","secret/metadata/danipa-config-server"]}' \
  "$VAULT/v1/sys/capabilities-self" | python3 -m json.tool
```

---

## Troubleshooting

- **403 on slash path**: add the wildcard rule to the policy:
  ```hcl
  path "secret/data/danipa-config-server/*" { capabilities = ["read"] }
  ```
- **JSON parse error during verify**: rerun with `VERIFY_ONLY=true` to narrow scope; ensure Vault returns a 200 and a JSON body.
- **Missing AppRole creds**: confirm files exist under `infra/vault/approle/config-server-<env>/`.

---

*© Danipa — internal tooling. Do not distribute secrets or tokens in training materials.*
