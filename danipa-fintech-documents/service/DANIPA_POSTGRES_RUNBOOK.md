# ![Danipa Logo](../images/danipa_logo.png)

# Danipa Postgres Setup & Runbook

This document explains how to configure, run, seed, and maintain **Postgres** for the Danipa Fintech Platform.  
It complements the main Platform Runbook and service-specific guides.

---

## 📦 Service Overview

Postgres is used as the primary database for:
- Danipa Fintech Service
- Other supporting microservices (e.g., Config Server, MoMo integration)

It runs in Docker with a named volume for persistence and pgAdmin for administration.

---

## 📌 Prerequisites

- Docker and Docker Compose installed
- PowerShell or Bash (depending on OS)
- `.env.dev` in project root containing Postgres settings
- Ports 5433 (Postgres) and 8081 (pgAdmin) available

---

## ⚙️ Configuration

### docker-compose.postgres.yml

```yaml
services:
  postgres:
    image: postgres:17
    container_name: danipa-postgres-dev
    ports:
      - "5433:5432"
    environment:
      POSTGRES_USER: ${POSTGRES_USER_DEV}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD_DEV}
      POSTGRES_DB: ${POSTGRES_DB_DEV}
    volumes:
      - postgres-data:/var/lib/postgresql/data

  pgadmin:
    image: dpage/pgadmin4:8
    container_name: danipa-pgadmin
    environment:
      PGADMIN_DEFAULT_EMAIL: admin@danipa.com
      PGADMIN_DEFAULT_PASSWORD: admin
    ports:
      - "8081:80"
    depends_on:
      - postgres

volumes:
  postgres-data:
```

---

## 🚀 Setup & Initialization

### 1. Start Postgres + pgAdmin

```powershell
docker compose -f docker-compose.postgres.yml up -d
docker ps --filter "name=danipa-postgres-dev"
```

### 2. Connect via psql

```powershell
docker exec -it danipa-postgres-dev psql -U ${POSTGRES_USER_DEV} -d ${POSTGRES_DB_DEV}
```

### 3. Connect via pgAdmin

Visit: [http://localhost:8081](http://localhost:8081)  
Login with:
- Email: `admin@danipa.com`
- Password: `admin`

Then register a new server pointing to `danipa-postgres-dev` on port `5432`.

---

## 🌱 Seeding Data

Schemas, roles, and seed data are managed in `infra/postgres/seeds/`.  
Example:

```sql
CREATE TABLE tenants (
  id UUID PRIMARY KEY,
  name VARCHAR(255) NOT NULL,
  created_at TIMESTAMP DEFAULT NOW()
);
```

To run seeds:

```powershell
docker exec -i danipa-postgres-dev psql -U ${POSTGRES_USER_DEV} -d ${POSTGRES_DB_DEV} < ./infra/postgres/seeds/init.sql
```

---

## ✅ Verification

### Check running containers

```powershell
docker ps --filter "name=danipa-postgres-dev"
```

### Connect and list tables

```sql
\dt
```

---

## 🔧 Maintenance

- **Restart database**  
  ```powershell
  docker restart danipa-postgres-dev
  ```

- **Reset database** (wipe all data)  
  ```powershell
  docker compose -f docker-compose.postgres.yml down -v
  docker compose -f docker-compose.postgres.yml up -d
  ```

- **Backups**  
  ```powershell
  docker exec -t danipa-postgres-dev pg_dump -U ${POSTGRES_USER_DEV} ${POSTGRES_DB_DEV} > backup.sql
  ```

- **Restore from backup**  
  ```powershell
  docker exec -i danipa-postgres-dev psql -U ${POSTGRES_USER_DEV} -d ${POSTGRES_DB_DEV} < backup.sql
  ```

---

## 🚨 Troubleshooting

### Port already in use

If `5433` is already used, change mapping in `docker-compose.postgres.yml`.

### pgAdmin cannot connect

Check that `danipa-postgres-dev` is running and reachable from pgAdmin container.

### Authentication failed

Ensure credentials in `.env.dev` match those used in pgAdmin connection.

---

## 📚 References

- [Postgres Docs](https://www.postgresql.org/docs/)
- [pgAdmin Docs](https://www.pgadmin.org/docs/)
- [Docker Hub - Postgres](https://hub.docker.com/_/postgres)
- [Docker Hub - pgAdmin](https://hub.docker.com/r/dpage/pgadmin4)
