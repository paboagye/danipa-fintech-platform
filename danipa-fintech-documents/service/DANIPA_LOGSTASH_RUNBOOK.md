# ![Danipa Logo](../images/danipa_logo.png)

# Danipa Logstash Setup & Runbook

This document explains how to configure, run, validate, and maintain **Logstash** for the Danipa Fintech Platform.

## Service Overview

Logstash ingests, transforms, and ships logs/metrics into Elasticsearch.

## Prerequisites

- Running Elasticsearch service
- Docker & Docker Compose installed
- Logstash pipeline config files

## Configuration

### docker-compose.logstash.yml

```yaml
services:
  logstash:
    image: docker.elastic.co/logstash/logstash:8.14.1
    container_name: danipa-logstash
    volumes:
      - ./logstash/pipeline:/usr/share/logstash/pipeline
    ports:
      - "5044:5044"
      - "9600:9600"
    depends_on:
      - elasticsearch
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://localhost:9600/_node/pipelines"]
      interval: 10s
      timeout: 5s
      retries: 10
```

### Example pipeline (`logstash/pipeline/logstash.conf`)

```conf
input {
  beats {
    port => 5044
  }
}

filter { }

output {
  elasticsearch {
    hosts => ["http://elasticsearch:9200"]
    index => "danipa-logs-%{+YYYY.MM.dd}"
  }
  stdout { codec => rubydebug }
}
```

## Setup & Initialization

1. Start container:

```powershell
docker compose -f docker-compose.logstash.yml up -d
docker logs -f danipa-logstash
```

2. Verify pipelines:

```powershell
curl http://localhost:9600/_node/pipelines?pretty
```

## Verification

- Check Elasticsearch indices:

```powershell
curl http://localhost:9200/_cat/indices?v
```

Expect indices starting with `danipa-logs-*`.

## Maintenance

- Update pipelines in `logstash/pipeline/` and restart container:
```powershell
docker restart danipa-logstash
```
- Monitor logs: `docker logs -f danipa-logstash`.

## References

- [Logstash Docs](https://www.elastic.co/guide/en/logstash/current/index.html)
