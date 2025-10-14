# ![Danipa Logo](./images/danipa_logo.png)

# 📘 Danipa Fintech Platform – Database Bootstrap & Permission Model

## 1️⃣ Overview

The **Danipa Fintech Platform** uses a **Postgres + Vault + Flyway** stack to enforce *least privilege*, environment consistency, and automated schema management across all stages (`dev`, `staging`, `prod`).

Core elements:

- **Postgres 17** – the database engine (one container per environment).  
- **Vault (AppRole + Agent templates)** – dynamically provisions secrets into file sinks.  
- **Flyway (Spring Boot integration)** – executes migrations using a dedicated `migrator` role.  
- **Bootstrap scripts (`infra/postgres/init/<env>/`)** – create roles, schemas, and grants idempotently.  
- **Permission probe scripts** – verify that `owner`, `app`, `ro`, and `migrator` roles follow least privilege.

---

## 2️⃣ Database Containers

### 🔹 `danipa-postgres-dev`

Runs Postgres 17 for the `dev` environment. The container is fully bootstrapped by Vault-rendered credentials and init scripts.

```yaml
postgres-dev:
  image: postgres:17
  profiles: [ "dev" ]
  container_name: danipa-postgres-dev
  environment:
    POSTGRES_USER: ${POSTGRES_USER_DEV}
    POSTGRES_DB: ${POSTGRES_DB_DEV}
    POSTGRES_PASSWORD_FILE: /opt/pg-secrets/POSTGRES_PASSWORD
  volumes:
    - pgdata_dev:/var/lib/postgresql/data
    - ./infra/postgres/init/dev:/docker-entrypoint-initdb.d:ro
    - pg_secrets:/opt/pg-secrets:rw
  depends_on:
    - postgres-agent
```

### 🔹 `postgres-agent`

A **Vault Agent** sidecar that renders database credentials securely:

```hcl
template {
  source      = "/vault/templates/postgres_password.cmtpl"
  destination = "/opt/pg-secrets/POSTGRES_PASSWORD"
  perms       = "0640"
}
```

Vault issues temporary DB credentials, which the container reads through `/opt/pg-secrets/`.

---

## 3️⃣ Database Bootstrap Process

### 🧩 Script: `010-bootstrap-db.sh`

Executed automatically at container init or manually via:

```bash
infra/postgres/init/dev/010-bootstrap-db.sh
```

This script:
- Creates database if missing.
- Defines **group roles** (`danipa_app`, `danipa_readonly`).
- Creates **env-scoped roles** (`danipa_app_<env>`, `danipa_ro_<env>`, `danipa_migrator_<env>`).
- Applies **schema grants and default privileges** across:
  - Writeable schemas: `fintech`, `core`, `payments`, `momo`, `webhooks`, `ops`
  - Read-only schema: `audit`
- Ensures idempotency – safe to re-run multiple times.

After execution, schema permissions follow this model:

| Role                    | Purpose               | Privileges                                      |
|-------------------------|-----------------------|-------------------------------------------------|
| `danipa_owner_<env>`    | Cluster owner         | Full access                                     |
| `danipa_app_<env>`      | Application runtime   | DML only on app schemas                         |
| `danipa_ro_<env>`       | Read-only role        | `SELECT` on all tables/sequences                |
| `danipa_migrator_<env>` | Flyway migrations     | `CREATE` and DDL on app schemas only            |
| `danipa_readonly`       | Group for read roles  | Aggregates RO access                            |

---

## 4️⃣ Flyway Integration

Spring Boot loads Vault-provided credentials and runs Flyway migrations using the **migrator** role.

```yaml
spring:
  flyway:
    url: jdbc:postgresql://postgres:5432/danipa_fintech_db_${ENV:dev}
    user: danipa_migrator_${ENV:dev}
    password: ${SPRING_FLYWAY_PLACEHOLDERS_DANIPA_MIGRATOR_${ENV:DEV}_PASSWORD}
    schemas: fintech,core,payments,momo,webhooks,ops,audit
    create-schemas: false
    baseline-on-migrate: true
```

Flyway scripts live under:

```
infra/postgres/init/dev/db-migration-common/
  ├── V1__roles_and_users.sql
  ├── V2__core_extensions.sql
  ├── V3__logical_schemas.sql
  └── ...
```

Flyway **never creates schemas or grants privileges**; that’s centralized in `010-bootstrap-db.sh`.

---

## 5️⃣ Permission Verification

### 🧪 Run the built-in permission probe

You can validate that every schema and role behaves as expected using:

```bash
make probe-db-perms
```

**Expected output (dev example):**
```
✅ Migrator cannot CREATE SCHEMA (expected)
✅ [fintech] App can DML (INSERT/SELECT/UPDATE/DELETE)
✅ [fintech] RO can SELECT
✅ [audit] App cannot INSERT (expected for read-only schema)
✅ [audit] cleanup done
[probe] all checks passed 🎉
```

Run against staging:

```bash
make probe-db-perms   POSTGRES_CONTAINER=danipa-postgres-staging   DB_NAME=danipa_fintech_db_staging   OWNER_ROLE=danipa_owner_staging   APP_ROLE=danipa_app_staging   RO_ROLE=danipa_ro_staging   MIGRATOR_ROLE=danipa_migrator_staging   APP_SCHEMAS="fintech core payments momo webhooks ops"   RO_ONLY_SCHEMAS="audit"
```

---

## 6️⃣ Sanity Checks

List all schemas and owners:

```bash
docker exec -it danipa-postgres-dev   psql -U danipa_owner_dev -d danipa_fintech_db_dev   -c "SELECT n.nspname AS schema, r.rolname AS owner
      FROM pg_namespace n JOIN pg_roles r ON r.oid = n.nspowner
      WHERE n.nspname IN ('fintech','core','payments','momo','webhooks','ops','audit')
      ORDER BY 1;"
```

Check Flyway status:

```bash
docker exec -it danipa-postgres-dev   psql -U danipa_owner_dev -d danipa_fintech_db_dev   -c "TABLE fintech.flyway_schema_history;"
```

---

## 7️⃣ Start/Stop Helpers

**Startup order:**  
1. Vault  
2. Vault Agent (`postgres-agent`)  
3. Postgres (`danipa-postgres-<env>`)  
4. Application services (after DB ready)

Use helpers:
```bash
./infra/scripts/start-db-stack.sh
./infra/scripts/stop-db-stack.sh
```

---

## 8️⃣ Security & Best Practices

- `010-bootstrap-db.sh` is **the single source of truth** for roles and privileges.  
- No Flyway script should `CREATE ROLE`, `CREATE SCHEMA`, or modify grants.  
- Vault manages credentials — no plaintext passwords in `.env` or Compose.  
- Each environment (`dev`, `staging`, `prod`) uses distinct roles and Vault paths.  
- Run `make probe-db-perms` after each environment bootstrap to verify least privilege.  
- Rotate DB credentials periodically through Vault.
