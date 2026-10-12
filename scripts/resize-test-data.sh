#!/usr/bin/env bash
# Resize only the known synthetic filler file in this disposable lab; existing snapshots are left untouched.
set -euo pipefail

source /etc/nfs-backup/lab.env
SNAPSHOT_NAME="${1:-}"
TARGET_GIB="${2:-10}"

if [[ ! "$SOURCE_ACCOUNT" =~ ^stnfsbksrc[a-z0-9]{4,8}$ || "$SOURCE_SHARE" != "nfsbackup-lab" ]]; then
  echo "Refusing: source account/share do not match the disposable lab naming pattern." >&2
  exit 2
fi
if [[ ! "$SNAPSHOT_NAME" =~ ^[0-9]{14}_snapshot$ ]]; then
  echo "Usage: $0 <existing-snapshot-name> [target-GiB]" >&2
  exit 2
fi
if [[ ! "$TARGET_GIB" =~ ^[1-9][0-9]*$ || "$TARGET_GIB" -gt 20 ]]; then
  echo "Target size must be a positive integer no larger than 20 GiB for this test." >&2
  exit 2
fi

"$SCRIPT_DIR/mount-nfs.sh" source
filler="$SOURCE_MOUNT/payload/filler.bin"
if [[ ! -f "$filler" || -L "$filler" ]]; then
  echo "Refusing: expected regular synthetic payload is missing or is a symlink." >&2
  exit 1
fi
# Require an already-created recovery point before shrinking the mutable base share.
if [[ ! -d "$SOURCE_MOUNT/.snapshots/$SNAPSHOT_NAME" ]]; then
  echo "Refusing: the named source snapshot is not visible; no files were changed." >&2
  exit 1
fi

# The lab seed layout is intentionally fixed; do not truncate if unrecognized root entries are present.
expected_entries=$'empty-file\nmetadata\nnested-a\nnested-b\npayload'
actual_entries=$(find "$SOURCE_MOUNT" -mindepth 1 -maxdepth 1 ! -name .snapshots -printf '%f\n' | sort)
if [[ "$actual_entries" != "$expected_entries" ]]; then
  echo "Refusing: source share layout differs from the expected synthetic dataset." >&2
  printf 'Found root entries:\n%s\n' "$actual_entries" >&2
  exit 1
fi

# Preserve the control files and trim only filler.bin to reach the requested approximate total.
control_bytes=$(du -sb --exclude='payload/filler.bin' "$SOURCE_MOUNT" | awk '{print $1}')
target_bytes=$((TARGET_GIB * 1024 * 1024 * 1024))
new_payload_bytes=$((target_bytes - control_bytes))
old_payload_bytes=$(stat -c '%s' "$filler")
if (( new_payload_bytes <= 0 || new_payload_bytes >= old_payload_bytes )); then
  echo "Refusing: requested size would not strictly shrink the existing synthetic payload." >&2
  exit 1
fi

printf 'EXISTING_SNAPSHOT=%s\nOLD_PAYLOAD_BYTES=%s\nCONTROL_BYTES=%s\nNEW_PAYLOAD_BYTES=%s\n' \
  "$SNAPSHOT_NAME" "$old_payload_bytes" "$control_bytes" "$new_payload_bytes"
truncate -s "$new_payload_bytes" "$filler"
sync
printf 'RESIZED_DATASET_BYTES=%s\nTARGET_GIB=%s\n' \
  "$(du -sb "$SOURCE_MOUNT" | awk '{print $1}')" "$TARGET_GIB"
