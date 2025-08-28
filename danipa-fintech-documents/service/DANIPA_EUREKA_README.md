# ![Danipa Logo](../images/danipa_logo.png)

# Danipa Eureka Server Setup & Runbook

This document explains how to configure, run, and maintain the **Eureka Service Registry** for the Danipa Fintech Platform.  
It complements the main [Platform Runbook](../Danipa_Platform_Stack_Runbook.md) and Vault documentation.

---

## 📦 Service Overview

Eureka acts as the **service registry** for the platform.  
It allows microservices to register themselves and discover others without needing hardcoded endpoints.

- Runs on **Spring Boot 3 / Spring Cloud Netflix Eureka**
- Exposed on port `8761`
- Secured with **basic authentication**
- Integrated with **Vault** for secret management

---

## 📌 Prerequisites

- Docker & Docker Compose installed  
- `.env.dev` available in the project root (`danipa-fintech-platform/.env.dev`)  
- Vault running and seeded with:
  - `ACTUATOR_USER`, `ACTUATOR_PASS`
  - `CONFIG_USER`, `CONFIG_PASS`

---

## ⚙️ Configuration

### `application.yml`

```yaml
server:
  port: 8761

spring:
  application:
    name: danipa-eureka-server
  security:
    user:
      name: ${ACTUATOR_USER}
      password: ${ACTUATOR_PASS}

eureka:
  client:
    registerWithEureka: false
    fetchRegistry: false
  server:
    enableSelfPreservation: true
```

---

## 🚀 Setup & Run

### 1. Start Eureka in Docker
```powershell
docker compose -f docker-compose.eureka.yml up -d
```

### 2. Verify Logs
```powershell
docker logs -f danipa-eureka
```

Expected output should show:
```
Started EurekaServerApplication in ...
```

### 3. Access UI
- URL: [http://localhost:8761](http://localhost:8761)  
- Credentials: from Vault secrets (`ACTUATOR_USER` / `ACTUATOR_PASS`)

---

## ✅ Verification

- Services should appear in the Eureka Dashboard when they register  
- Health endpoint:
  ```powershell
  curl -u act:act-pass http://localhost:8761/actuator/health
  ```

---

## 🔧 Maintenance

- **Rotate actuator credentials**
  - Update Vault `secret/actuator/<env>`
  - Restart Eureka service

- **Scale**
  - Update `docker-compose.eureka.yml` with replicas
  - Ensure load balancer points to all replicas

- **Logs**
  ```powershell
  docker logs -f danipa-eureka
  ```

- **Restart cleanly**
  ```powershell
  docker compose -f docker-compose.eureka.yml down
  docker compose -f docker-compose.eureka.yml up -d
  ```

---

## 🚨 Troubleshooting

### Issue: UI not loading
- Check if port `8761` is free  
- Run `docker ps` and confirm container is healthy  

### Issue: Services not registering
- Ensure clients have correct `eureka.client.serviceUrl.defaultZone` pointing to Eureka server  
- Confirm Eureka container logs  

### Issue: Authentication errors
- Verify Vault-seeded secrets  
- Check that environment variables are mounted correctly  

---

## 📚 References

- [Spring Cloud Netflix Eureka](https://spring.io/projects/spring-cloud-netflix)  
- [Spring Boot Actuator](https://docs.spring.io/spring-boot/docs/current/reference/html/actuator.html)  
- [Danipa Vault Setup](../Danipa_Vault_Runbook.md)  
