# ![Danipa Logo](../images/danipa_logo.png)

# Danipa Kafka Setup & Runbook

This document explains how to configure, run, verify, and maintain **Apache Kafka** for the Danipa Fintech Platform.  
It complements the main Platform Runbook and service-specific docs.

---

## 📦 Service Overview

Kafka is used as the distributed event streaming platform for:
- Spring Cloud Bus events
- Asynchronous communication between services
- Event-driven workflows for MoMo, payments, and notifications

Kafka runs in Docker along with Zookeeper, and is exposed on mapped ports for local development.

---

## 📌 Prerequisites

- **Docker** and **Docker Compose** installed
- **PowerShell** (Windows users) or `bash` (Linux/Mac)
- `.env.dev` file in the project root (`danipa-fintech-platform/.env.dev`)
- Kafka client tools (`kafka-topics.sh`, `kafka-console-producer.sh`, `kafka-console-consumer.sh`) available inside the container

---

## ⚙️ Configuration

### `docker-compose.kafka.yml`

```yaml
version: '3.8'

services:
  zookeeper:
    image: confluentinc/cp-zookeeper:7.6.1
    container_name: danipa-zookeeper
    environment:
      ZOOKEEPER_CLIENT_PORT: 2181
      ZOOKEEPER_TICK_TIME: 2000
    ports:
      - "2181:2181"

  kafka:
    image: confluentinc/cp-kafka:7.6.1
    container_name: danipa-kafka
    depends_on:
      - zookeeper
    ports:
      - "9092:9092"
    environment:
      KAFKA_BROKER_ID: 1
      KAFKA_ZOOKEEPER_CONNECT: zookeeper:2181
      KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://localhost:9092
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 1
```

---

## 🚀 Setup & Startup

### 1. Start Services
```powershell
docker compose -f docker-compose.kafka.yml up -d
docker ps --filter "name=danipa-kafka"
```

### 2. Verify Logs
```powershell
docker logs -f danipa-kafka
```

---

## ✅ Verification

### List Topics
```powershell
docker exec -it danipa-kafka kafka-topics --list --bootstrap-server localhost:9092
```

### Create Topic
```powershell
docker exec -it danipa-kafka kafka-topics --create --topic test-topic --bootstrap-server localhost:9092 --partitions 1 --replication-factor 1
```

### Produce Messages
```powershell
docker exec -it danipa-kafka kafka-console-producer --topic test-topic --bootstrap-server localhost:9092
```

### Consume Messages
```powershell
docker exec -it danipa-kafka kafka-console-consumer --topic test-topic --from-beginning --bootstrap-server localhost:9092
```

---

## 🔧 Maintenance

- **Restart cleanly:**
  ```powershell
  docker compose -f docker-compose.kafka.yml down
  docker volume rm <volume_name>   # optional reset
  ```

- **Add New Topics:**  
  Update configs or use `kafka-topics --create`.

- **Monitor Kafka:**  
  - Logs: `docker logs -f danipa-kafka`
  - Health: ensure port `9092` is listening

- **Scaling:**  
  Increase brokers by adding more `kafka` services with unique IDs.

---

## 📌 Notes

- Kafka relies on Zookeeper (until migrated to KRaft).  
- Ports: `2181` for Zookeeper, `9092` for Kafka broker.  
- Secrets for apps connecting to Kafka (if needed) are stored in Vault.  
- Config Server is already wired to Kafka for Spring Cloud Bus.

---

## 🚨 Troubleshooting

### Broker not reachable
Cause: Wrong `advertised.listeners` or port conflict.  
Solution: Ensure `KAFKA_ADVERTISED_LISTENERS` is set to `PLAINTEXT://localhost:9092`.

### Topic not created
Cause: Wrong bootstrap server or Zookeeper not running.  
Solution: Check `docker ps` and confirm `danipa-zookeeper` is healthy.

### Messages not consumed
Cause: Consumer group already committed offsets.  
Solution: Use `--from-beginning` flag when consuming.

---

## 📚 References

- [Apache Kafka Documentation](https://kafka.apache.org/documentation/)
- [Confluent Kafka Docker Images](https://hub.docker.com/r/confluentinc/cp-kafka)
- [Spring Cloud Stream Kafka](https://docs.spring.io/spring-cloud-stream/docs/current/reference/html/spring-cloud-stream-binder-kafka.html)
