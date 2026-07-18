#!/usr/bin/env bash
# Generates a local CA, Kafka broker keystore/truststore, and a client
# keystore for mTLS testing. Run from repo root or any cwd.
#
# Password for all stores/keys: kafkadev
#
# Equivalent of scripts/generate-certs.ps1 for Linux / macOS.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS="${ROOT}/secrets"
PASSWORD="kafkadev"
VALIDITY_DAYS=3650

if ! command -v keytool >/dev/null 2>&1; then
  echo "error: keytool not found on PATH (install a JDK)" >&2
  exit 1
fi

mkdir -p "${SECRETS}"

# Wipe previous generated material so reruns are clean.
find "${SECRETS}" -mindepth 1 -maxdepth 1 -type f -delete

run_keytool() {
  keytool "$@"
}

echo "Creating CA..."
run_keytool -genkeypair \
  -alias ca \
  -keyalg RSA \
  -keysize 4096 \
  -validity "${VALIDITY_DAYS}" \
  -keystore "${SECRETS}/ca.keystore.jks" \
  -storepass "${PASSWORD}" \
  -keypass "${PASSWORD}" \
  -dname "CN=Kafka-Dev-CA,OU=Dev,O=Local,C=US" \
  -ext "bc=ca:true" \
  -storetype JKS

run_keytool -exportcert \
  -alias ca \
  -keystore "${SECRETS}/ca.keystore.jks" \
  -storepass "${PASSWORD}" \
  -file "${SECRETS}/ca.crt" \
  -rfc

echo "Creating broker keystore..."
run_keytool -genkeypair \
  -alias kafka \
  -keyalg RSA \
  -keysize 2048 \
  -validity "${VALIDITY_DAYS}" \
  -keystore "${SECRETS}/kafka.keystore.jks" \
  -storepass "${PASSWORD}" \
  -keypass "${PASSWORD}" \
  -dname "CN=kafka,OU=Dev,O=Local,C=US" \
  -ext "SAN=DNS:kafka,DNS:localhost,IP:127.0.0.1" \
  -storetype JKS

run_keytool -certreq \
  -alias kafka \
  -keystore "${SECRETS}/kafka.keystore.jks" \
  -storepass "${PASSWORD}" \
  -file "${SECRETS}/kafka.csr"

run_keytool -gencert \
  -alias ca \
  -keystore "${SECRETS}/ca.keystore.jks" \
  -storepass "${PASSWORD}" \
  -infile "${SECRETS}/kafka.csr" \
  -outfile "${SECRETS}/kafka.crt" \
  -ext "SAN=DNS:kafka,DNS:localhost,IP:127.0.0.1" \
  -validity "${VALIDITY_DAYS}" \
  -rfc

run_keytool -importcert \
  -alias ca \
  -file "${SECRETS}/ca.crt" \
  -keystore "${SECRETS}/kafka.keystore.jks" \
  -storepass "${PASSWORD}" \
  -noprompt

run_keytool -importcert \
  -alias kafka \
  -file "${SECRETS}/kafka.crt" \
  -keystore "${SECRETS}/kafka.keystore.jks" \
  -storepass "${PASSWORD}" \
  -noprompt

echo "Creating broker truststore..."
run_keytool -importcert \
  -alias ca \
  -file "${SECRETS}/ca.crt" \
  -keystore "${SECRETS}/kafka.truststore.jks" \
  -storepass "${PASSWORD}" \
  -noprompt \
  -storetype JKS

echo "Creating client keystore (mTLS)..."
run_keytool -genkeypair \
  -alias client \
  -keyalg RSA \
  -keysize 2048 \
  -validity "${VALIDITY_DAYS}" \
  -keystore "${SECRETS}/client.keystore.jks" \
  -storepass "${PASSWORD}" \
  -keypass "${PASSWORD}" \
  -dname "CN=kafka-client,OU=Dev,O=Local,C=US" \
  -storetype JKS

run_keytool -certreq \
  -alias client \
  -keystore "${SECRETS}/client.keystore.jks" \
  -storepass "${PASSWORD}" \
  -file "${SECRETS}/client.csr"

run_keytool -gencert \
  -alias ca \
  -keystore "${SECRETS}/ca.keystore.jks" \
  -storepass "${PASSWORD}" \
  -infile "${SECRETS}/client.csr" \
  -outfile "${SECRETS}/client.crt" \
  -validity "${VALIDITY_DAYS}" \
  -rfc

run_keytool -importcert \
  -alias ca \
  -file "${SECRETS}/ca.crt" \
  -keystore "${SECRETS}/client.keystore.jks" \
  -storepass "${PASSWORD}" \
  -noprompt

run_keytool -importcert \
  -alias client \
  -file "${SECRETS}/client.crt" \
  -keystore "${SECRETS}/client.keystore.jks" \
  -storepass "${PASSWORD}" \
  -noprompt

# Client truststore = CA only (same as broker truststore).
cp "${SECRETS}/kafka.truststore.jks" "${SECRETS}/client.truststore.jks"

# Confluent credential files (password only, no trailing newline).
printf '%s' "${PASSWORD}" >"${SECRETS}/keystore_creds"
printf '%s' "${PASSWORD}" >"${SECRETS}/key_creds"
printf '%s' "${PASSWORD}" >"${SECRETS}/truststore_creds"

# Sample client configs for host/container testing (LF line endings).
cat >"${SECRETS}/ssl-client.properties" <<EOF
security.protocol=SSL
ssl.truststore.location=/etc/kafka/secrets/client.truststore.jks
ssl.truststore.password=${PASSWORD}
ssl.endpoint.identification.algorithm=

EOF

cat >"${SECRETS}/mtls-client.properties" <<EOF
security.protocol=SSL
ssl.truststore.location=/etc/kafka/secrets/client.truststore.jks
ssl.truststore.password=${PASSWORD}
ssl.keystore.location=/etc/kafka/secrets/client.keystore.jks
ssl.keystore.password=${PASSWORD}
ssl.key.password=${PASSWORD}
ssl.endpoint.identification.algorithm=

EOF

# Clean intermediate CSR files.
rm -f "${SECRETS}/kafka.csr" "${SECRETS}/client.csr"

echo ""
echo "Done. Files written to: ${SECRETS}"
echo "Store/key password: ${PASSWORD}"
echo ""
echo "Listeners:"
echo "  PLAINTEXT : localhost:9092"
echo "  SSL       : localhost:9093  (no mTLS)"
echo "  MTLS      : localhost:9094  (require client cert)"
