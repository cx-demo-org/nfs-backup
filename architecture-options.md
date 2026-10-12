# Architecture options and questions

Status: a 10-GiB snapshot/archive/restore lab test passed. The versioned project deliberately omits subscription and tenant identifiers; supply these via local Terraform configuration. Design choices: fresh isolated source and destination; Southeast Asia example; 10-GiB functional test; daily backup is a future target; 30-day Blob lifecycle; restore contents/paths, POSIX mode/timestamps, UID/GID, symlinks, and hardlinks. Use a disposable disk-backed Linux VM. WORM is not enabled.

## Candidate pattern

**Azure Files NFS snapshot → Linux NFS mount worker → POSIX-aware archive → HNS-enabled Blob container with retention → restore test.** The worker mounts NFS through AZNFS/TLS, creates a snapshot through the Azure management plane, reads the snapshot from `.snapshots`, archives it on local staging disk, and uploads that archive with AzCopy and managed identity. The source snapshot remains associated with the source share/account; the Blob copy is the separate long-term recovery boundary.

## Choices to settle

| Topic | Initial option | Trade-off / question |
|---|---|---|
| Scope | New disposable lab resource group | Keep all test resources isolated from the existing source and target accounts? Recommended: yes. |
| IaC | Terraform | Selected for this lab; use a disposable, isolated state and never point it at existing storage. |
| Runner | Disposable disk-backed Linux VM | Selected for the representative test. A temporary public IP is present for outbound package/bootstrap access; inbound is denied by NSG and operations use Azure Run Command. |
| NFS connectivity | Dedicated VNet, private endpoint, private DNS, and AZNFS TLS | NFS uses network-level access rather than user authentication; the worker connects from the dedicated VNet. |
| Source | Premium FileStorage account with a classic NFS share | Confirm region/SKU availability and that the intended source resource provider supports snapshots and AzCopy. |
| Destination | Separate StorageV2 account with HNS and a dedicated container | Confirm immutability policy mode/retention and how operational deletion/restore should work. |
| Snapshot lifecycle | Create a source share snapshot per run; export that snapshot; delete only after successful export/verification and policy checks | Snapshot retention is not a substitute for the off-account copy. Define failure cleanup and snapshot quota/retention. |
| Copy format | Timestamped full tree per recovery point | Simple restore and audit; likely repeats unchanged bytes. Measure cost before choosing production cadence. |
| Fidelity | All requested attributes are test requirements | Store a tar archive with numeric UID/GID, POSIX modes, timestamps, symlinks, and hardlinks; compare a source-snapshot manifest to a restored-share manifest. |
| Scheduling | Manual execution in lab; daily is the intended production cadence | Measure backup duration and cost before implementing scheduled automation. |

## Questions for the next iteration

1. What maximum acceptable restore time (RTO) should the 28 GB test aim to demonstrate?
2. Is 30-day retention a lifecycle deletion requirement, a WORM requirement, or both? Current lab plan uses lifecycle deletion only, with WORM off.
3. What daily change-rate estimate should be measured to compare full recovery-point exports with a future incremental/archive design?

## Known caveats to validate

- A 30-day lifecycle policy does not provide WORM protection; WORM needs a separate design and can prevent immediate teardown.
- Snapshot creation and restore must be verified through the Azure Files management plane and mounted NFS snapshot view. NFS snapshots should be created only after the share has been mounted at least once.
- The archive is a full copy per recovery point; staging disk and storage costs scale with the dataset and run cadence. The 128-GiB lab disk does not support a 1-TiB workload.
