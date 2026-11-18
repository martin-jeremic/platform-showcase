# Seed the platform secrets into the island's Key Vault.
#
# Idempotent in shape, NOT in effect: re-running mints NEW passwords and adds a new
# version of each secret. That is a rotation, not a no-op -- read the caveats at the
# bottom before running it a second time against a live platform.
#
#   az login
#   az account set --subscription "<platform subscription>"
#   .\scripts\seed-secrets.ps1 -VaultName kv-product-a-prod
#
# Requires Key Vault Secrets Officer on the vault. The workloads' own identities
# hold Key Vault Secrets User (read-only) and are not what this uses.
param(
    [Parameter(Mandatory = $true)][string]$VaultName
)

$ErrorActionPreference = 'Stop'

# Alphanumeric only, deliberately: these values end up in a JDBC URL and an AMQP
# URI. Excluding punctuation removes every escaping and URL-encoding question at the
# cost of ~4 bits of entropy over 32 characters.
#
# CSPRNG, not Get-Random -- on Windows PowerShell 5.1 that is System.Random, seeded
# from a low-resolution clock and not fit for production credentials.
function New-Pw {
    param([int]$Length = 32)
    $charset = [char[]]((48..57) + (65..90) + (97..122))   # 0-9 A-Z a-z
    $bytes   = [byte[]]::new($Length * 4)
    $rng     = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $sb = [System.Text.StringBuilder]::new($Length)
    for ($i = 0; $i -lt $Length; $i++) {
        # 4 bytes -> one index. The modulo bias across a 2^32 range into 62 buckets
        # is ~1e-8 -- irrelevant here.
        $v = [BitConverter]::ToUInt32($bytes, $i * 4)
        [void]$sb.Append($charset[$v % $charset.Length])
    }
    $sb.ToString()
}

function Set-KvSecret {
    param([string]$Name, [string]$Value)
    # -o none: `az keyvault secret set` echoes the secret VALUE in its JSON result.
    # Without this every password lands in the console and the shell transcript.
    az keyvault secret set --vault-name $VaultName --name $Name --value $Value -o none
    if ($LASTEXITCODE -ne 0) {
        throw "FAILED to set '$Name' (az exit $LASTEXITCODE). Check az login, the active subscription, and Key Vault Secrets Officer on $VaultName."
    }
    Write-Host "  seeded  $Name"
}

Write-Host "Seeding platform secrets into $VaultName ..."

# ONE credential, TWO vault entries: the broker reads the first, Keycloak's event SPI
# the second. If they ever drift, Keycloak starts healthy and silently publishes no
# events -- a failure with no error anywhere.
$rmq = New-Pw
Set-KvSecret -Name 'rabbitmq--password'           -Value $rmq
Set-KvSecret -Name 'keycloak--rabbitmq--password' -Value $rmq

Set-KvSecret -Name 'elasticsearch--password'   -Value (New-Pw)
Set-KvSecret -Name 'keycloak--db--password'    -Value (New-Pw)
Set-KvSecret -Name 'keycloak--admin--password' -Value (New-Pw)

Write-Host "`nVerifying (names only -- no value is printed):"
az keyvault secret list --vault-name $VaultName `
    --query "[?name=='rabbitmq--password' || name=='elasticsearch--password' || starts_with(name,'keycloak--')].name" `
    -o tsv
if ($LASTEXITCODE -ne 0) { throw "verification list failed (az exit $LASTEXITCODE)" }

Write-Host @"

RE-RUNNING THIS IS A ROTATION, NOT A REPLAY. Three of these are not safe to rotate
by changing the vault alone:

  keycloak--db--password    must also be changed on the Postgres role, or Keycloak
                            cannot connect after Reloader restarts it.
  elasticsearch--password   applied on FIRST start only; afterwards change it through
                            the _security/user/elastic/_password API as well.
  rabbitmq--password        must stay byte-identical to keycloak--rabbitmq--password.
"@
