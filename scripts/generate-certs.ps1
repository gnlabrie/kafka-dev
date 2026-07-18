# Generates a local CA, Kafka broker keystore/truststore, and a client
# keystore for mTLS testing. Run from repo root or any cwd.
#
# Password for all stores/keys: kafkadev

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$Secrets = Join-Path $Root "secrets"
$Password = "kafkadev"
$ValidityDays = 3650

New-Item -ItemType Directory -Force -Path $Secrets | Out-Null

# Wipe previous generated material so reruns are clean.
Get-ChildItem -Path $Secrets -File | Remove-Item -Force

function Invoke-Keytool {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
    & keytool @Args
    if ($LASTEXITCODE -ne 0) {
        throw "keytool failed: keytool $($Args -join ' ')"
    }
}

Write-Host "Creating CA..."
Invoke-Keytool -genkeypair `
    -alias "ca" `
    -keyalg "RSA" `
    -keysize "4096" `
    -validity $ValidityDays `
    -keystore (Join-Path $Secrets "ca.keystore.jks") `
    -storepass $Password `
    -keypass $Password `
    -dname "CN=Kafka-Dev-CA,OU=Dev,O=Local,C=US" `
    -ext "bc=ca:true" `
    -storetype "JKS"

Invoke-Keytool -exportcert `
    -alias "ca" `
    -keystore (Join-Path $Secrets "ca.keystore.jks") `
    -storepass $Password `
    -file (Join-Path $Secrets "ca.crt") `
    -rfc

Write-Host "Creating broker keystore..."
Invoke-Keytool -genkeypair `
    -alias "kafka" `
    -keyalg "RSA" `
    -keysize "2048" `
    -validity $ValidityDays `
    -keystore (Join-Path $Secrets "kafka.keystore.jks") `
    -storepass $Password `
    -keypass $Password `
    -dname "CN=kafka,OU=Dev,O=Local,C=US" `
    -ext "SAN=DNS:kafka,DNS:localhost,IP:127.0.0.1" `
    -storetype "JKS"

Invoke-Keytool -certreq `
    -alias "kafka" `
    -keystore (Join-Path $Secrets "kafka.keystore.jks") `
    -storepass $Password `
    -file (Join-Path $Secrets "kafka.csr")

Invoke-Keytool -gencert `
    -alias "ca" `
    -keystore (Join-Path $Secrets "ca.keystore.jks") `
    -storepass $Password `
    -infile (Join-Path $Secrets "kafka.csr") `
    -outfile (Join-Path $Secrets "kafka.crt") `
    -ext "SAN=DNS:kafka,DNS:localhost,IP:127.0.0.1" `
    -validity $ValidityDays `
    -rfc

Invoke-Keytool -importcert `
    -alias "ca" `
    -file (Join-Path $Secrets "ca.crt") `
    -keystore (Join-Path $Secrets "kafka.keystore.jks") `
    -storepass $Password `
    -noprompt

Invoke-Keytool -importcert `
    -alias "kafka" `
    -file (Join-Path $Secrets "kafka.crt") `
    -keystore (Join-Path $Secrets "kafka.keystore.jks") `
    -storepass $Password `
    -noprompt

Write-Host "Creating broker truststore..."
Invoke-Keytool -importcert `
    -alias "ca" `
    -file (Join-Path $Secrets "ca.crt") `
    -keystore (Join-Path $Secrets "kafka.truststore.jks") `
    -storepass $Password `
    -noprompt `
    -storetype "JKS"

Write-Host "Creating client keystore (mTLS)..."
Invoke-Keytool -genkeypair `
    -alias "client" `
    -keyalg "RSA" `
    -keysize "2048" `
    -validity $ValidityDays `
    -keystore (Join-Path $Secrets "client.keystore.jks") `
    -storepass $Password `
    -keypass $Password `
    -dname "CN=kafka-client,OU=Dev,O=Local,C=US" `
    -storetype "JKS"

Invoke-Keytool -certreq `
    -alias "client" `
    -keystore (Join-Path $Secrets "client.keystore.jks") `
    -storepass $Password `
    -file (Join-Path $Secrets "client.csr")

Invoke-Keytool -gencert `
    -alias "ca" `
    -keystore (Join-Path $Secrets "ca.keystore.jks") `
    -storepass $Password `
    -infile (Join-Path $Secrets "client.csr") `
    -outfile (Join-Path $Secrets "client.crt") `
    -validity $ValidityDays `
    -rfc

Invoke-Keytool -importcert `
    -alias "ca" `
    -file (Join-Path $Secrets "ca.crt") `
    -keystore (Join-Path $Secrets "client.keystore.jks") `
    -storepass $Password `
    -noprompt

Invoke-Keytool -importcert `
    -alias "client" `
    -file (Join-Path $Secrets "client.crt") `
    -keystore (Join-Path $Secrets "client.keystore.jks") `
    -storepass $Password `
    -noprompt

# Client truststore = CA only (same as broker truststore).
Copy-Item (Join-Path $Secrets "kafka.truststore.jks") (Join-Path $Secrets "client.truststore.jks")

# Confluent credential files (password only, no trailing newline).
[System.IO.File]::WriteAllText((Join-Path $Secrets "keystore_creds"), $Password)
[System.IO.File]::WriteAllText((Join-Path $Secrets "key_creds"), $Password)
[System.IO.File]::WriteAllText((Join-Path $Secrets "truststore_creds"), $Password)

# Sample client configs for host/container testing (LF line endings).
$sslClient = @"
security.protocol=SSL
ssl.truststore.location=/etc/kafka/secrets/client.truststore.jks
ssl.truststore.password=$Password
ssl.endpoint.identification.algorithm=

"@
$mtlsClient = @"
security.protocol=SSL
ssl.truststore.location=/etc/kafka/secrets/client.truststore.jks
ssl.truststore.password=$Password
ssl.keystore.location=/etc/kafka/secrets/client.keystore.jks
ssl.keystore.password=$Password
ssl.key.password=$Password
ssl.endpoint.identification.algorithm=

"@
[System.IO.File]::WriteAllText((Join-Path $Secrets "ssl-client.properties"), ($sslClient -replace "`r`n", "`n"))
[System.IO.File]::WriteAllText((Join-Path $Secrets "mtls-client.properties"), ($mtlsClient -replace "`r`n", "`n"))

# Clean intermediate CSR files.
Remove-Item (Join-Path $Secrets "kafka.csr"), (Join-Path $Secrets "client.csr") -Force

Write-Host ""
Write-Host "Done. Files written to: $Secrets"
Write-Host "Store/key password: $Password"
Write-Host ""
Write-Host "Listeners:"
Write-Host "  PLAINTEXT : localhost:9092"
Write-Host "  SSL       : localhost:9093  (no mTLS)"
Write-Host "  SSL_MTLS  : localhost:9094  (require client cert)"
