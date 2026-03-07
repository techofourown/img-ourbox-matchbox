#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tools/lib.sh"

need_cmd xz
need_cmd losetup
need_cmd lsblk
need_cmd mount
need_cmd umount
need_cmd mountpoint
need_cmd awk

DEPLOY_DIR="${DEPLOY_DIR:-${ROOT}/deploy}"
: "${OURBOX_TARGET:=rpi}"

IMG_XZ="${1:-}"
if [[ -z "${IMG_XZ}" ]]; then
  # shellcheck disable=SC2012
  IMG_XZ="$(ls -1t "${DEPLOY_DIR}"/*installer-ourbox-matchbox-"${OURBOX_TARGET,,}"-*.img.xz 2>/dev/null | head -n 1 || true)"
fi
[[ -n "${IMG_XZ}" && -f "${IMG_XZ}" ]] || die "installer image not found"

EXPECTED_OS_DEFAULT_REF="${EXPECTED_OS_DEFAULT_REF:-}"
if [[ -z "${EXPECTED_OS_DEFAULT_REF}" && -f "${DEPLOY_DIR}/os-artifact.pinned.ref" ]]; then
  EXPECTED_OS_DEFAULT_REF="$(cat "${DEPLOY_DIR}/os-artifact.pinned.ref")"
fi
[[ -n "${EXPECTED_OS_DEFAULT_REF}" ]] || die "EXPECTED_OS_DEFAULT_REF not set and ${DEPLOY_DIR}/os-artifact.pinned.ref missing"

SUDO=""
if [[ ${EUID} -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || die "sudo required to inspect installer image partitions"
  SUDO="sudo"
fi

TMP="$(mktemp -d)"
LOOPDEV=""
MOUNT_DIR="${TMP}/mnt"
RAW_IMG="${TMP}/installer.img"
EXTRACTED_DEFAULTS="${TMP}/installer-defaults.env"
mkdir -p "${MOUNT_DIR}"

cleanup() {
  if mountpoint -q "${MOUNT_DIR}" 2>/dev/null; then
    ${SUDO} umount "${MOUNT_DIR}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${LOOPDEV}" ]]; then
    ${SUDO} losetup -d "${LOOPDEV}" >/dev/null 2>&1 || true
  fi
  rm -rf "${TMP}"
}
trap cleanup EXIT

log "Extracting raw installer image from $(basename "${IMG_XZ}")"
xz -dc "${IMG_XZ}" > "${RAW_IMG}"

log "Attaching loop device"
LOOPDEV="$(${SUDO} losetup --find --show -Pf "${RAW_IMG}")"

mapfile -t ext4_parts < <(${SUDO} lsblk -rno PATH,FSTYPE "${LOOPDEV}" | awk '$2=="ext4" {print $1}')
(( ${#ext4_parts[@]} > 0 )) || die "no ext4 partitions found in installer image ${IMG_XZ}"

for part in "${ext4_parts[@]}"; do
  ${SUDO} mount -o ro "${part}" "${MOUNT_DIR}"
  if ${SUDO} test -f "${MOUNT_DIR}/opt/ourbox/installer/defaults.env"; then
    ${SUDO} cat "${MOUNT_DIR}/opt/ourbox/installer/defaults.env" > "${EXTRACTED_DEFAULTS}"
    ${SUDO} umount "${MOUNT_DIR}"
    break
  fi
  ${SUDO} umount "${MOUNT_DIR}"
done

[[ -f "${EXTRACTED_DEFAULTS}" ]] || die "failed to extract /opt/ourbox/installer/defaults.env from built installer image"

# shellcheck disable=SC1090
source "${EXTRACTED_DEFAULTS}"

[[ "${OS_DEFAULT_REF:-}" == "${EXPECTED_OS_DEFAULT_REF}" ]] || die \
  "installer defaults OS_DEFAULT_REF mismatch: expected '${EXPECTED_OS_DEFAULT_REF}', found '${OS_DEFAULT_REF:-}'"
[[ -z "${INSTALL_DEFAULTS_REF:-}" ]] || die \
  "installer defaults INSTALL_DEFAULTS_REF must be empty for official installer, found '${INSTALL_DEFAULTS_REF}'"

cp "${EXTRACTED_DEFAULTS}" "${DEPLOY_DIR}/installer-defaults.extracted.env"
cat > "${DEPLOY_DIR}/installer-defaults-smoke.txt" <<EOF
ARTIFACT=$(basename "${IMG_XZ}")
EXTRACTED_DEFAULTS=${DEPLOY_DIR}/installer-defaults.extracted.env
OS_DEFAULT_REF=${OS_DEFAULT_REF}
INSTALL_DEFAULTS_REF=${INSTALL_DEFAULTS_REF-}
EOF

log "Installer defaults smoke passed for $(basename "${IMG_XZ}")"
