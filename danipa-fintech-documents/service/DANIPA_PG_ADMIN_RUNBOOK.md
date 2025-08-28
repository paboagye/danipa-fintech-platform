# ![Danipa Logo](../images/danipa_logo.png)

# Danipa pgAdmin Setup & Runbook

This document explains how to configure, run, and maintain **pgAdmin 4** for the Danipa Fintech Platform.  
It complements the main [Platform Runbook](../Danipa_Platform_Stack_Runbook.md).

---

## 📦 Service Overview

pgAdmin provides a web-based GUI for managing PostgreSQL databases in the Danipa Platform.  
It runs in Docker, connects to the Postgres service, and is mapped to a local port for browser access.

---

## 📌 Prerequisites

- **Docker** and **Docker Compose** installed  
- Postgres service already running (see [Postgres Runbook](Danipa_Postgres_Runbook.md))  
- Environment variables set in `.env.dev` (or appropriate env file):  
  - `PGADMIN_DEFAULT_EMAIL`  
  - `PGADMIN_DEFAULT_PASSWORD`  
  - `PGADMIN_PORT`

---

## ⚙️ Configuration

### docker-compose.pgadmin.yml

```yaml
services:
  pgadmin:
    image: dpage/pgadmin4:8
    container_name: danipa-pgadmin
    environment:
      PGADMIN_DEFAULT_EMAIL: ${PGADMIN_DEFAULT_EMAIL}
      PGADMIN_DEFAULT_PASSWORD: ${PGADMIN_DEFAULT_PASSWORD}
    ports:
      - "${PGADMIN_PORT:-8081}:80"
    depends_on:
      - postgres
    volumes:
      - pgadmin-data:/var/lib/pgadmin

volumes:
  pgadmin-data:
```

---

## 🚀 Setup & Initialization

### 1. Start pgAdmin

```powershell
docker compose -f docker-compose.pgadmin.yml up -d
docker logs -f danipa-pgadmin
```

### 2. Access UI

- Open browser at: **http://localhost:8081** (or your configured port)  
- Login with:
  - **Email:** `${PGADMIN_DEFAULT_EMAIL}`  
  - **Password:** `${PGADMIN_DEFAULT_PASSWORD}`  

### 3. Register Postgres Server

- Click **Add New Server** in pgAdmin.  
- Connection settings:  
  - **Host:** `postgres` (container network name)  
  - **Port:** `5432` (or mapped port)  
  - **Database:** `danipa_dev` (or relevant DB)  
  - **Username/Password:** from Vault → `secret/postgres/dev`  

---

## ✅ Verification

- Confirm connection to Postgres DB inside pgAdmin.  
- Verify ability to browse schemas, tables, and run queries.  
- Ensure SSL or strong credentials are configured for staging/production.

---

## 🔧 Maintenance

- **Change pgAdmin password**:  
  - Update `.env.dev` with a new `PGADMIN_DEFAULT_PASSWORD`  
  - Restart container  

- **Backup pgAdmin settings**:  
  - Export pgAdmin server groups via UI for backup.  
  - Persist volumes with `pgadmin-data`.

- **Restart cleanly**:  
  ```powershell
  docker compose -f docker-compose.pgadmin.yml down
  docker volume rm pgadmin-data   # WARNING: deletes saved connections
  docker compose -f docker-compose.pgadmin.yml up -d
  ```

- **Upgrade pgAdmin**:  
  - Update the image tag in `docker-compose.pgadmin.yml` (e.g., `dpage/pgadmin4:latest`)  
  - Re-deploy  

---

## 🚨 Troubleshooting

### pgAdmin login fails
- Ensure `PGADMIN_DEFAULT_EMAIL` and `PGADMIN_DEFAULT_PASSWORD` are set correctly.  
- Recreate container after updating `.env.dev`.

### Cannot connect to Postgres
- Verify Postgres is running.  
- Ensure pgAdmin container can resolve the Postgres service (`postgres` in Docker network).  
- Check that credentials match Vault-seeded values.

---

## 📚 References
- [pgAdmin Docs](https://www.pgadmin.org/docs/)  
- [Postgres Runbook](Danipa_Postgres_Runbook.md)  
- [Vault Runbook](Danipa_Vault_Runbook.md)  
