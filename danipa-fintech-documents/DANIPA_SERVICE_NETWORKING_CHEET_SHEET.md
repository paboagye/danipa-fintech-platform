# ![Danipa Logo](images/danipa_logo.png)

# Danipa Service Networking Cheatsheet

This quick reference explains **which hostname to use** for every Danipa service in different contexts: inside Docker Compose, on your local host (Windows/macOS/Linux), and from other containers or machines. It also clarifies **service name vs. container name** and gives ready-to-copy examples.

---

## TL;DR

- **Inside the same `docker compose` project:** use the **service name** (the key under `services:`), e.g., `vault`, `config-server`, `eureka`, `kafka`, `postgres`, `redis`, `elasticsearch`, `kibana`, `logstash`.
- **From your host OS (PowerShell/Terminal):** use `localhost:<host_port>` from your Compose **port mappings**.
- **Never rely on `container_name` for inter-container DNS.** DNS inside the Compose network resolves by **service name**.
- If you changed the default ports, **update environment variables** and client configs accordingly.

---

## Service Map (Service Name ↔ Container Name ↔ Host Ports)

> Columns:
> - **Service Name**: DNS name containers use inside the Compose network.
> - **Container Name**: The explicit container name (if set). Not used for DNS.
> - **Host Access**: The host-port mapping exposed by Compose (use from your host OS/browser).
> - **In-Container Access**: The in-network address other services should use.

| Component        | Service Name      | Container Name               | Host Access (localhost)         | In-Container Access (service:port) |
|------------------|-------------------|------------------------------|----------------------------------|-------------------------------------|
| Vault            | `vault`           | `danipa-vault`               | `http://localhost:18300`         | `http://vault:8200`                 |
| Config Server    | `config-server`   | `danipa-config-server`       | `http://localhost:8088`          | `http://config-server:8088`         |
| Eureka Server    | `eureka`          | `danipa-eureka-server`       | `http://localhost:8761`          | `http://eureka:8761`                |
| Fintech Service  | `fintech-service` | `danipa-fintech-service`     | `http://localhost:8080`          | `http://fintech-service:8080`       |
| PostgreSQL       | `postgres`        | `danipa-postgres-dev`        | `localhost:5433`                 | `postgres:5432`                     |
| pgAdmin          | `pgadmin`         | `danipa-pgadmin`             | `http://localhost:8081`          | `http://pgadmin:80`                 |
| Redis            | `redis`           | `redis`                      | `localhost:6379`                 | `redis:6379`                        |
| Kafka            | `kafka`           | `kafka`                      | `localhost:9092`                 | `kafka:9092`                        |
| Elasticsearch    | `elasticsearch`   | `elasticsearch`              | `http://localhost:9200`          | `http://elasticsearch:9200`         |
| Kibana           | `kibana`          | `kibana`                     | `http://localhost:5601`          | `http://kibana:5601`                |
| Logstash         | `logstash`        | `logstash`                   | (usually not exposed)            | `http://logstash:9600`              |

> Your actual `container_name` values may vary; **service names** should match your Compose files. If a service name differs, use that value accordingly.

---

## Which host do I use where?

### 1) From another container in the same Compose project
Use the **service name** and the **container port**:
```properties
VAULT_HOST=vault
VAULT_PORT=8200
EUREKA_CLIENT_SERVICEURL_DEFAULTZONE=http://eureka:8761/eureka
SPRING_CONFIG_IMPORT=optional:configserver:http://config-server:8088
SPRING_DATASOURCE_URL=jdbc:postgresql://postgres:5432/danipa_dev
SPRING_REDIS_HOST=redis
SPRING_KAFKA_BOOTSTRAP_SERVERS=kafka:9092
ELASTICSEARCH_URI=http://elasticsearch:9200
```

### 2) From your host OS (PowerShell/Git Bash/Terminal)
Use **localhost** with the **host port** from the Compose mapping:
```bash
# health checks
curl http://localhost:18300/v1/sys/health        # Vault
curl http://localhost:8088/actuator/health       # Config Server
curl http://localhost:8761/                      # Eureka UI
curl http://localhost:8080/actuator/health       # Fintech Service
psql -h localhost -p 5433 -U danipa_owner_dev -d danipa_dev
redis-cli -h localhost -p 6379 ping
curl http://localhost:9200
curl http://localhost:5601                       # Kibana UI
```

### 3) From a different machine
Use your host’s IP and the **host port** (e.g., `http://<your-ip>:8088`). Ensure ports are reachable (firewall/NAT).

---

## Environment Variables (recommended patterns)

### Config Server (using Vault + Git composite)
```properties
# In config-server container (env or application.yml)
spring.config.server.composite[0].type=vault
spring.config.server.composite[0].host=${ ' }}VAULT_HOST:vault{{ ' }
spring.config.server.composite[0].port=${ ' }}VAULT_PORT:8200{{ ' }
spring.config.server.composite[0].backend=secret
spring.config.server.composite[0].kvVersion=2
spring.config.server.composite[0].defaultKey=danipa/config
spring.config.server.composite[0].authentication=APPROLE
spring.config.server.composite[0].app-role.role-id=${ ' }}VAULT_ROLE_ID{{ ' }
spring.config.server.composite[0].app-role.secret-id=${ ' }}VAULT_SECRET_ID{{ ' }

spring.config.server.composite[1].type=git
spring.config.server.composite[1].uri=${ ' }}CONFIG_GIT_URI:file:///config-repo{{ ' }
spring.config.server.composite[1].searchPaths=${ ' }}CONFIG_REPO_PATHS:{{ ' }
spring.config.server.composite[1].cloneOnStart=true
```

> **Note:** `host` should be `vault` (the **service name**), *not* `danipa-vault`. Port is the **container** port (8200), not the host port.

### Fintech Service (as a client of Eureka/Config/Kafka/Redis/Postgres)
```properties
SPRING_PROFILES_ACTIVE=dev
SPRING_CONFIG_IMPORT=optional:configserver:http://config-server:8088
EUREKA_CLIENT_SERVICEURL_DEFAULTZONE=http://eureka:8761/eureka

SPRING_DATASOURCE_URL=jdbc:postgresql://postgres:5432/danipa_dev
SPRING_DATASOURCE_USERNAME=danipa_app_dev
SPRING_DATASOURCE_PASSWORD=changeMeDevApp!

SPRING_REDIS_HOST=redis
SPRING_REDIS_PORT=6379

SPRING_KAFKA_BOOTSTRAP_SERVERS=kafka:9092
```

---

## Common Pitfalls & Fixes

- **Using `container_name` instead of the service name** for inter-container DNS.  
  ✅ Use `vault`, `eureka`, `config-server`, etc.

- **Using host-mapped ports inside containers.**  
  Inside containers, always use the **container port** (e.g., `vault:8200`), *not* `localhost:18300`.

- **Port conflicts on the host.**  
  Change host-side ports in Compose mappings if 8080/8088/8761/etc. are in use.

- **Health checks still show “unhealthy.”**  
  Confirm the right **host:port** is used in healthcheck commands (container context vs. host context).

- **WSL vs. Windows**: if you run commands in WSL, make sure you target `localhost:<host_port>` for services exposed by Docker Desktop.

---

## Quick Diagnostics

```bash
# Inside a running service container (e.g., fintech-service)
docker exec -it danipa-fintech-service sh -lc "apk add --no-cache curl || true; curl -sf http://eureka:8761 > /dev/null && echo OK || echo FAIL"

# From host
docker ps --format 'table {'{'}.Names{'}'}	{'{'}.Ports{'}'}'
docker logs -f danipa-config-server
docker logs -f danipa-vault
```

---

## FAQ

**Q: My service can’t reach Vault using `danipa-vault:8200`.**  
A: Use `vault:8200`. `vault` is the **service name** (DNS).

**Q: Do I ever use `127.0.0.1` inside containers?**  
A: Only to reach *itself*. To reach other services, use their **service names**.

**Q: I changed a host port, do I need to change in-container ports?**  
A: No. In-container communication still uses container ports and service names.

---

_Last updated: 2025-08-24_
