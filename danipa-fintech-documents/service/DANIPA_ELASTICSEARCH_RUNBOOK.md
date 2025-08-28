# ![Danipa Logo](../images/danipa_logo.png)

# Danipa Elasticsearch Setup & Runbook

This document explains how to configure, run, validate, and maintain **Elasticsearch** for the Danipa Fintech Platform.

## Service Overview

Elasticsearch provides distributed search and analytics for logs, metrics, and business data.

It is deployed as a container, part of the logging/monitoring stack with **Kibana** and **Logstash**.

## Prerequisites

- Docker & Docker Compose installed
- .env.dev file with relevant ports and credentials
- Adequate memory (at least 2GB for Elasticsearch container)

## Configuration

### docker-compose.elasticsearch.yml

```yaml
services:
  elasticsearch:
    image: docker.elastic.co/elasticsearch/elasticsearch:8.14.1
    container_name: danipa-elasticsearch
    environment:
      - discovery.type=single-node
      - xpack.security.enabled=false
      - ES_JAVA_OPTS=-Xms1g -Xmx1g
    ports:
      - "9200:9200"
    volumes:
      - es-data:/usr/share/elasticsearch/data
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://localhost:9200/_cluster/health"]
      interval: 10s
      timeout: 5s
      retries: 10

volumes:
  es-data:
```

## Setup & Initialization

1. Start container:

```powershell
docker compose -f docker-compose.elasticsearch.yml up -d
docker logs -f danipa-elasticsearch
```

2. Verify health:

```powershell
curl http://localhost:9200/_cluster/health?pretty
```

Expect status `"green"` or `"yellow"`.

## Verification

- Access: http://localhost:9200
- Default response should show cluster info in JSON.

## Maintenance

- Restart cleanly:
```powershell
docker compose -f docker-compose.elasticsearch.yml down
docker volume rm es-data   # WARNING: deletes all data
```
- Scale horizontally for production (multiple nodes).
- Monitor logs: `docker logs -f danipa-elasticsearch`.

## References

- [Elasticsearch Docs](https://www.elastic.co/guide/en/elasticsearch/reference/current/index.html)
