
# ![Danipa Logo](images/danipa_logo.png)

# Danipa Fintech Platform – Vault Certificate Management Guide

This guide explains how to **issue, reload, and verify Vault TLS certificates** in the **Danipa Fintech Platform** using `step-ca`, `docker compose`, and helper scripts.  
It applies to **Docker Compose environments** where Vault runs with **TLS enabled** and relies on `step-ca` as the local CA.

---

## 📌 Purpose

- Automate **Vault TLS certificate issuance** with SANs.
- Reload Vault seamlessly after certificate rotation.
- Provide repeatable steps to **check Vault health** and **unseal if necessary**.
- Standardize workflow using a `Makefile`.

---

## 🔑 Prerequisites

- Running **Vault** container (`danipa-vault`).
- Running **step-ca** container (`step-ca`).
- Root CA file available: `infra/vault/tls/root_ca.crt`.
- Make installed locally (`make`).

---

## ⚙️ Key Makefile Targets

### 🔹 `make vault-cert`

Issue a new TLS certificate for Vault via **step-ca** and reload Vault.

```bash
make vault-cert CN=vault.local.danipa.com SANS="vault.local.danipa.com vault localhost 127.0.0.1 api.vault.local"
```

✅ Example output:

```
>> Issuing Vault cert for CN=vault.local.danipa.com with SANs: vault.local.danipa.com vault localhost 127.0.0.1 api.vault.local
Your certificate has been saved in /tmp/server.crt.
Your private key has been saved in /tmp/server.key.
Successfully copied .../infra/vault/tls/server.crt
Successfully copied .../infra/vault/tls/server.key
certs_in_file=2
subject=CN = vault.local.danipa.com
issuer=O = Danipa Local CA, CN = Danipa Local CA Intermediate CA
notBefore=Sep 27 23:24:21 2025 GMT
notAfter=Mar 26 23:24:21 2026 GMT
Wrote: infra/vault/tls/server.crt and infra/vault/tls/server.key
```

Vault will then restart and serve the new cert.

---

### 🔹 `make vault-status`

Check Vault’s **seal status** inside the container (ignores TLS verification).

```bash
make vault-status
```

✅ Example output:

```
>> Checking Vault status (sealed/unsealed)...
Key             Value
---             -----
Seal Type       shamir
Initialized     true
Sealed          false
Total Shares    1
Threshold       1
Version         1.20.3
```

---

### 🔹 `make vault-unseal`

Unseal Vault manually if it comes up sealed.  
Two ways to provide the key:

**Option 1 – via environment variable**

```bash
export UNSEAL_KEY=rM1S/Gj9ClAWi4ZTJp/EIvSea03QW6WnWwZGbp+m1pM=
make vault-unseal
```

**Option 2 – via file (`infra/vault/keys/vault-unseal.key`)**

```bash
make vault-unseal
```

✅ Example output:

```
>> Unsealing Vault (non-interactive)...
Key             Value
---             -----
Seal Type       shamir
Initialized     true
Sealed          false
Total Shares    1
Threshold       1
Version         1.20.3
```

---

### 🔹 `make vault-health`

Check Vault’s **HTTPS API health endpoint** using the CA cert and pinned SNI.

```bash
make vault-health
# or override CN
make vault-health CN=api.vault.local
```

✅ Example output:

```json
{
  "initialized": true,
  "sealed": false,
  "standby": false,
  "version": "1.20.3",
  "cluster_name": "vault-cluster-8c87d10f",
  "cluster_id": "dd8b6853-6d02-85fb-c199-37be38663139"
}
```

---

## 🔍 Verification

After issuing and reloading, validate TLS and SANs manually:

```bash
curl -sS --cacert infra/vault/tls/root_ca.crt   --resolve vault.local.danipa.com:18300:127.0.0.1   https://vault.local.danipa.com:18300/v1/sys/health | jq
```

---

## 🛡️ Best Practices

- Always include **all SANs** Vault clients will use (`vault.local.danipa.com`, `vault`, `localhost`, cluster IPs).
- Rotate Vault certs proactively before expiry.
- Use `make vault-status` to confirm unseal state after restarts.
- Use `vault-unsealer` (daemon) for automatic unsealing in production.

---

## 🔧 Troubleshooting

### Healthcheck & Startup Timing

- The **`hashicorp/vault` image does not ship with `curl`**.  
  → The container’s healthcheck uses `vault status -tls-skip-verify` instead.
- After `docker compose up -d vault`, the container reports `(health: starting)` until:
    1. The Vault process binds to `:8200`,
    2. TLS listener is ready, and
    3. The unseal key(s) are applied (by manual `make vault-unseal` or the unsealer daemon).
- During this window:
    - `make vault-health` may fail once with `connection refused` or `SSL_ERROR_SYSCALL`.
    - Retrying after a few seconds should succeed.
- This is expected startup race behavior.  
  The container flips to **(healthy)** only once `Sealed=false`.

---

> **Summary**:  
> This guide standardizes the workflow for **TLS certificate management in Vault**, ensuring smooth certificate rotation, container reloads, health checks, and unsealing across the **Danipa Fintech Platform**.
