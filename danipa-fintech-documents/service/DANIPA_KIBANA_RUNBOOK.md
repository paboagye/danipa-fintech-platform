# ![Danipa Logo](../images/danipa_logo.png)

# Danipa Kibana Setup & Runbook

This document explains how to configure, run, validate, and maintain **Kibana** for the Danipa Fintech Platform.

## Service Overview

Kibana provides visualization and UI access for Elasticsearch data.

## Prerequisites

- Running Elasticsearch service
- Docker & Docker Compose installed

## Configuration

### docker-compose.kibana.yml

```yaml
services:
  kibana:
    image: docker.elastic.co/kibana/kibana:8.14.1
    container_name: danipa-kibana
    environment:
      - ELASTICSEARCH_HOSTS=http://elasticsearch:9200
    ports:
      - "5601:5601"
    depends_on:
      - elasticsearch
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://localhost:5601/api/status"]
      interval: 10s
      timeout: 5s
      retries: 10
```

## Setup & Initialization

1. Start container:

```powershell
docker compose -f docker-compose.kibana.yml up -d
docker logs -f danipa-kibana
```

2. Verify health:

```powershell
curl http://localhost:5601/api/status
```

## Verification

- Access Kibana UI: http://localhost:5601
- Navigate to dashboards, logs, and monitoring.

## Maintenance

- Restart service:
```powershell
docker restart danipa-kibana
```
- Ensure Elasticsearch is healthy before starting Kibana.

## References

- [Kibana Docs](https://www.elastic.co/guide/en/kibana/current/index.html)
