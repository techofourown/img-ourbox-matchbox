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

SUDO=""
if [[ ${EUID} -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || die "sudo required to inspect installer image partitions"
  SUDO="sudo"
fi

TMP="$(mktemp -d)"
LOOPDEV=""
MOUNT_DIR="${TMP}/mnt"
RAW_IMG="${TMP}/installer.img"
EXTRACTED_DEFAULTS="${TMP}/installer-runtime.env"
HAS_INSTALLER=0
HAS_MISSION_DIR=0
HAS_SSH_HELPER=0
HAS_SELECTION_RESOLVER=0
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
    ${SUDO} test -f "${MOUNT_DIR}/opt/ourbox/tools/ourbox-install" && HAS_INSTALLER=1
    ${SUDO} test -f "${MOUNT_DIR}/opt/ourbox/tools/installer-ssh-helper.sh" && HAS_SSH_HELPER=1
    ${SUDO} test -d "${MOUNT_DIR}/opt/ourbox/mission" && HAS_MISSION_DIR=1
    ${SUDO} test -f "${MOUNT_DIR}/opt/ourbox/tools/installer-selection-resolver.sh" && HAS_SELECTION_RESOLVER=1 || true
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

required_key() {
  local key="$1"
  grep -Eq "^${key}=" "${EXTRACTED_DEFAULTS}" || die "installer runtime defaults missing ${key}"
}

forbidden_key() {
  local key="$1"
  grep -Eq "^${key}=" "${EXTRACTED_DEFAULTS}" && die "installer runtime defaults must not define ${key}"
}

required_key "INSTALLER_ID"
required_key "INSTALLER_VERSION"
required_key "INSTALLER_GIT_HASH"
required_key "OURBOX_INSTALLER_SSH_TEARDOWN_ON_COMPLETE"

# shellcheck disable=SC1090
source "${EXTRACTED_DEFAULTS}"

[[ "${INSTALLER_ID:-}" == "matchbox" ]] || die "installer runtime INSTALLER_ID mismatch: expected 'matchbox', found '${INSTALLER_ID:-}'"
[[ -n "${INSTALLER_VERSION:-}" ]] || die "installer runtime INSTALLER_VERSION must be non-empty"
[[ -n "${INSTALLER_GIT_HASH:-}" ]] || die "installer runtime INSTALLER_GIT_HASH must be non-empty"
[[ "${OURBOX_INSTALLER_SSH_TEARDOWN_ON_COMPLETE:-}" =~ ^(0|1)$ ]] \
  || die "installer runtime OURBOX_INSTALLER_SSH_TEARDOWN_ON_COMPLETE must be 0 or 1"

forbidden_key "OS_REPO"
forbidden_key "OS_CHANNEL"
forbidden_key "OS_DEFAULT_REF"
forbidden_key "OS_REF"
forbidden_key "INSTALL_DEFAULTS_REF"
forbidden_key "AIRGAP_PLATFORM_REF"
forbidden_key "AIRGAP_PLATFORM_DEFAULT_REF"
forbidden_key "AIRGAP_PLATFORM_CHANNEL"
forbidden_key "AIRGAP_PLATFORM_CATALOG_TAG"

[[ "${HAS_INSTALLER}" == "1" ]] || die "installer substrate is missing /opt/ourbox/tools/ourbox-install"
[[ "${HAS_SSH_HELPER}" == "1" ]] || die "installer substrate is missing /opt/ourbox/tools/installer-ssh-helper.sh"
[[ "${HAS_MISSION_DIR}" == "1" ]] || die "installer substrate is missing /opt/ourbox/mission"
[[ "${HAS_SELECTION_RESOLVER}" == "0" ]] || die "installer substrate must not ship /opt/ourbox/tools/installer-selection-resolver.sh"

cp "${EXTRACTED_DEFAULTS}" "${DEPLOY_DIR}/installer-runtime.extracted.env"
cat > "${DEPLOY_DIR}/installer-substrate-smoke.txt" <<EOF
ARTIFACT=$(basename "${IMG_XZ}")
EXTRACTED_DEFAULTS=${DEPLOY_DIR}/installer-runtime.extracted.env
INSTALLER_ID=${INSTALLER_ID}
INSTALLER_VERSION=${INSTALLER_VERSION}
INSTALLER_GIT_HASH=${INSTALLER_GIT_HASH}
OURBOX_INSTALLER_SSH_TEARDOWN_ON_COMPLETE=${OURBOX_INSTALLER_SSH_TEARDOWN_ON_COMPLETE}
HAS_OURBOX_INSTALL=1
HAS_INSTALLER_SSH_HELPER=1
HAS_MISSION_DIR=1
HAS_SELECTION_RESOLVER=0
EOF

log "Installer substrate smoke passed for $(basename "${IMG_XZ}")"
