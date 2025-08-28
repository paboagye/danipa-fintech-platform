
---
layout: page
title: Developers
permalink: /developers/
---

## Developer Portal

### Swagger & API Docs
- **Sandbox**: `https://dev.danipa.com/swagger-ui/` (placeholder)
- **OpenAPI**: `https://dev.danipa.com/v3/api-docs` (placeholder)

### Quick Start
```bash
# Local compose (dev)
docker compose --env-file .env.dev up --build -d

# Check health
curl -u cfg-user:cfg-pass http://localhost:8088/actuator/health
curl http://localhost:8761/actuator/health
curl http://localhost:8080/api/actuator/health
```

### SDKs & Samples
- Java SDK (planned)
- Postman Collection (planned)
