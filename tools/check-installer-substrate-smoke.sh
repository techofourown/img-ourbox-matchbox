#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tools/lib.sh"

need_cmd xz
need_cmd losetup
need_cmd partx
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

settle_udev() {
  if command -v udevadm >/dev/null 2>&1; then
    ${SUDO} udevadm settle >/dev/null 2>&1 || true
  fi
}

print_loop_diagnostics() {
  ${SUDO} losetup -a >&2 || true
  ${SUDO} losetup -f >&2 || true
  ls -l /dev/loop* >&2 || true
}

attach_loop_with_retry() {
  local attempt rc
  local attach_output=""
  local errfile="${TMP}/losetup.err"

  for attempt in $(seq 1 10); do
    : > "${errfile}"
    attach_output=""
    rc=0

    set +e
    attach_output="$(${SUDO} losetup --find --show "${RAW_IMG}" 2>"${errfile}")"
    rc=$?
    set -e

    if [[ ${rc} -eq 0 && -n "${attach_output}" ]]; then
      LOOPDEV="${attach_output}"
      : > "${errfile}"

      set +e
      ${SUDO} partx -u "${LOOPDEV}" >>"${errfile}" 2>&1
      rc=$?
      set -e

      if [[ ${rc} -eq 0 ]]; then
        settle_udev
        return 0
      fi

      log "Loop partition scan attempt ${attempt}/10 failed for ${LOOPDEV} (rc=${rc})"
      if [[ -s "${errfile}" ]]; then
        sed 's/^/[partx] /' "${errfile}" >&2
      fi
      ${SUDO} losetup -d "${LOOPDEV}" >/dev/null 2>&1 || true
      LOOPDEV=""
    else
      log "Loop attach attempt ${attempt}/10 failed (rc=${rc})"
      if [[ -s "${errfile}" ]]; then
        sed 's/^/[losetup] /' "${errfile}" >&2
      fi
    fi

    print_loop_diagnostics
    "${ROOT}/tools/sanitize-loopdevs.sh" || true
    settle_udev
    sleep 1
  done

  die "failed to attach loop device for ${IMG_XZ}"
}

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

log "Preflight: sanitizing loop devices before substrate smoke"
"${ROOT}/tools/sanitize-loopdevs.sh" || true
settle_udev

log "Attaching loop device"
attach_loop_with_retry

wait_for_loop_parts() {
  local deadline=$((SECONDS + 30))
  local lsblk_output=""
  local parts=()

  while (( SECONDS < deadline )); do
    # Loop devices on the official runner can take a moment to show up in lsblk
    # even after losetup returns, so treat an empty/failed probe as retryable.
    lsblk_output="$(${SUDO} lsblk -rno PATH,TYPE "${LOOPDEV}" 2>/dev/null || true)"
    if [[ -z "${lsblk_output}" ]]; then
      sleep 1
      continue
    fi
    mapfile -t parts < <(awk '$2=="part" {print $1}' <<<"${lsblk_output}")
    if (( ${#parts[@]} > 0 )); then
      printf '%s\n' "${parts[@]}"
      return 0
    fi
    sleep 1
  done

  return 1
}

loop_parts_output="$(wait_for_loop_parts || true)"
loop_parts=()
if [[ -n "${loop_parts_output}" ]]; then
  mapfile -t loop_parts <<<"${loop_parts_output}"
fi
if (( ${#loop_parts[@]} == 0 )); then
  ${SUDO} losetup -l "${LOOPDEV}" >&2 || true
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
    if ${SUDO} test -f "${MOUNT_DIR}/opt/ourbox/tools/installer-selection-resolver.sh"; then
      HAS_SELECTION_RESOLVER=1
    fi
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
