# ![Danipa Logo](images/danipa_logo.png)

# Danipa Services – Start/Stop Cheatsheet (with `SPRING_PROFILES_ACTIVE`)

Quick commands to **start**, **stop**, and **check** each Danipa service using the correct Spring profile.
Assumes you have a valid `.env.dev` at the project root (`danipa-fintech-platform/.env.dev`).  
For staging/prod, swap to `.env.staging`, `.env.prod`, etc.

---

## 0) Prereqs (once per session)
```powershell
# From project root of danipa-fintech-platform
$env:COMPOSE_PROJECT_NAME = "danipa"
docker compose --version
```

> Tip: Our Compose files pass `SPRING_PROFILES_ACTIVE` from your chosen `.env.<env>` automatically.

---

## 1) Config Server (danipa-config-server)

### Start (Docker)
```powershell
docker compose --env-file .env.dev up -d danipa-config-server
```

### Start (Local Java)
```powershell
cd danipa-config-server
mvn clean package -DskipTests
java -jar -Dspring.profiles.active=dev target/danipa-config-server-*.jar
```

### Stop
```powershell
docker compose stop danipa-config-server
# or if running locally: Ctrl+C
```

### Health
```powershell
curl -u cfg-user:cfg-pass http://localhost:8088/actuator/health
```

---

## 2) Eureka Server (danipa-eureka-server)

### Start (Docker)
```powershell
docker compose --env-file .env.dev up -d danipa-eureka-server
```

### Start (Local Java)
```powershell
cd danipa-eureka-server
mvn clean package -DskipTests
java -jar -Dspring.profiles.active=dev target/danipa-eureka-server-*.jar
```

### Stop
```powershell
docker compose stop danipa-eureka-server
# or if running locally: Ctrl+C
```

### Health
```powershell
curl http://localhost:8761/actuator/health
# UI: http://localhost:8761
```

---

## 3) Fintech Service (danipa-fintech-service)

### Start (Docker)
```powershell
docker compose --env-file .env.dev up -d danipa-fintech-service
```

### Start (Local Java)
```powershell
cd danipa-fintech-service
mvn clean package -DskipTests
java -jar -Dspring.profiles.active=dev target/danipa-fintech-service-*.jar
```

### Stop
```powershell
docker compose stop danipa-fintech-service
# or locally: Ctrl+C
```

### Health
```powershell
curl http://localhost:8080/actuator/health
```

---

## 4) Stripe Service (danipa-stripe-service)

### Start (Docker)
```powershell
docker compose --env-file .env.dev up -d danipa-stripe-service
```

### Start (Local Java)
```powershell
cd danipa-stripe-service
mvn clean package -DskipTests
java -jar -Dspring.profiles.active=dev target/danipa-stripe-service-*.jar
```

### Stop
```powershell
docker compose stop danipa-stripe-service
```

### Health
```powershell
curl http://localhost:8081/actuator/health
```

---

## 5) PayPal Service (danipa-paypal-service)

### Start (Docker)
```powershell
docker compose --env-file .env.dev up -d danipa-paypal-service
```

### Start (Local Java)
```powershell
cd danipa-paypal-service
mvn clean package -DskipTests
java -jar -Dspring.profiles.active=dev target/danipa-paypal-service-*.jar
```

### Stop
```powershell
docker compose stop danipa-paypal-service
```

### Health
```powershell
curl http://localhost:8085/actuator/health
```

---

## 6) Shared Infra Quick Commands

> These are not Spring apps (no `SPRING_PROFILES_ACTIVE`) but often needed for local runs.

### Vault
```powershell
docker compose -f infra/vault/docker-compose.vault.yml up -d
# UI: http://localhost:18300/ui
```

### Redis
```powershell
docker compose --env-file .env.dev up -d redis
```

### Kafka + Zookeeper
```powershell
docker compose --env-file .env.dev up -d zookeeper kafka
```

### Postgres + pgAdmin
```powershell
docker compose --env-file .env.dev up -d postgres pgadmin
# pgAdmin UI: http://localhost:9012
```

### Elastic Stack (Elasticsearch, Kibana, Logstash)
```powershell
docker compose --env-file .env.dev up -d elasticsearch kibana logstash
# Kibana UI: http://localhost:5601
```

---

## 7) Verify Service Profile at Runtime

```powershell
# Replace port with the service’s actuator port
curl http://localhost:<port>/actuator/env | findstr /I spring.profiles.active
# or JSON:
curl http://localhost:<port>/actuator/env | jq '.propertySources[]?.properties."spring.profiles.active" // empty'
```

---

## 8) Common Management

### View logs
```powershell
docker compose logs -f <service-name>
```

### Restart service
```powershell
docker compose restart <service-name>
```

### Stop all
```powershell
docker compose stop
```

### Tear down (careful: stops and removes containers)
```powershell
docker compose down
```

### Rebuild image & start
```powershell
docker compose --env-file .env.dev up --build -d <service-name>
```

---

## 9) Typical Bring-up Order (dev)
```powershell
# Infra
docker compose --env-file .env.dev up -d zookeeper kafka redis postgres

# Config & Discovery
docker compose --env-file .env.dev up -d danipa-config-server danipa-eureka-server

# App Services
docker compose --env-file .env.dev up -d danipa-fintech-service danipa-stripe-service danipa-paypal-service
```

---

## 10) Notes
- Ensure `.env.dev` sets required credentials (Vault AppRole, CONFIG_USER/PASS, DB, Kafka brokers, etc.).
- For staging/prod, use the matching env file and change `-Dspring.profiles.active=<env>` when running locally.
- When using Vault, config server must be up before other services so clients can fetch configuration.

