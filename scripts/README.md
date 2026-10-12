# Backup lab operator workflow

The implementation uses the Azure Files NFS share snapshot as the point-in-time source, reads the read-only snapshot view through the mounted NFS share's `.snapshots` directory, and packages the tree as a POSIX-aware tar archive on the attached staging disk. The archive and manifests are copied to a separate HNS Blob account using the worker's managed identity.

This avoids Azure Files data-plane SAS/account keys for NFS reads: NFS is accessed through network-restricted NFSv4.1 with AZNFS TLS; snapshot creation uses the Azure management plane. The destination upload uses Blob RBAC. Runtime identity/role support remains a live integration-test gate.

## Scripts

- `seed-test-data.sh` seeds the source share with nested content, empty files, duplicate leaf names, a symlink, a hardlink, non-default UID/GID/mode, and a real 28-GiB payload by default. It refuses to modify a non-empty source share.
- `backup.sh` creates a new NFS share snapshot, archives that snapshot using numeric owner/group, modes, timestamps, symlink and hardlink support, then uploads the archive and manifests under a unique recovery-point prefix. It never overwrites a prior point and writes `_SUCCESS.json` only after all artifacts upload.
- `restore-test.sh <recovery-point-id>` downloads the archive, validates its SHA-256, extracts to the separate empty NFS restore share, and compares content and POSIX manifests.
- `manifest.py` uses only Python standard-library modules.
- `mount-nfs.sh`, `prepare-stage.sh`, and `create-snapshot.ps1` are helpers.
- `deploy-lab.ps1` validates and previews a create-only Terraform plan, then requires the exact typed confirmation before applying that saved plan.
- `invoke-lab-operation.ps1` invokes seed/backup/restore with Azure Run Command; it does not open SSH.
- `destroy-lab.ps1` creates and displays a destroy-only Terraform plan, then requires the scope-specific phrase `DESTROY <lab-resource-group> IN <subscription-id>` before applying that saved plan.

## Run the lab operations

After deployment, wait for cloud-init to install AZNFS, PowerShell Az modules, and AzCopy. The scripts are installed at `/opt/nfs-backup` on the VM. From PowerShell, use `invoke-lab-operation.ps1 -Operation seed`, then `-Operation backup`; use `-Operation restore -RecoveryPointId <id>` with the recovery point ID printed by backup. Each invocation specifies the planned subscription ID. The equivalent Azure CLI commands are:

```bash
az vm run-command invoke --subscription <subscription-id> --resource-group <lab-resource-group> --name <worker-vm> --command-id RunShellScript --scripts "bash /opt/nfs-backup/seed-test-data.sh"
az vm run-command invoke --subscription <subscription-id> --resource-group <lab-resource-group> --name <worker-vm> --command-id RunShellScript --scripts "bash /opt/nfs-backup/backup.sh"
az vm run-command invoke --subscription <subscription-id> --resource-group <lab-resource-group> --name <worker-vm> --command-id RunShellScript --scripts "bash /opt/nfs-backup/restore-test.sh <recovery-point-id>"
```

Run Command opens no SSH ingress. It requires operator permissions for VM Run Command. The worker identity is assigned a dedicated snapshot-management role scoped to the lab source account plus Blob Data Contributor on the disposable destination account. Never pass SAS tokens or storage keys. The destroy helper is not to be run until the recovery-point results are saved elsewhere and the Terraform plan has been reviewed.

## Current test boundaries

- Source share seed target: 28 GiB; share quota: 128 GiB; stage disk: 128 GiB.
- Expected cadence: one manual test run; daily is a design target only.
- Blob lifecycle: 30 days; this is not WORM/immutability.
- Archive strategy: one complete archive per run, not incremental. A 1-TiB share does not fit the current stage disk and is not represented by this lab.
- POSIX owner/group, modes, timestamps, symlinks, and hardlinks are expected to pass end-to-end; record any mismatches instead of weakening the manifest comparison.

Do not deploy until the approved subscription, cost, access, and destruction risks have been reviewed and explicitly confirmed. Do not destroy until the exact Terraform plan has been reviewed; only the isolated lab resource group may be targeted.

## Deployment and teardown gates

The deployment helper requires the expected subscription and lab resource group as local parameters and refuses to apply if the plan includes anything except creates. After reviewing the plan and costs, the operator must type the scope-specific confirmation phrase displayed by the helper. Teardown requires its own destroy-only plan and scope-specific confirmation; it permanently removes test data, snapshots, and backups.
