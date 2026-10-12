#!/usr/bin/env bash
# Restore one archived recovery point to the isolated NFS restore share and verify the resulting tree.
set -euo pipefail

source /etc/nfs-backup/lab.env
# Validate the user-supplied run ID before using it in local paths or Blob URLs.
RUN_ID="${1:-}"
if [[ -z "$RUN_ID" || ! "$RUN_ID" =~ ^[A-Za-z0-9T._-]{1,80}$ ]]; then
  echo "Usage: $0 <recovery-point-id>" >&2
  exit 2
fi
"$SCRIPT_DIR/prepare-stage.sh" >/dev/null
"$SCRIPT_DIR/mount-nfs.sh" restore

# Preserve safety: never overlay an existing restore tree or damage prior test data.
if [[ -n "$(find "$RESTORE_MOUNT" -mindepth 1 -maxdepth 1 ! -name .snapshots -print -quit)" ]]; then
  echo "Restore share is not empty; refusing to overwrite test data." >&2
  exit 1
fi

RUN_DIR="$STAGE_MOUNT/restore-test/$RUN_ID"
mkdir -p "$RUN_DIR"
# Fetch the selected run's marker, archive, and sidecars from the private DFS endpoint using managed identity.
REMOTE_BASE="https://${DESTINATION_ACCOUNT}.dfs.core.windows.net/${BLOB_CONTAINER}/recovery-points/${RUN_ID}"
azcopy login --identity --identity-client-id "$WORKER_CLIENT_ID"
azcopy copy "$REMOTE_BASE/_SUCCESS.json" "$RUN_DIR/_SUCCESS.json" --from-to=BlobFSLocal
azcopy copy "$REMOTE_BASE/backup.tar" "$RUN_DIR/backup.tar" --from-to=BlobFSLocal
azcopy copy "$REMOTE_BASE/manifest.json" "$RUN_DIR/manifest.json" --from-to=BlobFSLocal
azcopy copy "$REMOTE_BASE/run.json" "$RUN_DIR/run.json" --from-to=BlobFSLocal

# Verify transport/storage integrity before extracting any archive content to the NFS restore share.
remote_sha256=$(jq -r '.archive.sha256' "$RUN_DIR/run.json")
local_sha256=$(sha256sum "$RUN_DIR/backup.tar" | awk '{print $1}')
if [[ "$remote_sha256" != "$local_sha256" ]]; then
  echo "Downloaded archive SHA-256 does not match the uploaded recovery-point manifest." >&2
  exit 1
fi

# Extract numeric ownership, POSIX permissions, pax timestamps, symlinks, and hardlinks from the archive.
sudo tar --extract --file "$RUN_DIR/backup.tar" --directory "$RESTORE_MOUNT" \
  --numeric-owner --same-owner --same-permissions --sparse
# Compare the restored tree against the manifest captured from the point-in-time snapshot.
python3 "$SCRIPT_DIR/manifest.py" create --root "$RESTORE_MOUNT" --output "$RUN_DIR/restored-manifest.json"
python3 "$SCRIPT_DIR/manifest.py" compare --expected "$RUN_DIR/manifest.json" --actual "$RUN_DIR/restored-manifest.json"
printf 'RESTORE_STATUS=PASS\nRUN_ID=%s\nRESTORE_PATH=%s\nARCHIVE_SHA256=%s\n' \
  "$RUN_ID" "$RESTORE_MOUNT" "$local_sha256"
