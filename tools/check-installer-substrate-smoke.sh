#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tools/lib.sh"

need_cmd xz
need_cmd sfdisk
need_cmd dd
need_cmd debugfs
need_cmd python3

DEPLOY_DIR="${DEPLOY_DIR:-${ROOT}/deploy}"
: "${OURBOX_TARGET:=rpi}"

IMG_XZ="${1:-}"
if [[ -z "${IMG_XZ}" ]]; then
  # shellcheck disable=SC2012
  IMG_XZ="$(ls -1t "${DEPLOY_DIR}"/*installer-ourbox-matchbox-"${OURBOX_TARGET,,}"-*.img.xz 2>/dev/null | head -n 1 || true)"
fi
[[ -n "${IMG_XZ}" && -f "${IMG_XZ}" ]] || die "installer image not found"

TMP="$(mktemp -d)"
RAW_IMG="${TMP}/installer.img"
PART_IMG="${TMP}/installer-root.ext4"
EXTRACTED_DEFAULTS="${TMP}/installer-runtime.env"

cleanup() {
  rm -rf "${TMP}"
}
trap cleanup EXIT

log "Extracting raw installer image from $(basename "${IMG_XZ}")"
xz -dc "${IMG_XZ}" > "${RAW_IMG}"

log "Parsing partition table"
PART_INFO="$(python3 - "${RAW_IMG}" <<'PYEOF'
import json, subprocess, sys
out = subprocess.check_output(["sfdisk", "-J", sys.argv[1]], text=True)
pt = json.loads(out)["partitiontable"]
for p in pt["partitions"]:
    # MBR type 83 = Linux; GPT Linux data partition GUID
    if p.get("type", "").lower() in ("83", "0fc63daf-8483-4772-8e79-3d69d8477de4"):
        print(p["start"], p["size"])
        break
PYEOF
)" || die "failed to parse partition table from installer image"

[[ -n "${PART_INFO}" ]] || die "no Linux partition found in installer image"
read -r PART_START PART_SIZE <<< "${PART_INFO}"

log "Extracting root partition (start=${PART_START}, size=${PART_SIZE} sectors)"
dd if="${RAW_IMG}" bs=512 skip="${PART_START}" count="${PART_SIZE}" of="${PART_IMG}" status=none

log "Reading installer defaults"
debugfs -R "cat /opt/ourbox/installer/defaults.env" "${PART_IMG}" > "${EXTRACTED_DEFAULTS}" 2>/dev/null
[[ -s "${EXTRACTED_DEFAULTS}" ]] \
  || die "failed to extract /opt/ourbox/installer/defaults.env from built installer image"

debugfs_has() {
  local path="$1"
  debugfs -R "stat ${path}" "${PART_IMG}" 2>&1 | grep -q "^Inode:"
}

HAS_INSTALLER=0
HAS_MISSION_DIR=0
HAS_SSH_HELPER=0
HAS_SELECTION_RESOLVER=0

debugfs_has "/opt/ourbox/tools/ourbox-install"                  && HAS_INSTALLER=1
debugfs_has "/opt/ourbox/tools/installer-ssh-helper.sh"         && HAS_SSH_HELPER=1
debugfs_has "/opt/ourbox/mission"                               && HAS_MISSION_DIR=1
debugfs_has "/opt/ourbox/tools/installer-selection-resolver.sh" && HAS_SELECTION_RESOLVER=1

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

[[ "${INSTALLER_ID:-}" == "matchbox" ]] \
  || die "installer runtime INSTALLER_ID mismatch: expected 'matchbox', found '${INSTALLER_ID:-}'"
[[ -n "${INSTALLER_VERSION:-}" ]] \
  || die "installer runtime INSTALLER_VERSION must be non-empty"
[[ -n "${INSTALLER_GIT_HASH:-}" ]] \
  || die "installer runtime INSTALLER_GIT_HASH must be non-empty"
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

[[ "${HAS_INSTALLER}" == "1" ]]          || die "installer substrate is missing /opt/ourbox/tools/ourbox-install"
[[ "${HAS_SSH_HELPER}" == "1" ]]         || die "installer substrate is missing /opt/ourbox/tools/installer-ssh-helper.sh"
[[ "${HAS_MISSION_DIR}" == "1" ]]        || die "installer substrate is missing /opt/ourbox/mission"
[[ "${HAS_SELECTION_RESOLVER}" == "0" ]] \
  || die "installer substrate must not ship /opt/ourbox/tools/installer-selection-resolver.sh"

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
