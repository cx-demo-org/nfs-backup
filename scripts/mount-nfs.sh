#!/usr/bin/env bash
# Mount the lab's classic Azure Files NFS shares using AZNFS (TLS) inside the private worker VM.
set -euo pipefail

# Mount paths, account, and share names are injected into this root-owned environment file at deployment.
source /etc/nfs-backup/lab.env

mount_share() {
  # Accept account/share/path separately so callers cannot accidentally mount the source over the restore path.
  local account="$1" share="$2" mount_path="$3"
  sudo mkdir -p "$mount_path"
  # Reuse an existing mount to keep seed/backup/restore operations idempotent.
  if mountpoint -q "$mount_path"; then
    return 0
  fi
  # AZNFS supplies TLS for NFSv4.1; sec=sys carries the POSIX UID/GID values used by this lab.
  sudo mount -t aznfs "${account}.file.core.windows.net:/${account}/${share}" "$mount_path" \
    -o vers=4,minorversion=1,sec=sys,nconnect=4
  mountpoint -q "$mount_path"
}

# Support targeted mounts for scripts and a convenience mode for manual troubleshooting.
case "${1:-both}" in
  source) mount_share "$SOURCE_ACCOUNT" "$SOURCE_SHARE" "$SOURCE_MOUNT" ;;
  restore) mount_share "$SOURCE_ACCOUNT" "$RESTORE_SHARE" "$RESTORE_MOUNT" ;;
  both)
    mount_share "$SOURCE_ACCOUNT" "$SOURCE_SHARE" "$SOURCE_MOUNT"
    mount_share "$SOURCE_ACCOUNT" "$RESTORE_SHARE" "$RESTORE_MOUNT"
    ;;
  *) echo "Usage: $0 [source|restore|both]" >&2; exit 2 ;;
esac
