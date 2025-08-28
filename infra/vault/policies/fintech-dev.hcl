# Fintech dev can read only its env namespaces in KV v2
path "secret/data/danipa/fintech,dev" { capabilities = ["read"] }
path "secret/data/danipa/postgres/dev" { capabilities = ["read"] }
