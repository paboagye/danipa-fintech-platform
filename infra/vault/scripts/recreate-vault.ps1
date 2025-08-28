# Stop & remove just the Vault container (volume is preserved)
docker compose stop vault
docker compose rm -f vault

# Fix ownership inside a one-shot helper container (this time the syntax is correct)
docker run --rm `
  -v danipa-fintech-platform_vault-data:/vault/data `
  alpine sh -c "chown -R 100:100 /vault/data && ls -ld /vault/data && ls -la /vault/data | head"

# Bring Vault back up
docker compose up -d vault

# Watch logs (should show normal startup; still 'not initialized' until we run init)
docker logs -f danipa-vault
