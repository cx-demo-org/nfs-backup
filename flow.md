# Manual Azure Files NFS Snapshot Backup Flow

This is a **manual, command-by-command procedure** for a Linux backup worker. It does not invoke the lab automation scripts. Replace every `<placeholder>` with values for the environment. Do not paste subscription details, tokens, keys, or customer identifiers into a committed copy of this guide.

The procedure creates an Azure Files NFS share snapshot, reads the snapshot through the mounted NFS `.snapshots` view, archives it locally, uploads the archive to a separate HNS-enabled Blob account, then demonstrates a restore. Azure does not copy an entire NFS share snapshot object into Blob; this flow copies the snapshot's files into a tar archive.

## Values used in the commands

Have these values available from the customer's approved configuration:

- Subscription ID, tenant, resource group, source storage account and NFS share.
- Worker user-assigned managed identity client ID.
- Destination HNS storage account and private container.
- Linux NFS mount point, staging-disk mount point, and restore-share mount point.

Example variable names are used below. Set them in the relevant shell before continuing. Use customer-selected values; these are not defaults to deploy blindly.

### Linux shell values

```bash
export SUBSCRIPTION_ID='<subscription-id>'
export RESOURCE_GROUP='<resource-group>'
export SOURCE_ACCOUNT='<source-storage-account>'
export SOURCE_SHARE='<source-nfs-share>'
export RESTORE_SHARE='<empty-restore-nfs-share>'
export DESTINATION_ACCOUNT='<hns-destination-storage-account>'
export BLOB_CONTAINER='<private-container>'
export WORKER_CLIENT_ID='<worker-managed-identity-client-id>'
export SOURCE_MOUNT='/mnt/nfs-source'
export RESTORE_MOUNT='/mnt/nfs-restore'
export STAGE_MOUNT='/mnt/nfs-stage'
export RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
export RUN_DIR="$STAGE_MOUNT/recovery-points/$RUN_ID"
mkdir -p "$RUN_DIR"
```

Keep the run ID unique. Do not reuse a recovery-point folder that already contains an archive.

## 1. Prepare local staging storage

Inspect the worker's block devices and filesystems before mounting. Do not format a disk unless you have verified it is the dedicated, disposable, empty staging disk; formatting destroys existing contents.

```bash
lsblk -f
sudo mkdir -p "$STAGE_MOUNT"
```

If the approved staging disk already has a filesystem, mount that filesystem. Example only—the device and filesystem UUID must be verified for the worker:

```bash
sudo mount /dev/disk/azure/scsi1/lun0 "$STAGE_MOUNT"
df -h "$STAGE_MOUNT"
```

Ensure the staging disk has enough free space for the archive plus working headroom. This procedure stages a full archive locally; it is not incremental.

## 2. Mount the source NFS share

The worker needs private network connectivity to the Azure Files NFS endpoint. NFS uses network-level access rather than per-user Entra authentication. For TLS in transit, install/use Microsoft's AZNFS mount helper.

```bash
sudo mkdir -p "$SOURCE_MOUNT"
sudo mount -t aznfs \
  "${SOURCE_ACCOUNT}.file.core.windows.net:/${SOURCE_ACCOUNT}/${SOURCE_SHARE}" \
  "$SOURCE_MOUNT" \
  -o vers=4,minorversion=1,sec=sys,nconnect=4
findmnt "$SOURCE_MOUNT"
```

Mount the share at least once before creating snapshots. Azure Files exposes snapshots through a virtual, read-only `.snapshots` view beneath this mount. Mounting is worker setup; it is not itself the snapshot or backup operation.

## 3. Authenticate to Azure and create the snapshot

The snapshot is created through the Azure management plane, not by creating a directory in NFS. Use the worker's user-assigned managed identity and a customer-approved least-privilege role that permits snapshot management on the configured source account.

In PowerShell on the Linux worker:

```powershell
$ErrorActionPreference = 'Stop'
$subscriptionId = '<subscription-id>'
$resourceGroup = '<resource-group>'
$sourceAccount = '<source-storage-account>'
$sourceShare = '<source-nfs-share>'
$workerClientId = '<worker-managed-identity-client-id>'

Import-Module Az.Accounts
Import-Module Az.Storage
Connect-AzAccount -Identity -AccountId $workerClientId
Set-AzContext -SubscriptionId $subscriptionId

$snapshot = New-AzRmStorageShare `
  -ResourceGroupName $resourceGroup `
  -StorageAccountName $sourceAccount `
  -Name $sourceShare `
  -Snapshot `
  -ErrorAction Stop
$snapshotTime = ([DateTime]$snapshot.SnapshotTime).ToUniversalTime().ToString('o')
$snapshotTime
```

Record the returned UTC `SnapshotTime`. It identifies the point-in-time snapshot to read. If the cmdlet fails, stop; do not assume a snapshot was created.

## 4. Locate and inspect that snapshot

In Bash, set the timestamp to the exact value returned by PowerShell. The classic Azure Files NFS snapshot view name is derived from that timestamp:

```bash
SNAPSHOT_TIME='<UTC SnapshotTime returned above>'
SNAPSHOT_NAME="$(date -u -d "$SNAPSHOT_TIME" +%Y%m%d%H%M%S)_snapshot"
SNAPSHOT_PATH="$SOURCE_MOUNT/.snapshots/$SNAPSHOT_NAME"

# Wait briefly for the read-only virtual view to appear, then fail if it is not visible.
for attempt in $(seq 1 36); do
  if [[ -d "$SNAPSHOT_PATH" ]]; then break; fi
  sleep 5
done
test -d "$SNAPSHOT_PATH"
ls -la "$SNAPSHOT_PATH"
```

Read from `SNAPSHOT_PATH`, not from the live share root. The `.snapshots` entry is provided by Azure Files; it is not a user-created folder.

## 5. Build a manifest and POSIX archive

The manifest records paths, file types, sizes, SHA-256 per-file hashes, numeric UID/GID, POSIX mode bits, modification times, symlink targets, and hardlink relationships. The manifest tool is provided as a standalone Python file in this repository; copy it to the worker or install it at `/opt/nfs-backup/manifest.py` before using these commands.

```bash
python3 /opt/nfs-backup/manifest.py create \
  --root "$SNAPSHOT_PATH" \
  --output "$RUN_DIR/manifest.json"

tar --format=pax --create \
  --file "$RUN_DIR/backup.tar" \
  --directory "$SNAPSHOT_PATH" \
  --numeric-owner --sparse .

ARCHIVE_SHA256="$(sha256sum "$RUN_DIR/backup.tar" | awk '{print $1}')"
ARCHIVE_BYTES="$(stat -c '%s' "$RUN_DIR/backup.tar")"
printf 'ARCHIVE_BYTES=%s\nARCHIVE_SHA256=%s\n' "$ARCHIVE_BYTES" "$ARCHIVE_SHA256"
```

`pax` format stores extended metadata such as high-resolution timestamps. `--numeric-owner` records numeric IDs instead of local username strings. A tar archive can carry POSIX ownership, permissions, timestamps, and links; Blob objects themselves are not a POSIX filesystem.

Write a run metadata file beside the archive. The values below are shell variables established earlier:

```bash
jq -n \
  --arg run_id "$RUN_ID" \
  --arg snapshot_time "$SNAPSHOT_TIME" \
  --arg snapshot_name "$SNAPSHOT_NAME" \
  --arg source_account "$SOURCE_ACCOUNT" \
  --arg source_share "$SOURCE_SHARE" \
  --arg archive_sha256 "$ARCHIVE_SHA256" \
  --arg archive_bytes "$ARCHIVE_BYTES" \
  '{schema_version:1,run_id:$run_id,snapshot:{name:$snapshot_name,created_at_utc:$snapshot_time},source:{storage_account:$source_account,share:$source_share},archive:{file:"backup.tar",bytes:($archive_bytes|tonumber),sha256:$archive_sha256},created_at_utc:(now|todate)}' \
  > "$RUN_DIR/run.json"
```

## 6. Upload archive and metadata to private Blob

The worker identity needs Blob data-plane write permissions on the destination container/account. Authenticate AzCopy with that identity; do not use account keys or long-lived SAS tokens.

```bash
azcopy login --identity --identity-client-id "$WORKER_CLIENT_ID"
REMOTE_DIR="https://${DESTINATION_ACCOUNT}.dfs.core.windows.net/${BLOB_CONTAINER}/recovery-points/${RUN_ID}"

for artifact in backup.tar manifest.json run.json; do
  azcopy copy "$RUN_DIR/$artifact" "$REMOTE_DIR/$artifact" \
    --from-to=LocalBlobFS --overwrite=false --put-md5
done
```

After all three uploads return successfully, publish a completion marker:

```bash
printf '{"run_id":"%s","status":"uploaded","archive_sha256":"%s"}\n' \
  "$RUN_ID" "$ARCHIVE_SHA256" > "$RUN_DIR/_SUCCESS.json"
azcopy copy "$RUN_DIR/_SUCCESS.json" "$REMOTE_DIR/_SUCCESS.json" \
  --from-to=LocalBlobFS --overwrite=false --put-md5
```

The marker means the upload commands completed; it does not prove recoverability. Restore verification below is the test of the recovery point. The container path includes the unique run ID so one backup run cannot overwrite another's files.

## 7. Download, restore, and verify

Mount the separate, empty restore NFS share in the worker's NFS context:

```bash
sudo mkdir -p "$RESTORE_MOUNT"
sudo mount -t aznfs \
  "${SOURCE_ACCOUNT}.file.core.windows.net:/${SOURCE_ACCOUNT}/${RESTORE_SHARE}" \
  "$RESTORE_MOUNT" \
  -o vers=4,minorversion=1,sec=sys,nconnect=4
findmnt "$RESTORE_MOUNT"
```

Create a local restore workspace, then download the recovery-point artifacts:

```bash
RESTORE_DIR="$STAGE_MOUNT/restore-test/$RUN_ID"
mkdir -p "$RESTORE_DIR"

for artifact in _SUCCESS.json backup.tar manifest.json run.json; do
  azcopy copy "$REMOTE_DIR/$artifact" "$RESTORE_DIR/$artifact" --from-to=BlobFSLocal
done
```

Verify the archive's SHA-256 against the metadata before extracting:

```bash
EXPECTED_SHA256="$(jq -r '.archive.sha256' "$RESTORE_DIR/run.json")"
ACTUAL_SHA256="$(sha256sum "$RESTORE_DIR/backup.tar" | awk '{print $1}')"
test "$EXPECTED_SHA256" = "$ACTUAL_SHA256"
```

Extract into the empty restore share and compare its manifest to the snapshot manifest:

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

Success is reported as `MANIFEST_COMPARE=PASS`; investigate any missing/extra paths, content hashes, or metadata differences rather than treating an upload marker as proof of a good backup.

## Important limits

- This example applies to classic `Microsoft.Storage` Azure Files NFS shares; validate support before adapting it to another share resource provider.
- The whole NFS snapshot cannot be moved to Blob as a snapshot object. The worker reads files and packages them into an archive.
- The workflow makes a full archive each run, not an incremental backup. The staging disk must fit the archive with headroom.
- Azure Files snapshots remain in the source account. The Blob archive is the separate copy. A 30-day Blob lifecycle rule is not WORM protection.
- For active databases, coordinate application quiescence if a crash-consistent point-in-time copy is insufficient.
