# Danipa Vault Starter (v5)

## What’s included
- `docker-compose.vault.yml` — local Vault (UI on 8300) with healthcheck
- `scripts/vault-init-env.sh` — initialize **dev/staging/prod**, write policies & AppRoles, seed per-env secrets
- `scripts/make-envfiles.sh` — generate `.env.vault.<env>` from `./out/`
- `scripts/verify-stack.sh` — checks Vault health + reads KV + hits Config, Eureka, Fintech health
- `policies/*` — least-privilege per env + config-server policy
- `spring/fintech/bootstrap.yml` — Spring Cloud Vault using profile-aware KV contexts

## Quickstart
```bash
docker compose -f docker-compose.vault.yml up -d
export VAULT_ADDR=http://127.0.0.1:8300
export VAULT_TOKEN=<root-or-admin-token>

# Initialize DEV using your existing env file
ENV_FILE=../danipa-fintech-platform/.env.dev ./scripts/vault-init-env.sh dev

# Create Compose env file with AppRole creds
./scripts/make-envfiles.sh dev

# Verify end to end
ENV_FILE=.env.dev ./scripts/verify-stack.sh dev
```

## Paths seeded
- `secret/danipa/config` — `config.user`, `config.pass`
- `secret/danipa/fintech/<env>` — `actuator.user`, `actuator.pass`, `momo.*` (apiUserId, apiKey, remittance/collection/disbursements.subscriptionKey, callbackUrl)
- `secret/danipa/postgres/<env>` — `postgres.admin.*`, `postgres.app.*`, `postgres.db`, `postgres.port`

## Compose usage
Run your stack with your existing env file(s) plus the generated vault env file:
```bash
docker compose --env-file .env.dev --env-file .env.vault.dev -f docker-compose.yml up -d
```
