# Danipa • Makefile Wrapper Usage

This Makefile wraps `infra/vault/scripts/write-secrets.sh` to standardize Vault seeding and verification commands.

## Requirements

- `make`
- Vault reachable (default `http://127.0.0.1:18300`)
- Admin/root `TOKEN` exported or passed inline

## Main targets

| Target               | Effect |
|----------------------|--------|
| `make vault-verify`  | Runs verification only (all envs or `ENVS=...`). |
| `make vault-seed`    | Seeds all envs listed in `ENVS` (default: dev,staging,prod). |
| `make vault-seed-dev` / `-staging` / `-prod` | Seed a single environment. |
| `make vault-dry-run` | Prints intended actions; no writes. |
| `make vault-show-values` | Seeds while printing raw values (debug only!). |

## Variables

| Variable     | Default               | Notes |
|--------------|-----------------------|-------|
| `TOKEN`      | _(required)_          | Admin/root token. |
| `VAULT_ADDR` | `http://127.0.0.1:18300` | Passed through to script. |
| `ENVS`       | `dev,staging,prod`    | Comma-separated env list. |

## Examples

```bash
# Verify policies & caps across all envs
make vault-verify TOKEN="<root>"

# Verify only staging
make vault-verify TOKEN="<root>" ENVS=staging

# Seed all envs
make vault-seed TOKEN="<root>"

# Seed one env
make vault-seed-prod TOKEN="<root>"

# Dry run planned actions
make vault-dry-run TOKEN="<root>"

# Debug: show values while seeding (do not use in CI)
make vault-show-values TOKEN="<root>"
```

> Tip: you can set `TOKEN` once in your shell: `export TOKEN=<root>` and omit it from subsequent commands.
