# ![Danipa Logo](../images/danipa_logo.png)

# Danipa Redis Setup & Runbook

This document explains how to configure, run, validate, and maintain **Redis** for the Danipa Fintech Platform.  
It complements the main Platform Runbook and other service-specific guides.

---

## 📦 Service Overview

Redis is used as the **in-memory data store** and **cache** for the Danipa Fintech Platform.  
It supports session storage, caching, and real-time message handling.

Redis runs in Docker and is exposed on a custom port to avoid conflicts.

---

## 📌 Prerequisites

- Docker and Docker Compose installed
- PowerShell (for Windows users) or Bash (Linux/Mac)
- `redis-cli` for manual validation (comes with Redis image)

---

## ⚙️ Configuration

### docker-compose.redis.yml

```yaml
services:
  redis:
    image: redis:7.2
    container_name: danipa-redis
    ports:
      - "16379:6379"
    volumes:
      - redis-data:/data
    command: ["redis-server", "--appendonly", "yes"]
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5

volumes:
  redis-data:
```

> **Note**  
> Default Redis port is **6379**, but here it is mapped to **16379** on the host to avoid conflicts.

---

## 🚀 Setup & Initialization

### 1. Start Redis
```powershell
docker compose -f docker-compose.redis.yml up -d
docker logs -f danipa-redis
```

### 2. Verify Health
```powershell
docker exec -it danipa-redis redis-cli ping
```
Expect response:
```
PONG
```

---

## ✅ Verification

### Check Info
```powershell
docker exec -it danipa-redis redis-cli info server
```

### Store and Retrieve a Key
```powershell
docker exec -it danipa-redis redis-cli set testkey "hello-danipa"
docker exec -it danipa-redis redis-cli get testkey
```
Expect output:
```
"hello-danipa"
```

---

## 🔧 Maintenance

- **View logs**
  ```powershell
  docker logs -f danipa-redis
  ```

- **Backup data**
  - Data is stored in the `redis-data` Docker volume.
  - Snapshot backups can be made by exporting the volume.

- **Flush database (dangerous)**
  ```powershell
  docker exec -it danipa-redis redis-cli FLUSHALL
  ```

- **Restart cleanly**
  ```powershell
  docker compose -f docker-compose.redis.yml down
  docker volume rm redis-data   # WARNING: deletes all data!
  docker compose -f docker-compose.redis.yml up -d
  ```

---

## 🚨 Troubleshooting

### Port already in use
- Ensure nothing else is bound to port `16379` on the host.
- Change the mapping in `docker-compose.redis.yml` if needed.

### Cannot connect from host
- Ensure you are connecting to `127.0.0.1:16379`
- Check container health with `docker ps`

---

## 📚 References

- [Redis Official Docs](https://redis.io/docs/)
- [Docker Hub: Redis](https://hub.docker.com/_/redis)
- [Spring Data Redis](https://docs.spring.io/spring-data/redis/docs/current/reference/html/)
