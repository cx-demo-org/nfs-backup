[CmdletBinding()]
# Run one explicitly selected lab operation on the worker using Azure Run Command (no inbound SSH).
param(
    [Parameter(Mandatory)]
    [ValidateSet('seed', 'backup', 'restore')]
    [string]$Operation,

    [string]$RecoveryPointId,

    [Parameter(Mandatory)]
    [string]$SubscriptionId,
    [Parameter(Mandatory)]
    [string]$ResourceGroupName,
    [Parameter(Mandatory)]
    [string]$VmName
)

$ErrorActionPreference = 'Stop'

# Map the operator's short operation name to the corresponding root-owned VM script.
switch ($Operation) {
    'seed' { $remoteCommand = 'sudo bash /opt/nfs-backup/seed-test-data.sh' }
    'backup' { $remoteCommand = 'sudo bash /opt/nfs-backup/backup.sh' }
    'restore' {
        # A restore must name one recovery point and the value is restricted before interpolation into a shell command.
        if ([string]::IsNullOrWhiteSpace($RecoveryPointId)) {
            throw 'Provide -RecoveryPointId for a restore test.'
        }
        if ($RecoveryPointId -notmatch '^[A-Za-z0-9T._-]{1,80}$') {
            throw 'RecoveryPointId contains invalid characters.'
        }
        $remoteCommand = "sudo bash /opt/nfs-backup/restore-test.sh $RecoveryPointId"
    }
}

# Run Command executes inside the VM agent, so this wrapper needs Azure VM Run Command authorization.
Write-Host "Invoking $Operation on $VmName in $ResourceGroupName ($SubscriptionId). No SSH connection is opened."
$result = az vm run-command invoke `
    --subscription $SubscriptionId `
    --resource-group $ResourceGroupName `
    --name $VmName `
    --command-id RunShellScript `
    --scripts $remoteCommand `
    --output json
if ($LASTEXITCODE -ne 0) {
    throw "Azure Run Command failed with exit code $LASTEXITCODE."
}

# Surface guest stdout/stderr from the structured Azure response so operators can capture run IDs and failures.
$parsed = $result | ConvertFrom-Json
$instance = $parsed.value | Where-Object { $_.code -match 'ComponentStatus/StdOut' }
if ($instance) { Write-Output $instance.message }
$stderr = $parsed.value | Where-Object { $_.code -match 'ComponentStatus/StdErr' }
if ($stderr -and $stderr.message) { Write-Error $stderr.message }
