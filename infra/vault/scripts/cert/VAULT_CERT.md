# ![Danipa Logo](../../../../images/danipa_logo.png)

# Danipa Fintech Platform – Vault TLS Certificate Management Guide

This guide explains how to use the `vault_cert.sh` script to **issue and manage TLS certificates for Vault** using the Danipa `step-ca` container.  
It ensures that Vault always presents a **valid, SAN-aware, CA-signed certificate** for secure communication.

---

## 📌 Purpose

- Automate certificate issuance from **step-ca** for Vault.
- Embed **Subject Alternative Names (SANs)** such as service DNS, localhost, and IPs.
- Eliminate interactive prompts (`--force`, `--no-password`, `--insecure`).
- Provide **consistent storage** of certs/keys under `infra/vault/tls/`.

---

## ⚙️ Script Location

```bash
infra/vault/scripts/cert/vault_cert.sh
```

---

## 🔍 Usage

```bash
Usage: vault_cert.sh issue <common-name>
```

- `<common-name>` → the CN (primary hostname) to appear in the certificate (e.g. `vault.local.danipa.com`).
- By default, SANs include:
  - `<CN>`
  - `vault`
  - `localhost`
  - `127.0.0.1`
- Extra SANs may be passed via the `SANS` environment variable.

---

## 🚀 Examples

### 1. Basic issuance
```bash
infra/vault/scripts/cert/vault_cert.sh issue vault.local.danipa.com
```

✅ Expected output:
```text
>> ACTION=issue  CN=vault.local.danipa.com
>> SANs: vault.local.danipa.com vault localhost 127.0.0.1
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

---

### 2. Issuance with extra SANs
```bash
SANS="api.vault.local 10.0.0.10" \
infra/vault/scripts/cert/vault_cert.sh issue vault.local.danipa.com
```

✅ Expected output:
```text
>> ACTION=issue  CN=vault.local.danipa.com
>> SANs: vault.local.danipa.com vault localhost 127.0.0.1 api.vault.local 10.0.0.10
...
Wrote: infra/vault/tls/server.crt and infra/vault/tls/server.key
```

---

### 3. Reload Vault with new cert
```bash
docker compose up -d --no-deps --force-recreate vault
```

---

### 4. Verify served cert
```bash
openssl s_client -connect 127.0.0.1:18300 -servername vault.local.danipa.com -showcerts </dev/null | sed -n '1,120p'
```

Or use the API with your CA root:
```bash
curl -sS --cacert infra/vault/tls/root_ca.crt \
  --resolve vault.local.danipa.com:18300:127.0.0.1 \
  https://vault.local.danipa.com:18300/v1/sys/health | jq
```

---

## 🛡️ Best Practices

- Always **include all hostnames and IPs** Vault may be addressed by in SANs.
- Rotate the cert **before expiry** (`--not-after=4320h` ≈ 180 days).
- Store keys with **restricted permissions** (`0600` for private key).
- Restart Vault after each new issuance.
- Validate with `openssl s_client` and `curl` before trusting the setup.

---

## ✅ Quick Checklist

- [ ] Cert saved under `infra/vault/tls/`
- [ ] SANs include all required DNS/IPs
- [ ] Vault restarted with new cert
- [ ] API health endpoint works with CA trust
- [ ] No interactive prompts during issuance

---

> **Summary**: This guide ensures Vault always runs with a **valid, CA-signed TLS certificate** using the automated `vault_cert.sh` script, with predictable SANs, no prompts, and consistent storage under `infra/vault/tls/`.
