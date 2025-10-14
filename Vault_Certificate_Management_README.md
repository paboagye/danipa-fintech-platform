
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

Check Vault’s status **inside the container**. Ignores TLS verification.

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
Cluster Name    vault-cluster-8c87d10f
```

---

### 🔹 `make vault-unseal`

Unseal Vault manually if it comes up sealed.  
You can either **pass the key via env** or let Make read it from `infra/vault/keys/vault-unseal.key`.

```bash
# Option 1: Using environment variable
export UNSEAL_KEY=<your_unseal_key>
make vault-unseal

# Option 2: Using default key file
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

Check Vault’s **API health over TLS** with SNI pinned to your CN and the CA trusted.

```bash
make vault-health
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

You can also override the CN at runtime:

```bash
make vault-health CN=api.vault.local
```

---

## 🛡️ Best Practices

- Always include **all SANs** Vault clients will use (`vault.local.danipa.com`, `vault`, `localhost`, cluster IPs).
- Rotate Vault certs proactively before expiry.
- Use `make vault-status` to confirm unseal state after restarts.
- Use `make vault-health` to validate API TLS connectivity.
- Use `vault-unsealer` (daemon) for automatic unsealing in production.

---

> **Summary**:  
> This guide standardizes the workflow for **TLS certificate management in Vault**, ensuring smooth certificate rotation, container reloads, and health checks across the **Danipa Fintech Platform**.
