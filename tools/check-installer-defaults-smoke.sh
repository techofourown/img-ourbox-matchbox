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

wait_for_loop_parts() {
  local deadline=$((SECONDS + 10))
  local parts=()

  while (( SECONDS < deadline )); do
    mapfile -t parts < <(${SUDO} lsblk -rno PATH,TYPE "${LOOPDEV}" | awk '$2=="part" {print $1}')
    if (( ${#parts[@]} > 0 )); then
      printf '%s\n' "${parts[@]}"
      return 0
    fi
    sleep 1
  done

  return 1
}

mapfile -t loop_parts < <(wait_for_loop_parts)
if (( ${#loop_parts[@]} == 0 )); then
  ${SUDO} lsblk -rno PATH,TYPE,FSTYPE "${LOOPDEV}" >&2 || true
  die "no loop partitions found in installer image ${IMG_XZ}"
fi

for part in "${loop_parts[@]}"; do
  if ! ${SUDO} mount -o ro "${part}" "${MOUNT_DIR}" >/dev/null 2>&1; then
    continue
  fi

  if ${SUDO} test -f "${MOUNT_DIR}/opt/ourbox/installer/defaults.env"; then
    ${SUDO} cat "${MOUNT_DIR}/opt/ourbox/installer/defaults.env" > "${EXTRACTED_DEFAULTS}"
    ${SUDO} umount "${MOUNT_DIR}"
    break
  fi
  ${SUDO} umount "${MOUNT_DIR}"
done

if [[ ! -f "${EXTRACTED_DEFAULTS}" ]]; then
  ${SUDO} lsblk -rno PATH,TYPE,FSTYPE "${LOOPDEV}" >&2 || true
  die "failed to extract /opt/ourbox/installer/defaults.env from built installer image"
fi

# The legacy airgap fallback keys are intentionally gone from official media.
grep -q '^AIRGAP_PLATFORM_DEFAULT_REF=' "${EXTRACTED_DEFAULTS}" && die \
  "installer defaults must not carry AIRGAP_PLATFORM_DEFAULT_REF anymore"
grep -q '^AIRGAP_PLATFORM_CHANNEL_STABLE_TAG=' "${EXTRACTED_DEFAULTS}" && die \
  "installer defaults must not carry AIRGAP_PLATFORM_CHANNEL_STABLE_TAG anymore"
grep -q '^AIRGAP_PLATFORM_CHANNEL_BETA_TAG=' "${EXTRACTED_DEFAULTS}" && die \
  "installer defaults must not carry AIRGAP_PLATFORM_CHANNEL_BETA_TAG anymore"
grep -q '^AIRGAP_PLATFORM_CHANNEL_NIGHTLY_TAG=' "${EXTRACTED_DEFAULTS}" && die \
  "installer defaults must not carry AIRGAP_PLATFORM_CHANNEL_NIGHTLY_TAG anymore"
grep -q '^AIRGAP_PLATFORM_CHANNEL_EXP_LABS_TAG=' "${EXTRACTED_DEFAULTS}" && die \
  "installer defaults must not carry AIRGAP_PLATFORM_CHANNEL_EXP_LABS_TAG anymore"

# shellcheck disable=SC1090
source "${EXTRACTED_DEFAULTS}"

[[ "${OS_DEFAULT_REF:-}" == "${EXPECTED_OS_DEFAULT_REF}" ]] || die \
  "installer defaults OS_DEFAULT_REF mismatch: expected '${EXPECTED_OS_DEFAULT_REF}', found '${OS_DEFAULT_REF:-}'"
[[ -z "${AIRGAP_PLATFORM_REF:-}" ]] || die \
  "installer defaults AIRGAP_PLATFORM_REF must be empty on official media, found '${AIRGAP_PLATFORM_REF:-}'"
[[ "${AIRGAP_PLATFORM_ARCH:-}" == "arm64" ]] || die \
  "installer defaults AIRGAP_PLATFORM_ARCH mismatch: expected 'arm64', found '${AIRGAP_PLATFORM_ARCH:-}'"
[[ "${AIRGAP_PLATFORM_CATALOG_TAG:-}" == "catalog-arm64" ]] || die \
  "installer defaults AIRGAP_PLATFORM_CATALOG_TAG mismatch: expected 'catalog-arm64', found '${AIRGAP_PLATFORM_CATALOG_TAG:-}'"
[[ -z "${INSTALL_DEFAULTS_REF:-}" ]] || die \
  "installer defaults INSTALL_DEFAULTS_REF must be empty for official installer, found '${INSTALL_DEFAULTS_REF}'"

cp "${EXTRACTED_DEFAULTS}" "${DEPLOY_DIR}/installer-defaults.extracted.env"
cat > "${DEPLOY_DIR}/installer-defaults-smoke.txt" <<EOF
ARTIFACT=$(basename "${IMG_XZ}")
EXTRACTED_DEFAULTS=${DEPLOY_DIR}/installer-defaults.extracted.env
OS_DEFAULT_REF=${OS_DEFAULT_REF}
AIRGAP_PLATFORM_REF=${AIRGAP_PLATFORM_REF-}
AIRGAP_PLATFORM_ARCH=${AIRGAP_PLATFORM_ARCH}
AIRGAP_PLATFORM_CATALOG_TAG=${AIRGAP_PLATFORM_CATALOG_TAG}
INSTALL_DEFAULTS_REF=${INSTALL_DEFAULTS_REF-}
EOF

log "Installer defaults smoke passed for $(basename "${IMG_XZ}")"
