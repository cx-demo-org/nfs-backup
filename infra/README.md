# Terraform infrastructure

The Terraform files are scaffolded for the approved representative lab plan. They create only a new isolated resource group and disposable resources; they do not reference or mutate the existing storage accounts in the parent README.

## Resources

- Premium classic `FileStorage` account with source and restore NFS shares.
- Separate private HNS-enabled `StorageV2` account and recovery-point container with a 30-day lifecycle expiry (not WORM).
- Dedicated VNet, worker subnet, private-endpoint subnet, private DNS zones, and private endpoints for source File plus destination Blob and DFS.
- Single disposable Ubuntu VM with a 128-GiB staging disk, user-assigned managed identity, and no inbound SSH rule. Operations use Azure Run Command.
- Temporary VM public IP for outbound bootstrap downloads only. The VM NIC is associated with an NSG whose inbound policy denies all; review this cost/exposure before deployment.
- Scoped custom snapshot-management role for the worker identity plus Blob Data Contributor on the lab destination.

## Guardrails for generated IaC

- Use unique, parameterized resource names and an explicit lab-only naming prefix.
- Do not reference, mutate, or delete the existing accounts in the parent README.
- Do not place credentials, SAS tokens, private IP assumptions, or subscription-specific identifiers in source control.
- Both storage accounts disable public network access and shared-key authorization. The source is reached through a private endpoint and AZNFS TLS mount; the destination uses Blob RBAC. Validate the snapshot role on the live integration test.
- Surface estimated lab duration/cost and require a deliberate resource-group teardown confirmation.
- Do not enable long WORM retention in a disposable lab until a deletion/retention process has been agreed.

## Planned validation

Run `terraform fmt`, `terraform init -backend=false`, `terraform validate`, and a security scan first. A local state file is used for this disposable lab and must remain outside source control. Review a plan, deploy only after explicit risk confirmation, run backup and restore tests, capture results outside the target data path, then review the resource-group destroy plan before teardown.
