[CmdletBinding()]
# Deploy only the disposable lab after validating and reviewing a create-only Terraform plan.
param(
    [Parameter(Mandatory)]
    [string]$ExpectedSubscription,
    [Parameter(Mandatory)]
    [string]$ExpectedResourceGroup,
    [string]$TerraformDirectory = (Join-Path $PSScriptRoot '..\infra')
)

$ErrorActionPreference = 'Stop'
# Resolve the lab IaC folder and name the saved plan so apply uses the exact reviewed actions.
$terraformRoot = (Resolve-Path $TerraformDirectory).Path
$planPath = Join-Path $terraformRoot 'deploy-review.tfplan'

# Terraform receives only the public key through the environment; the private key is never read by this script.
if ([string]::IsNullOrWhiteSpace($env:TF_VAR_admin_ssh_public_key)) {
    throw 'Set TF_VAR_admin_ssh_public_key to the lab VM public key before planning/deploying.'
}

Push-Location $terraformRoot
try {
    # Guard against accidentally deploying into another subscription or resource group.
    $tfvarsText = Get-Content -Raw terraform.tfvars
    $subscriptionMatch = [regex]::Match($tfvarsText, '(?m)^\s*subscription_id\s*=\s*"([^"]+)"\s*$')
    $resourceGroupMatch = [regex]::Match($tfvarsText, '(?m)^\s*resource_group_name\s*=\s*"([^"]+)"\s*$')
    if (-not $subscriptionMatch.Success -or $subscriptionMatch.Groups[1].Value -ne $ExpectedSubscription) {
        throw "Refusing deploy: tfvars subscription is not the expected '$ExpectedSubscription'."
    }
    if (-not $resourceGroupMatch.Success -or $resourceGroupMatch.Groups[1].Value -ne $ExpectedResourceGroup) {
        throw "Refusing deploy: tfvars resource group is not the expected '$ExpectedResourceGroup'."
    }

    # The lab intentionally uses local Terraform state rather than creating a remote state backend.
    terraform init -backend=false
    if ($LASTEXITCODE -ne 0) { throw 'Terraform init failed.' }

    terraform validate
    if ($LASTEXITCODE -ne 0) { throw 'Terraform validation failed.' }

    terraform plan "-out=$planPath"
    if ($LASTEXITCODE -ne 0) { throw 'Terraform deployment plan failed.' }

    # Inspect the machine-readable saved plan and reject updates, replacements, or deletes.
    $planJson = terraform show -json $planPath | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'Could not read the saved Terraform plan.' }
    $changes = @($planJson.resource_changes | Where-Object { $_.change.actions -notcontains 'no-op' })
    $unsafe = @($changes | Where-Object {
        $actions = (@($_.change.actions) -join ',')
        $actions -ne 'create'
    })
    if ($unsafe.Count -gt 0) {
        $unsafe | ForEach-Object { Write-Error "Plan is not create-only: $($_.address) actions=$($_.change.actions -join ',')" }
        throw 'Refusing apply because the plan contains an update, replacement, or deletion.'
    }

    # Surface the major cost, exposure, region, and destructive-teardown implications before asking for approval.
    Write-Host "Reviewed plan: $($changes.Count) resources to create; no resource updates, replacements, or deletions."
    Write-Host 'Cost/exposure: premium NFS capacity for two shares, 128-GiB staging disk, VM runtime, private endpoints, public IPv4 for outbound bootstrap, and Blob storage/transactions. Seed and recovery-point data incur additional charges.'
    Write-Host 'The lab is in Southeast Asia. Destroying it removes all NFS snapshots, source/restore data, and Blob recovery points.'
    # Require a scope-bound phrase; a casual yes/continue must not provision billable Azure resources.
    $confirmation = Read-Host "Type DEPLOY $ExpectedResourceGroup IN $ExpectedSubscription to apply this exact saved plan"
    if ($confirmation -cne "DEPLOY $ExpectedResourceGroup IN $ExpectedSubscription") {
        Write-Host 'Deployment cancelled. No Azure resources were created.'
        exit 0
    }

    # Apply precisely the plan just displayed; do not silently create a fresh, potentially different plan.
    terraform apply $planPath
    if ($LASTEXITCODE -ne 0) { throw 'Terraform apply failed; inspect state and Azure resources before retrying.' }
}
finally {
    Pop-Location
}
