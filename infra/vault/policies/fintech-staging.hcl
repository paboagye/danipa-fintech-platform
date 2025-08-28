# Fintech staging can read only its env namespaces in KV v2
path "secret/data/danipa/fintech,staging" { capabilities = ["read"] }
path "secret/data/danipa/postgres/staging" { capabilities = ["read"] }
