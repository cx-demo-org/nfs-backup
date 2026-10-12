#!/usr/bin/env bash
# Populate only the disposable source share with repeatable test structures and real, non-sparse sample bytes.
set -euo pipefail

source /etc/nfs-backup/lab.env
# Ensure local staging is ready and seed through the same private AZNFS mount used by backup operations.
"$SCRIPT_DIR/prepare-stage.sh" >/dev/null
"$SCRIPT_DIR/mount-nfs.sh" source

# Never overwrite a pre-existing test/user dataset; .snapshots is Azure's synthetic view and is ignored here.
if [[ -n "$(find "$SOURCE_MOUNT" -mindepth 1 -maxdepth 1 ! -name .snapshots -print -quit)" ]]; then
  echo "Source share is not empty; refusing to overwrite test data." >&2
  exit 1
fi

# Create representative paths: repeated basenames, empty file, symlink, and a pair of hardlinked names.
mkdir -p "$SOURCE_MOUNT"/{nested-a,nested-b,metadata,payload}
printf 'same leaf name, first path\n' > "$SOURCE_MOUNT/nested-a/shared.txt"
printf 'same leaf name, second path\n' > "$SOURCE_MOUNT/nested-b/shared.txt"
printf '' > "$SOURCE_MOUNT/empty-file"
printf 'symlink target\n' > "$SOURCE_MOUNT/metadata/link-target.txt"
ln -s link-target.txt "$SOURCE_MOUNT/metadata/symlink.txt"
printf 'hardlink payload\n' > "$SOURCE_MOUNT/metadata/hardlink-a.txt"
ln "$SOURCE_MOUNT/metadata/hardlink-a.txt" "$SOURCE_MOUNT/metadata/hardlink-b.txt"
# Set non-default POSIX mode and IDs so archive/restore fidelity can be measured rather than assumed.
chmod 0640 "$SOURCE_MOUNT/nested-a/shared.txt"
chmod 0750 "$SOURCE_MOUNT/nested-a"
chown 12345:23456 "$SOURCE_MOUNT/nested-a/shared.txt" "$SOURCE_MOUNT/nested-a" || {
  echo "Could not set the requested test UID/GID on NFS; record this as a metadata-fidelity blocker." >&2
  exit 1
}

# Use real random bytes rather than a sparse file so I/O time and staging requirements are representative.
target_bytes=$((SEED_TOTAL_GIB * 1024 * 1024 * 1024))
# Include control files in the requested total, then fill the remaining amount with the large payload.
control_bytes=$(du -sb "$SOURCE_MOUNT" | awk '{print $1}')
remaining=$((target_bytes - control_bytes))
if (( remaining <= 0 )); then
  echo "Control files exceed requested dataset size; increase SEED_TOTAL_GIB." >&2
  exit 1
fi
# Write in large blocks to avoid expensive per-byte I/O on the NFS share.
block_bytes=$((16 * 1024 * 1024))
full_blocks=$((remaining / block_bytes))
remainder=$((remaining % block_bytes))
dd if=/dev/urandom of="$SOURCE_MOUNT/payload/filler.bin" bs="$block_bytes" count="$full_blocks" status=progress conv=fsync
if (( remainder > 0 )); then
  remainder_mib=$((remainder / (1024 * 1024)))
  final_bytes=$((remainder % (1024 * 1024)))
  if (( remainder_mib > 0 )); then
    dd if=/dev/urandom of="$SOURCE_MOUNT/payload/filler.bin" bs=1M count="$remainder_mib" oflag=append conv=notrunc status=none
  fi
  if (( final_bytes > 0 )); then
    dd if=/dev/urandom of="$SOURCE_MOUNT/payload/filler.bin" bs=1 count="$final_bytes" oflag=append conv=notrunc status=none
  fi
fi
# Flush client writes before taking a point-in-time snapshot.
sync
# Report the actual seeded byte count for the test record.
printf 'SEEDED_BYTES=%s\n' "$(du -sb "$SOURCE_MOUNT" | awk '{print $1}')"
printf 'SEED_TOTAL_GIB=%s\n' "$SEED_TOTAL_GIB"
