# Azure Files NFS Snapshot Backup Flow

This guide describes the manual equivalent of the lab's backup and restore scripts. Run the Linux/NFS and AzCopy commands on the **backup worker VM** from a privileged shell. Use a customer-approved identity and scope for any customer deployment; the values below are placeholders, not live account details.

## What happens

1. A Linux worker mounts the configured Azure Files NFS share over the approved network.
2. The worker asks Azure's management plane to create a point-in-time share snapshot.
3. Azure exposes that read-only snapshot through the mounted share's virtual `.snapshots` directory.
4. The worker reads the snapshot, creates a manifest, and packages the files as a POSIX pax tar archive on local staging storage.
5. AzCopy uploads the archive and metadata to a unique path in a separate HNS-enabled Blob account.
6. For a restore test, the worker downloads the archive, validates its digest, extracts it to a separate NFS share, and compares manifests.

The snapshot itself stays with the source Azure Files share. It is not moved to Blob. Blob receives a separate archive copy. Since the archive is staged locally, the worker needs enough free disk for the archive plus working room.

## 0. Set local values

Replace all angle-bracket placeholders with values for the environment. Do not commit credentials, tokens, private keys, or customer identifiers in this file. The examples assume the lab paths; customer paths may differ.

On the worker, load its root-owned lab configuration if available:

```bash
sudo -i
source /etc/nfs-backup/lab.env
```

The file defines values such as `SOURCE_ACCOUNT`, `SOURCE_SHARE`, `DESTINATION_ACCOUNT`, `BLOB_CONTAINER`, `SOURCE_MOUNT`, `RESTORE_MOUNT`, `STAGE_MOUNT`, `WORKER_CLIENT_ID`, and `SUBSCRIPTION_ID`.

## 1. Prepare the staging disk and mount the source share

Prepare and mount the dedicated staging disk. The helper checks for an existing filesystem before formatting, mounts it at the configured staging path, and restricts access to root:

```bash
/opt/nfs-backup/prepare-stage.sh
df -h "$STAGE_MOUNT"
```

Mount the source NFS share through AZNFS. This is worker/environment setup; if already mounted in this worker's mount namespace, the helper reuses the mount:

```bash
/opt/nfs-backup/mount-nfs.sh source
findmnt "$SOURCE_MOUNT"
```

The equivalent classic Azure Files NFS mount form is:

```bash
sudo mkdir -p /mnt/nfs-source
sudo mount -t aznfs \
  <storage-account>.file.core.windows.net:/<storage-account>/<share-name> \
  /mnt/nfs-source \
  -o vers=4,minorversion=1,sec=sys,nconnect=4
```

AZNFS provides TLS in transit. NFS access is network-scoped; it does not use a per-user Entra login. The worker needs connectivity to the configured private endpoint/VNet or another customer-approved network path. A mount on an application VM or AKS pod is not automatically shared with a separate backup worker.

## 2. Create the Azure Files share snapshot

Snapshots are created using the Azure management plane, not by creating a directory in NFS. For this lab, `create-snapshot.ps1` authenticates as the VM's user-assigned managed identity and calls `New-AzRmStorageShare`:

```powershell
Connect-AzAccount -Identity -AccountId $env:WORKER_CLIENT_ID
Set-AzContext -SubscriptionId $env:SUBSCRIPTION_ID

$snapshot = New-AzRmStorageShare `
  -ResourceGroupName $env:RESOURCE_GROUP `
  -StorageAccountName $env:SOURCE_ACCOUNT `
  -Name $env:SOURCE_SHARE `
  -Snapshot
$snapshot.SnapshotTime
```

In a customer environment, grant the worker identity only the approved control-plane permission to create/list snapshots for the configured source account. Review the role definition with the customer's Azure administrator; the lab role is not automatically the right production role.

## 3. Read the read-only snapshot view

Azure exposes the snapshot as a virtual, read-only directory beneath the mounted share. It is not a normal folder that the worker creates. Convert the returned UTC snapshot time to the view name used by this lab, then inspect it:

```bash
SNAPSHOT_TIME='<timestamp returned by Azure, in UTC>'
SNAPSHOT_NAME="$(date -u -d "$SNAPSHOT_TIME" +%Y%m%d%H%M%S)_snapshot"
SNAPSHOT_PATH="$SOURCE_MOUNT/.snapshots/$SNAPSHOT_NAME"
ls -la "$SNAPSHOT_PATH"
```

Example shape only: `.snapshots/YYYYMMDDhhmmss_snapshot/`. Use the actual snapshot time returned by Azure, not a copied example. Read data from this path rather than the live share root so writes made after snapshot time are not included.

## 4. Create the manifest and archive on staging storage

Create a unique recovery-point folder. Never reuse a run ID that already has an archive:

```bash
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="$STAGE_MOUNT/recovery-points/$RUN_ID"
mkdir -p "$RUN_DIR"
```

Create the manifest and archive:

```bash
python3 /opt/nfs-backup/manifest.py create \
  --root "$SNAPSHOT_PATH" \
  --output "$RUN_DIR/manifest.json"

tar --format=pax --create \
  --file "$RUN_DIR/backup.tar" \
  --directory "$SNAPSHOT_PATH" \
  --numeric-owner --sparse .
```

The manifest records relative paths, file types, sizes, SHA-256 content hashes, numeric UID/GID, POSIX mode bits, timestamps, symlink targets, and hardlink relationships. The pax tar carries the tree for restore; Blob itself is object storage and does not become an NFS filesystem.

Record the archive size and whole-archive SHA-256:

```bash
ARCHIVE_SHA256="$(sha256sum "$RUN_DIR/backup.tar" | awk '{print $1}')"
ARCHIVE_BYTES="$(stat -c '%s' "$RUN_DIR/backup.tar")"
printf 'bytes=%s sha256=%s\n' "$ARCHIVE_BYTES" "$ARCHIVE_SHA256"
```

The automated flow also writes `run.json` containing run ID, source share, snapshot time/name, archive size, and SHA-256. Keep the manifest and run metadata beside the archive.

## 5. Upload the recovery point to Blob

Authenticate AzCopy with the worker's managed identity, then upload to a unique recovery-point prefix on the destination DFS endpoint:

```bash
azcopy login --identity --identity-client-id "$WORKER_CLIENT_ID"
REMOTE_DIR="https://${DESTINATION_ACCOUNT}.dfs.core.windows.net/${BLOB_CONTAINER}/recovery-points/${RUN_ID}"

for artifact in backup.tar manifest.json run.json; do
  azcopy copy "$RUN_DIR/$artifact" "$REMOTE_DIR/$artifact" \
    --from-to=LocalBlobFS --overwrite=false --put-md5
done
```

Only after all three uploads succeed, write and upload a completion marker:

```bash
printf '{"run_id":"%s","status":"uploaded","archive_sha256":"%s"}\n' \
  "$RUN_ID" "$ARCHIVE_SHA256" > "$RUN_DIR/_SUCCESS.json"
azcopy copy "$RUN_DIR/_SUCCESS.json" "$REMOTE_DIR/_SUCCESS.json" \
  --from-to=LocalBlobFS --overwrite=false --put-md5
```

`_SUCCESS.json` means the upload commands completed. It does **not** prove the archive is restorable; restore verification is a separate test. Avoid keys and SAS tokens; destination writes use Blob RBAC for the worker identity.

## 6. Download, restore, and compare

Mount the separate, empty restore NFS share and download the artifacts for the selected run:

```bash
/opt/nfs-backup/mount-nfs.sh restore
RESTORE_DIR="$STAGE_MOUNT/restore-test/$RUN_ID"
mkdir -p "$RESTORE_DIR"

azcopy copy "$REMOTE_DIR/_SUCCESS.json" "$RESTORE_DIR/_SUCCESS.json" --from-to=BlobFSLocal
azcopy copy "$REMOTE_DIR/backup.tar" "$RESTORE_DIR/backup.tar" --from-to=BlobFSLocal
azcopy copy "$REMOTE_DIR/manifest.json" "$RESTORE_DIR/manifest.json" --from-to=BlobFSLocal
azcopy copy "$REMOTE_DIR/run.json" "$RESTORE_DIR/run.json" --from-to=BlobFSLocal
```

Verify the downloaded archive before extracting it:

```bash
EXPECTED_SHA256="$(jq -r '.archive.sha256' "$RESTORE_DIR/run.json")"
ACTUAL_SHA256="$(sha256sum "$RESTORE_DIR/backup.tar" | awk '{print $1}')"
test "$EXPECTED_SHA256" = "$ACTUAL_SHA256"
```

Extract to the empty restore share and compare its manifest with the snapshot manifest:

```bash
sudo tar --extract \
  --file "$RESTORE_DIR/backup.tar" \
  --directory "$RESTORE_MOUNT" \
  --numeric-owner --same-owner --same-permissions --sparse

python3 /opt/nfs-backup/manifest.py create \
  --root "$RESTORE_MOUNT" \
  --output "$RESTORE_DIR/restored-manifest.json"
python3 /opt/nfs-backup/manifest.py compare \
  --expected "$RESTORE_DIR/manifest.json" \
  --actual "$RESTORE_DIR/restored-manifest.json"
```

A passing result prints `MANIFEST_COMPARE=PASS`. This checks file content and the metadata fields recorded by the manifest; it is the restore test, not merely a successful upload.

## Scope and caveats

- This process is for the lab's **classic `Microsoft.Storage` Azure Files NFS share**. Confirm the resource provider, mount behavior, and snapshot support before adapting it to another share type.
- The 10-GiB test was successful. The archive process reads the snapshot to build a manifest and again to build the tar, so large or metadata-heavy trees can take longer than expected.
- This is a full archive for each recovery point, not incremental backup. Stage-disk capacity must exceed the archive size with headroom.
- The tar contains POSIX attributes, but restore fidelity depends on the destination NFS filesystem and privileges; verify with the manifest and application-level checks.
- Share snapshots remain in the source account. The Blob copy is separate. Blob lifecycle expiration is not WORM protection.
- Do not delete source snapshots or local evidence until the corresponding Blob archive has been downloaded and successfully restored in a test.
