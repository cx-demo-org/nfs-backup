[CmdletBinding()]
# Destroy only the named disposable lab, after displaying Terraform's destroy-only plan and receiving typed consent.
param(
    [Parameter(Mandatory)]
    [string]$ExpectedSubscription,
    [Parameter(Mandatory)]
    [string]$ExpectedResourceGroup,
    [string]$TerraformDirectory = (Join-Path $PSScriptRoot '..\infra')
)

$ErrorActionPreference = 'Stop'
$terraformRoot = (Resolve-Path $TerraformDirectory).Path
# Keep the plan file separate and ignored by source control because Terraform plans can contain sensitive values.
$planPath = Join-Path $terraformRoot 'destroy-review.tfplan'

if ([string]::IsNullOrWhiteSpace($env:TF_VAR_admin_ssh_public_key)) {
    throw 'Set TF_VAR_admin_ssh_public_key to the lab VM public key before planning destruction.'
}

Push-Location $terraformRoot
try {
    # Verify both subscription and resource-group settings before requesting a destructive Terraform plan.
    $tfvarsText = Get-Content -Raw terraform.tfvars
    $subscriptionMatch = [regex]::Match($tfvarsText, '(?m)^\s*subscription_id\s*=\s*"([^"]+)"\s*$')
    $resourceGroupMatch = [regex]::Match($tfvarsText, '(?m)^\s*resource_group_name\s*=\s*"([^"]+)"\s*$')
    if (-not $subscriptionMatch.Success -or $subscriptionMatch.Groups[1].Value -ne $ExpectedSubscription) {
        throw "Refusing destroy: tfvars subscription is not the expected '$ExpectedSubscription'."
    }
    if (-not $resourceGroupMatch.Success -or $resourceGroupMatch.Groups[1].Value -ne $ExpectedResourceGroup) {
        throw "Refusing destroy: tfvars resource group is not the expected lab group '$ExpectedResourceGroup'."
    }

    Write-Host "Creating a destroy-only plan for the disposable lab resource group '$ExpectedResourceGroup'."
    # Generate a plan that can only destroy; show it in full before asking for confirmation.
    terraform plan -destroy "-out=$planPath"
    if ($LASTEXITCODE -ne 0) { throw 'Terraform destroy planning failed.' }

    terraform show $planPath
    if ($LASTEXITCODE -ne 0) { throw 'Could not display the destroy plan.' }

    # Explicitly name data loss in the prompt; the exact text is required to proceed.
    $confirmationPhrase = "DESTROY $ExpectedResourceGroup IN $ExpectedSubscription"
    $confirmation = Read-Host "This permanently deletes lab data, snapshots, backups, compute, and networking. Type '$confirmationPhrase' to apply this exact plan"
    if ($confirmation -cne $confirmationPhrase) {
        Write-Host 'Destroy cancelled. No resources were deleted.'
        exit 0
    }

    # Apply the saved plan that the operator reviewed, not a newly generated destroy plan.
    terraform apply $planPath
    if ($LASTEXITCODE -ne 0) { throw 'Terraform destroy apply failed; inspect state and Azure resources before retrying.' }
}
finally {
    Pop-Location
}
