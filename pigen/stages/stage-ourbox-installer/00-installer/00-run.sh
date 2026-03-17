#!/usr/bin/env bash
set -euo pipefail

: "${ROOTFS_DIR:?ROOTFS_DIR not set}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"

# Rootfs MUST be seeded by prerun.sh via copy_previous.
[[ -f "${ROOTFS_DIR}/etc/os-release" ]] || {
  echo "ERROR: stage rootfs is not seeded (missing ${ROOTFS_DIR}/etc/os-release)." >&2
  echo "Fix: pigen/stages/stage-ourbox-installer/prerun.sh must call copy_previous." >&2
  exit 1
}

cp -a "${SCRIPT_DIR}/files/." "${ROOTFS_DIR}/"
install -D -m 0644 \
  "${REPO_ROOT}/tools/matchbox-storage-flow.sh" \
  "${ROOTFS_DIR}/opt/ourbox/tools/matchbox-storage-flow.sh"
install -D -m 0644 \
  "${REPO_ROOT}/tools/installer-ssh-helper.sh" \
  "${ROOTFS_DIR}/opt/ourbox/tools/installer-ssh-helper.sh"

install -d -m 0755 "${ROOTFS_DIR}/opt/ourbox/installer"
install -d -m 0755 "${ROOTFS_DIR}/opt/ourbox/mission"
