# Certificate generation (`generate-certs`)

Generates a local self-signed PKI for kafka-dev: a CA, broker keystore/truststore, client keystore/truststore for mTLS, Confluent password files, and sample client property files.

| Platform | Script |
|----------|--------|
| Windows | [`scripts/generate-certs.ps1`](../scripts/generate-certs.ps1) |
| Linux / macOS | [`scripts/generate-certs.sh`](../scripts/generate-certs.sh) |

Both scripts produce the **same** files under **`secrets/`** (created if missing). That folder is gitignored.

## Prerequisites

- Java with `keytool` on `PATH` (Temurin / OpenJDK 17+ is fine)
- **Windows:** PowerShell
- **Linux / macOS:** `bash`

## Usage

### Windows

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\generate-certs.ps1
docker compose up -d --force-recreate
```

### Linux / macOS

```bash
chmod +x ./scripts/generate-certs.sh   # once
./scripts/generate-certs.sh
docker compose up -d --force-recreate
```

You can run either script from the repo root or any directory; paths are resolved from the script location.

### Important behavior

- **Destructive:** every file currently under `secrets/` is deleted before generation.
- **Fixed password:** all stores and keys use `kafkadev`.
- **Validity:** certificates are issued for **3650 days** (~10 years).
- Intermediate CSR files are removed after signing; they are not left in `secrets/`.

## What it creates

### Certificate authority

| File | Description |
|------|-------------|
| `ca.keystore.jks` | CA private key + self-signed CA cert (`CN=Kafka-Dev-CA`, RSA 4096, `bc=ca:true`) |
| `ca.crt` | CA certificate exported PEM/RFC text (used to build truststores and sign CSRs) |

### Broker (server) material

| File | Description |
|------|-------------|
| `kafka.keystore.jks` | Broker private key + chain (`CN=kafka`, RSA 2048). SAN: `DNS:kafka`, `DNS:localhost`, `IP:127.0.0.1` |
| `kafka.crt` | CA-signed broker certificate (also imported into the keystore) |
| `kafka.truststore.jks` | Truststore containing only the CA — used by the broker to validate **client** certs on the MTLS listener |

### Client (mTLS) material

| File | Description |
|------|-------------|
| `client.keystore.jks` | Client private key + chain (`CN=kafka-client`, RSA 2048), signed by the same CA |
| `client.crt` | CA-signed client certificate |
| `client.truststore.jks` | Copy of `kafka.truststore.jks` — client trusts the broker via the CA |

### Confluent password files

Read by the `cp-kafka` image from `/etc/kafka/secrets/` (see `docker-compose.yml`):

| File | Used for |
|------|----------|
| `keystore_creds` | Password for `kafka.keystore.jks` |
| `key_creds` | Password for the private key inside the keystore |
| `truststore_creds` | Password for `kafka.truststore.jks` |

Each file contains only the password string (`kafkadev`), with no trailing newline.

### Sample client configs

Paths inside these files assume the Compose mount `./secrets` → `/etc/kafka/secrets`.

| File | Use with |
|------|----------|
| `ssl-client.properties` | TLS to **localhost:9093** (truststore only; no client cert) |
| `mtls-client.properties` | TLS to **localhost:9094** (truststore + client keystore) |

Both set `ssl.endpoint.identification.algorithm=` (empty) to match the broker’s disabled hostname verification.

## Generation flow (high level)

```text
1. Create CA keystore → export ca.crt
2. Create broker keypair → CSR → CA signs kafka.crt → import CA + signed cert into kafka.keystore.jks
3. Import ca.crt into kafka.truststore.jks
4. Create client keypair → CSR → CA signs client.crt → import into client.keystore.jks
5. Copy kafka.truststore.jks → client.truststore.jks
6. Write *_creds and *-client.properties
7. Delete temporary *.csr files
```

## How the broker uses these files

Mounted read-only in Compose:

```yaml
volumes:
  - ./secrets:/etc/kafka/secrets:ro
```

| Listener | Port | Needs from `secrets/` |
|----------|------|------------------------|
| `SSL` | 9093 | Broker keystore + truststore (client auth **none**) |
| `MTLS` | 9094 | Same + truststore validates client certs (**required**) |

PLAINTEXT (`9092`) does not use TLS files.

## Using the material from other tools

Copy as needed (example for a Java client on the host):

| Need | File | Type | Password |
|------|------|------|----------|
| Trust the broker | `client.truststore.jks` | JKS | `kafkadev` |
| Prove client identity (mTLS) | `client.keystore.jks` | JKS | `kafkadev` |

Adjust `ssl.*.location` paths to the host filesystem when not running inside the Kafka container.

## When to re-run

- First-time setup (before `docker compose up`)
- After deleting `secrets/`
- When rotating the local CA or client identity
- After changing SANs / DNs (edit the script, then regenerate)

After regenerating, recreate the container and update any external copies of the client stores (for example tools that copied certs out of `secrets/`).
