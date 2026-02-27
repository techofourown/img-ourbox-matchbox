#!/usr/bin/env bash
set -euo pipefail

: "${ROOTFS_DIR:?ROOTFS_DIR not set}"

# IMPORTANT: Custom stages must start from the previous stage's rootfs.
# If ROOTFS_DIR exists but is not a real Debian rootfs, pi-gen chroot mounting will fail
# (e.g., missing /proc, /bin, apt, etc.).
if [[ ! -f "${ROOTFS_DIR}/etc/os-release" ]]; then
  rm -rf "${ROOTFS_DIR}"
  copy_previous
fi

# Defensive: ensure standard mountpoints exist (pi-gen will mount these during on_chroot)
install -d -m 0755 \
  "${ROOTFS_DIR}/proc" \
  "${ROOTFS_DIR}/sys" \
  "${ROOTFS_DIR}/dev/pts"
