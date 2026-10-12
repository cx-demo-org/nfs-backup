# Azure Files NFS Snapshot-to-Blob Backup Lab

> **Status (2026-10-12): resources deployed; a 10-GiB synthetic backup-and-restore test passed.** The Azure Files NFS snapshot was archived to private Blob storage, downloaded, restored to the restore share, and its manifest matched. This is a disposable lab, not a production backup service.

## Purpose

This lab tests a snapshot-based long-term backup pattern for **Azure Files NFS** using Azure Files share snapshots as point-in-time capture and a separate HNS-enabled Blob account for the off-share recovery copy. The implementation and operations are documented here so that the setup can be reviewed, tested, and later reproduced or removed.

Azure Files share snapshots are the capture point; they are not an independent copy outside the source storage account. The Blob recovery-point archive is the separate copy. Azure Backup does not currently support NFS shares, so this lab exercises snapshot lifecycle and export/restore directly. See [Microsoft Learn: Use Azure Files Share Snapshots](https://learn.microsoft.com/en-us/azure/storage/files/storage-snapshots-files?tabs=portal).

## Current deployment

| Setting | Value |
|---|---|
| Subscription | A customer-selected subscription supplied through local configuration |
| Region | Southeast Asia (`southeastasia`) |
| Resource group | A disposable, customer-selected lab resource group |
| IaC | Terraform with local state in `infra/terraform.tfstate` (do not commit state or plan files) |
| Source storage account | Premium `FileStorage`, classic NFS shares; name is supplied in local configuration |
| Source test share | `nfsbackup-lab` — 128-GiB provisioned quota |
| Restore test share | `nfsbackup-restore` — 128-GiB provisioned quota |
| Destination storage account | HNS-enabled `StorageV2`, LRS; name is supplied in local configuration |
| Destination container | `nfs-backup-points` — private |
| Backup worker | Ubuntu 24.04, `Standard_D2s_v5` (name held in local configuration) |
| Staging disk | 128-GiB Standard SSD (name held in local configuration) |
| Current source test data | Approximately 10 GiB (10,737,418,240 bytes after resizing the synthetic filler) |
| 10-GiB recovery point | A run-specific ID and snapshot timestamp were recorded during testing; specific values remain in local operational output |
| Uploaded archive | 10,737,448,960 bytes; digest matched after download (digest omitted from this guide) |
| Restore verification | `MANIFEST_COMPARE=PASS`; 12 entries, 10,737,418,242 manifest file bytes |
| Destination retention | Lifecycle deletion after 30 days; **not** WORM/immutability |

The lab was deployed additively. It does not reuse or modify the existing source/target accounts named in the parent [SingtelNFS README](../README.md).

## Environment prerequisite: worker access to the NFS share

The backup worker needs network access to the Azure Files NFS endpoint and a mounted NFSv4.1 view so it can read the share's `.snapshots` directory. In this lab, AZNFS provides TLS and the private endpoint/VNet provides network reachability. NFS uses network-level trust rather than per-user authentication. Azure Files exposes `.snapshots` as a virtual, read-only NFS view; it is not a normal directory that the backup script creates.

This mount is **worker/environment setup, not the recurring backup operation**. The lab script calls an idempotent mount helper: if the source is already mounted in that worker's mount namespace, it reuses it; otherwise it establishes the mount. Azure requires that the share has been mounted before snapshots can be browsed. If a production backup worker is separate from the application VM or AKS pod, it needs its own NFS mount/access in its own host or pod context; an application's existing mount is not automatically shared with another VM or pod.

## What each backup run does

1. Create a **classic Azure Files share snapshot** through the Azure management plane using the worker's user-assigned managed identity and a lab-scoped custom role. Azure creates the point-in-time snapshot; the worker does not create snapshot data by making a directory.
2. Use the snapshot timestamp to locate its new read-only virtual view under the worker's mounted source share `.snapshots` path, then read the snapshot contents from there.
3. Generate a source manifest, then create a POSIX pax-format tar archive on the attached staging disk. The archive uses numeric UID/GID and records POSIX modes, timestamps, symlinks, and hardlinks.
4. Upload `backup.tar`, `manifest.json`, `run.json`, and then `_SUCCESS.json` to `nfs-backup-points/recovery-points/<run-id>/` using AzCopy and the worker's managed identity. Each run uses a unique prefix; the script does not overwrite an existing archive path.
5. A separate restore operation downloads the archive, checks its SHA-256 against `run.json`, extracts into the empty restore NFS share, and compares manifests.

There is no direct Azure Files NFS-to-Blob server-side copy in this workflow. The local staging disk is necessary for this archive-based implementation. The target is a Blob archive, **not** a POSIX filesystem; metadata is recoverable by extracting the archive to a compatible filesystem, subject to the end-to-end test.

## Data seeded for the test

The seed script creates a synthetic tree containing nested directories, duplicate leaf names in distinct paths, an empty file, a large non-sparse payload, a symlink, a hardlink, and a file/directory with non-default UID/GID/mode. It refuses to seed if the source share already contains user files. The seed data is disposable and contains no production content.

## Resource and security design

- Source and destination storage accounts have public network access disabled and shared-key access disabled. Destination HNS is enabled; the container has no public access.
- Private DNS zones and private endpoints are created for Azure Files `file`, destination Blob, and destination DFS endpoints.
- Worker has a user-assigned managed identity. Blob write access is granted through `Storage Blob Data Contributor`; snapshot management uses a custom role scoped to the lab source account.
- VM has no inbound SSH rule; an NSG deny-all inbound rule is associated with its NIC. Azure Run Command is used for administration. A temporary public IP is attached for outbound bootstrap/download traffic, so it still has a public address even though inbound is denied.
- Storage uses TLS 1.2 for REST endpoints. NFS in-transit encryption is provided by AZNFS on the worker.
- The Blob lifecycle rule deletes recovery-point blobs after 30 days. It is lifecycle retention, **not** immutable/WORM retention or a protection against privileged deletion.
- Terraform state, plans, and local tfvars are not for source control. SSH public key is supplied via `TF_VAR_admin_ssh_public_key`; no private SSH key, SAS, or storage key is included in the Terraform inputs.

## Running the lab

From an authorized PowerShell terminal, the helper supports the lab operations through Azure Run Command:

- Seed: `./scripts/invoke-lab-operation.ps1 -Operation seed -SubscriptionId <id> -ResourceGroupName <lab-rg> -VmName <worker>`
- Backup: `./scripts/invoke-lab-operation.ps1 -Operation backup -SubscriptionId <id> -ResourceGroupName <lab-rg> -VmName <worker>`
- Restore: `./scripts/invoke-lab-operation.ps1 -Operation restore -RecoveryPointId <run-id> -SubscriptionId <id> -ResourceGroupName <lab-rg> -VmName <worker>`

The backup command prints a `RUN_ID` on successful completion. Record that value for the restore invocation. The worker can also be invoked with `az vm run-command invoke`; examples and caveats are in [scripts/README.md](scripts/README.md).

Only use the deployment helper after a create-only Terraform plan and explicit risk approval. To remove the lab, use [scripts/destroy-lab.ps1](scripts/destroy-lab.ps1); it displays a destroy-only plan and requires a typed confirmation. Destroying the resource group permanently deletes all source/restore data, NFS snapshots, and Blob recovery points.

## Test status and evidence

| Check | Status |
|---|---|
| Terraform validation | Passed before deployment; the initial plan was 33 creates and no changes/deletions. VM creation first failed because encryption-at-host was not enabled for the subscription; that optional flag was disabled and the remaining three resources were created successfully. |
| Synthetic source seed | **Passed** for an initial 28-GiB seed and subsequent 10-GiB test resize. |
| Azure Files NFS share snapshot | **Created and confirmed** through the Azure Storage management API; exact snapshot timestamps are omitted from this guide. |
| 10-GiB snapshot archive upload to Blob | **Passed**; AzCopy reported all recovery-point artifacts uploaded. Run ID is kept in local operational output. |
| Downloaded archive integrity | **Passed**; SHA-256 matched the run metadata. |
| Restore to NFS and manifest comparison | **Passed**; 12 entries and all in-scope manifest fields matched on the restore share. |
| Checkov security scan | Not completed; package download failed due a network TLS handshake error. |
| Teardown | Not run. |

Azure CLI calls from the workstation cannot enumerate destination blobs because destination public network access is disabled. The recovery point was verified from the worker VM/private network by downloading, hashing, restoring, and comparing its manifest. The target account settings were confirmed as HNS enabled, public access disabled, shared-key auth disabled.

## Limitations and production decisions

- The latest test uses a 10-GiB mutable source tree. Earlier, larger synthetic content remains in older Azure Files snapshots; shrinking the live filler did not shrink those snapshots. The 128-GiB stage disk cannot support a 1-TiB export.
- Each recovery point is a complete archive. Daily 1-TiB archives for 30 days could create very large transfer and storage costs; this design is not incremental or deduplicated.
- Snapshot point-in-time consistency is provided by Azure Files, but application-level quiescence (for databases or active writes) is not implemented. Coordinate application consistency where required.
- Snapshot retention, retention cleanup on the source share, RPO/RTO, daily change rate, restore time, Blob immutability/WORM, cross-region protection, and operational alerting need a production design.
- Do not call the solution production-ready until the Blob archive is verified and restored to the NFS restore share with the agreed contents and POSIX metadata intact.

## Related documentation

- [Terraform resource layout and guardrails](infra/README.md)
- [Backup, restore, deploy, and destroy operations](scripts/README.md)
- [Functional and scale acceptance criteria](tests/README.md)
- [Azure Files Share Snapshots documentation](https://learn.microsoft.com/en-us/azure/storage/files/storage-snapshots-files?tabs=portal)
- [Azure Files NFS protocol documentation](https://learn.microsoft.com/en-us/azure/storage/files/files-nfs-protocol)
- [AzCopy transfer guidance for Azure Files](https://learn.microsoft.com/en-us/azure/storage/common/storage-use-azcopy-files)
