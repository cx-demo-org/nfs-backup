#!/usr/bin/env bash
# Prepare the dedicated managed staging disk for local archive and restore artifacts.
set -euo pipefail

source /etc/nfs-backup/lab.env
# Azure Linux exposes the attached staging data disk as the first SCSI LUN.
DEVICE=/dev/disk/azure/scsi1/lun0

# Wait up to six minutes for udev/waagent to publish the block device after VM boot/attachment.
for _ in $(seq 1 180); do
  [[ -b "$DEVICE" ]] && break
  sleep 2
done
if [[ ! -b "$DEVICE" ]]; then
  echo "Staging disk $DEVICE did not appear; verify the managed-disk attachment." >&2
  exit 1
fi

if ! sudo blkid "$DEVICE" >/dev/null 2>&1; then
  # Only format this lab's dedicated, newly-created empty staging disk; never format an already recognized filesystem.
  sudo mkfs.ext4 -F -m 0 -L nfsbackup-stage "$DEVICE"
fi

# Reject unexpected filesystems rather than mounting or formatting an unknown device.
filesystem=$(sudo blkid -s TYPE -o value "$DEVICE")
if [[ "$filesystem" != "ext4" ]]; then
  echo "Refusing unexpected staging-disk filesystem: $filesystem" >&2
  exit 1
fi
uuid=$(sudo blkid -s UUID -o value "$DEVICE")
# Mount by UUID so the path remains stable across device discovery order changes.
sudo mkdir -p "$STAGE_MOUNT"
if ! mountpoint -q "$STAGE_MOUNT"; then
  sudo mount "UUID=$uuid" "$STAGE_MOUNT"
fi
sudo chmod 0700 "$STAGE_MOUNT"
# Show capacity so operators can compare archive use with the configured stage-disk size.
df -h "$STAGE_MOUNT"
