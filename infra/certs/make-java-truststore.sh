# From repo root
mkdir -p infra/java-truststores

# Option A (recommended): PKCS12 truststore
keytool -importcert \
  -alias step-root \
  -file infra/step/root_ca.crt \
  -keystore infra/java-truststores/step-root.p12 \
  -storetype PKCS12 \
  -storepass changeit \
  -noprompt

# Option B (JKS) if you prefer:
# keytool -importcert \
#   -alias step-root \
#   -file infra/step/root_ca.crt \
#   -keystore infra/java-truststores/step-root.jks \
#   -storetype JKS \
#   -storepass changeit \
#   -noprompt
