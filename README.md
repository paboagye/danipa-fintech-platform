# Danipa Fintech Platform – Infrastructure Setup

This repository contains the infrastructure components for the Danipa Fintech Platform, including the **Fintech Service**, **Config Server**, and **Eureka Discovery Server**.

## Table of Contents
- [Overview](#overview)
- [Architecture](#architecture)
- [Services](#services)
- [Configuration](#configuration)
- [Running Locally](#running-locally)
- [Docker & Deployment](#docker--deployment)
- [Monitoring & Health](#monitoring--health)
- [Contributing](#contributing)
- [License](#license)

## Overview
The Danipa Fintech Platform provides a modular, microservice-based architecture to integrate with **MTN MoMo APIs** and enable secure, scalable fintech operations. It includes:
- **danipa-fintech-service**: Core API service for MoMo integration and fintech operations.
- **danipa-config-server**: Centralized configuration management with Git-backed property sources.
- **danipa-eureka-server**: Service discovery using Netflix Eureka.

## Architecture
- **Spring Boot 3**
- **Spring Cloud Config** for centralized configuration
- **Eureka Discovery** for service registry
- **Vault** for secrets management
- **Resilience4j** for fault tolerance
- **Micrometer + Actuator** for monitoring
- **Docker** for containerization
- **GitHub Actions** for CI/CD

```text
                        +------------------+
                        |  Config Server   |
                        | (Git-backed)     |
                        +------------------+
                                 |
                +----------------+----------------+
                |                                 |
+---------------------------+       +---------------------------+
|   Fintech Service (MoMo) | <-->  |   Eureka Discovery Server |
+---------------------------+       +---------------------------+
```

## Services
### danipa-fintech-service
- Handles MTN MoMo API calls (Remittance, Disbursements, Collections).
- Exposes REST APIs with Swagger/OpenAPI documentation.
- Uses Redis for caching and token storage.

### danipa-config-server
- Loads configuration from a Git repository or local filesystem.
- Supports hot reloading via `/actuator/refresh` or Spring Cloud Bus.

### danipa-eureka-server
- Service registry for dynamic discovery of fintech microservices.

## Configuration
Each service uses **bootstrap.properties** or **application.properties** for configuration.  
Example for `danipa-fintech-service`:
```properties
spring.application.name=danipa-fintech-service
spring.cloud.config.uri=http://localhost:8888
spring.profiles.active=dev
```

Example Git-backed config in `danipa-config-server`:
```properties
spring.cloud.config.server.git.uri=https://github.com/<org>/<repo>-config
spring.cloud.config.server.git.clone-on-start=true
```

## Running Locally
1. Start the **Config Server**:
   ```sh
   cd danipa-config-server
   mvn spring-boot:run
   ```

2. Start the **Eureka Server**:
   ```sh
   cd danipa-eureka-server
   mvn spring-boot:run
   ```

3. Start the **Fintech Service**:
   ```sh
   cd danipa-fintech-service
   mvn spring-boot:run
   ```

## Docker & Deployment
Each service includes a `Dockerfile`. You can build and run them via:
```sh
docker-compose up --build
```

This will bring up:
- `danipa-config-server` on port **8888**
- `danipa-eureka-server` on port **8761**
- `danipa-fintech-service` on port **8080**

## Monitoring & Health
- **Actuator Health Endpoint:** `http://localhost:8080/actuator/health`
- **Swagger UI:** `http://localhost:8080/swagger-ui.html`
- **Eureka Dashboard:** `http://localhost:8761`

## Contributing
This platform is actively maintained by **Patrick Aboagye**. Contributions and extensions will be supported in future releases.

## License
This project is licensed under the [Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0).
