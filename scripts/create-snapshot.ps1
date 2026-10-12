$ErrorActionPreference = 'Stop' # Fail immediately on PowerShell errors so the caller never treats a failed snapshot as success.

# Require the deployment configuration before using the managed identity or touching a share.
$required = @('SUBSCRIPTION_ID', 'RESOURCE_GROUP', 'SOURCE_ACCOUNT', 'SOURCE_SHARE', 'WORKER_CLIENT_ID')
foreach ($name in $required) {
    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
        throw "Required environment variable is missing: $name"
    }
}

# Load Az modules and authenticate non-interactively as the VM's assigned identity.
Import-Module Az.Accounts -ErrorAction Stop
Import-Module Az.Storage -ErrorAction Stop
Connect-AzAccount -Identity -AccountId $env:WORKER_CLIENT_ID -ErrorAction Stop | Out-Null
Set-AzContext -SubscriptionId $env:SUBSCRIPTION_ID -ErrorAction Stop | Out-Null

# Create a classic Microsoft.Storage file-share snapshot (the same snapshot feature used for NFS shares).
$snapshot = New-AzRmStorageShare `
    -ResourceGroupName $env:RESOURCE_GROUP `
    -StorageAccountName $env:SOURCE_ACCOUNT `
    -Name $env:SOURCE_SHARE `
    -Snapshot `
    -ErrorAction Stop

$snapshotTime = $snapshot.SnapshotTime
if (-not $snapshotTime) {
    # Fall back only if the module omitted the response property; Azure's resulting share view remains authoritative.
    $snapshotTime = (Get-Date).ToUniversalTime()
}

# Emit one ISO-8601 UTC value for Bash to resolve the corresponding .snapshots directory; never print credentials.
[Console]::Out.WriteLine(([DateTime]$snapshotTime).ToUniversalTime().ToString('o'))
