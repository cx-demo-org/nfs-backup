#!/usr/bin/env bash
# Create one Azure Files NFS snapshot recovery point, archive it locally, then upload it to private Blob storage.
# Run on the lab Linux VM, where the NFS mount, managed identity, and staging disk are available.
set -euo pipefail

# Load names, mount locations, identity, and storage configuration provisioned by cloud-init.
source /etc/nfs-backup/lab.env
# Ensure the attached disk is mounted and the live source share is mounted before snapshot access.
"$SCRIPT_DIR/prepare-stage.sh" >/dev/null
"$SCRIPT_DIR/mount-nfs.sh" source

# Make recovery points unique by default; allow an explicit run ID for controlled operations.
RUN_ID="${NFS_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
# Restrict path-derived IDs to safe characters and a bounded length.
if [[ ! "$RUN_ID" =~ ^[A-Za-z0-9T._-]{1,80}$ ]]; then
  echo "Invalid recovery-point identifier." >&2
  exit 2
fi
RUN_DIR="$STAGE_MOUNT/recovery-points/$RUN_ID"
mkdir -p "$RUN_DIR"
# Never silently reuse a recovery-point path or overwrite an earlier archive.
if [[ -e "$RUN_DIR/backup.tar" ]]; then
  echo "Recovery-point path already exists; refusing overwrite: $RUN_ID" >&2
  exit 1
fi

SNAPSHOTS_DIR="$SOURCE_MOUNT/.snapshots"
mkdir -p "$STAGE_MOUNT/tmp"
# Create the Azure Files share snapshot through the management plane; the helper prints its UTC timestamp.
SNAPSHOT_CREATED_AT=$(pwsh -NoLogo -NoProfile -NonInteractive -File "$SCRIPT_DIR/create-snapshot.ps1")
printf '%s\n' "$SNAPSHOT_CREATED_AT" > "$RUN_DIR/snapshot-command.txt"

# Azure Files NFS exposes a snapshot as YYYYMMDDhhmmss_snapshot under the mounted .snapshots directory.
snapshot_name="$(date -u -d "$SNAPSHOT_CREATED_AT" +%Y%m%d%H%M%S)_snapshot"
snapshot_path="$SNAPSHOTS_DIR/$snapshot_name"
# Allow time for the read-only snapshot view to appear after the management-plane request.
for _ in $(seq 1 36); do
  [[ -d "$snapshot_path" ]] && break
  sleep 5
done
if [[ ! -d "$snapshot_path" ]]; then
  echo "Snapshot was created through the management plane, but no new .snapshots directory appeared." >&2
  exit 1
fi
SNAPSHOT_NAME="$snapshot_name"

# Hash every regular file and capture path, POSIX IDs/mode/time, symlink targets, and hardlink relationships.
python3 "$SCRIPT_DIR/manifest.py" create --root "$snapshot_path" --output "$RUN_DIR/manifest.json"
# Use pax headers for precise timestamps and numeric ownership; archive contents, not the synthetic .snapshots wrapper.
tar --format=pax --create --file "$RUN_DIR/backup.tar" --directory "$snapshot_path" \
  --numeric-owner --sparse .
# Record a strong local archive digest and exact byte count for subsequent integrity checks.
ARCHIVE_SHA256=$(sha256sum "$RUN_DIR/backup.tar" | awk '{print $1}')
ARCHIVE_BYTES=$(stat -c '%s' "$RUN_DIR/backup.tar")

# Write portable run metadata; this records the source snapshot and archive digest, not credentials.
jq -n \
  --arg run_id "$RUN_ID" \
  --arg snapshot_name "$SNAPSHOT_NAME" \
  --arg snapshot_created_at_utc "$SNAPSHOT_CREATED_AT" \
  --arg source_account "$SOURCE_ACCOUNT" \
  --arg source_share "$SOURCE_SHARE" \
  --arg archive_sha256 "$ARCHIVE_SHA256" \
  --arg archive_bytes "$ARCHIVE_BYTES" \
  --arg created_at_utc "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{schema_version:1,run_id:$run_id,snapshot:{name:$snapshot_name,created_at_utc:$snapshot_created_at_utc},source:{storage_account:$source_account,share:$source_share},archive:{file:"backup.tar",bytes:($archive_bytes|tonumber),sha256:$archive_sha256},created_at_utc:$created_at_utc}' \
  > "$RUN_DIR/run.json"

# Authenticate AzCopy with the VM's user-assigned managed identity instead of keys or SAS tokens.
azcopy login --identity --identity-client-id "$WORKER_CLIENT_ID"
# Keep each point under an immutable-by-convention unique prefix in the separate HNS-enabled destination.
REMOTE_BASE="https://${DESTINATION_ACCOUNT}.dfs.core.windows.net/${BLOB_CONTAINER}/recovery-points/${RUN_ID}"
# Upload artifacts without overwrite. The success marker is deliberately written only after these uploads finish.
for artifact in backup.tar manifest.json run.json; do
  azcopy copy "$RUN_DIR/$artifact" "$REMOTE_BASE/$artifact" \
    --from-to=LocalBlobFS --overwrite=false --put-md5
 done
# This marker means upload commands returned successfully; restore verification is a separate operation.
printf '{"run_id":"%s","status":"uploaded","archive_sha256":"%s"}\n' "$RUN_ID" "$ARCHIVE_SHA256" > "$RUN_DIR/_SUCCESS.json"
azcopy copy "$RUN_DIR/_SUCCESS.json" "$REMOTE_BASE/_SUCCESS.json" \
  --from-to=LocalBlobFS --overwrite=false --put-md5

# Emit identifiers and checksums needed by operators to run and audit the restore test.
printf 'BACKUP_STATUS=SUCCESS\nRUN_ID=%s\nSNAPSHOT=%s\nARCHIVE_BYTES=%s\nARCHIVE_SHA256=%s\nBLOB_PREFIX=%s\n' \
  "$RUN_ID" "$SNAPSHOT_NAME" "$ARCHIVE_BYTES" "$ARCHIVE_SHA256" "$REMOTE_BASE"
