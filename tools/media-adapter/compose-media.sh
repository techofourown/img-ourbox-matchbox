#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${MATCHBOX_ADAPTER_ROOT:=${SCRIPT_DIR}}"
ADAPTER_WORKSPACE_ROOT="$(cd "${MATCHBOX_ADAPTER_ROOT}/../.." && pwd)"

LIB_SH="${MATCHBOX_ADAPTER_ROOT}/lib.sh"
if [[ ! -f "${LIB_SH}" ]]; then
  LIB_SH="$(cd "${SCRIPT_DIR}/../.." && pwd)/tools/lib.sh"
fi
# shellcheck disable=SC1090
source "${LIB_SH}"

MISSION_DIR=""
OS_PAYLOAD=""
OS_META_ENV=""
SUBSTRATE_ARTIFACT=""
OUTPUT_DIR=""
FLASH_DEVICE=""

usage() {
  cat <<EOF
Usage: $0 --mission-dir DIR --os-payload PATH --os-meta-env PATH --substrate-artifact PATH [--output-dir DIR] [--flash-device DEV]

Matchbox mission-media composition:
- validates a prepared mission directory
- starts from a published Matchbox installer substrate image
- embeds the mission directory into /opt/ourbox/mission inside the image rootfs
- recompresses the installer image as a flashable .img.xz artifact
- optionally flashes the resulting image to removable media
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mission-dir)
      [[ $# -ge 2 ]] || die "--mission-dir requires a value"
      MISSION_DIR="$2"
      shift 2
      ;;
    --os-payload)
      [[ $# -ge 2 ]] || die "--os-payload requires a value"
      OS_PAYLOAD="$2"
      shift 2
      ;;
    --os-meta-env)
      [[ $# -ge 2 ]] || die "--os-meta-env requires a value"
      OS_META_ENV="$2"
      shift 2
      ;;
    --substrate-artifact|--substrate-img-xz)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      SUBSTRATE_ARTIFACT="$2"
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || die "--output-dir requires a value"
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --flash-device)
      [[ $# -ge 2 ]] || die "--flash-device requires a value"
      FLASH_DEVICE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      die "unknown argument: $1"
      ;;
  esac
done

[[ -n "${MISSION_DIR}" ]] || die "--mission-dir is required"
[[ -n "${OS_PAYLOAD}" ]] || die "--os-payload is required"
[[ -n "${OS_META_ENV}" ]] || die "--os-meta-env is required"
[[ -n "${SUBSTRATE_ARTIFACT}" ]] || die "--substrate-artifact is required"
[[ -f "${SUBSTRATE_ARTIFACT}" ]] || die "substrate artifact not found: ${SUBSTRATE_ARTIFACT}"

if [[ ${EUID} -ne 0 ]]; then
  log "Re-executing Matchbox media compose with sudo..."
  exec sudo -E -- "$0" "$@"
fi

need_cmd xz
need_cmd losetup
need_cmd lsblk
need_cmd mount
need_cmd umount
need_cmd mountpoint
need_cmd findmnt
need_cmd readlink
need_cmd rsync
need_cmd sha256sum
need_cmd awk
need_cmd bash

bash "${MATCHBOX_ADAPTER_ROOT}/validate-media.sh" \
  --mission-dir "${MISSION_DIR}" \
  --os-payload "${OS_PAYLOAD}" \
  --os-meta-env "${OS_META_ENV}"

STRICT_METADATA_PARSER="${MATCHBOX_ADAPTER_ROOT}/strict-kv-metadata.py"
if [[ ! -f "${STRICT_METADATA_PARSER}" ]]; then
  STRICT_METADATA_PARSER="$(cd "${SCRIPT_DIR}/../.." && pwd)/tools/strict-kv-metadata.py"
fi
[[ -f "${STRICT_METADATA_PARSER}" ]] || die "strict metadata parser not found: ${STRICT_METADATA_PARSER}"

FLASH_HELPER="${MATCHBOX_ADAPTER_ROOT}/flash-installer-media.sh"
if [[ ! -f "${FLASH_HELPER}" ]]; then
  FLASH_HELPER="$(cd "${SCRIPT_DIR}/../.." && pwd)/tools/flash-installer-media.sh"
fi
[[ -f "${FLASH_HELPER}" ]] || die "flash helper not found: ${FLASH_HELPER}"

payload_meta_dump="$(
  python3 "${STRICT_METADATA_PARSER}" "${OS_META_ENV}" \
    --allow OURBOX_TARGET \
    --allow OURBOX_SKU \
    --allow OURBOX_VARIANT \
    --allow OURBOX_VERSION \
    --print OURBOX_TARGET \
    --print OURBOX_SKU \
    --print OURBOX_VARIANT \
    --print OURBOX_VERSION
)"
mapfile -t payload_meta_fields <<<"${payload_meta_dump}"
[[ "${#payload_meta_fields[@]}" -eq 4 ]] || die "failed to parse ${OS_META_ENV}"

: "${OURBOX_PRODUCT:=ourbox}"
: "${OURBOX_DEVICE:=matchbox}"
: "${OURBOX_TARGET:=${payload_meta_fields[0]:-rpi}}"
: "${OURBOX_SKU:=${payload_meta_fields[1]:-TOO-OBX-MBX-BASE-001}}"
: "${OURBOX_VARIANT:=${payload_meta_fields[2]:-prod}}"
: "${OURBOX_VERSION:=${payload_meta_fields[3]:-host-compose}}"

OURBOX_TARGET_SLUG="$(echo "${OURBOX_TARGET}" | tr '[:upper:]' '[:lower:]')"
OURBOX_SKU_SLUG="$(echo "${OURBOX_SKU}" | tr '[:upper:]' '[:lower:]')"
OURBOX_VARIANT_SLUG="$(echo "${OURBOX_VARIANT}" | tr '[:upper:]' '[:lower:]')"
OUT_IMG_XZ="${ADAPTER_WORKSPACE_ROOT}/deploy/installer-${OURBOX_PRODUCT}-${OURBOX_DEVICE}-${OURBOX_TARGET_SLUG}-${OURBOX_SKU_SLUG}-${OURBOX_VARIANT_SLUG}-${OURBOX_VERSION}.img.xz"
OUT_SHA="${OUT_IMG_XZ}.sha256"
if [[ -n "${OUTPUT_DIR}" ]]; then
  mkdir -p "${OUTPUT_DIR}"
  OUT_IMG_XZ="${OUTPUT_DIR}/$(basename "${OUT_IMG_XZ}")"
  OUT_SHA="${OUT_IMG_XZ}.sha256"
fi
mkdir -p "$(dirname "${OUT_IMG_XZ}")"

WORK_ROOT="${OURBOX_MEDIA_COMPOSE_WORK_ROOT:-${ADAPTER_WORKSPACE_ROOT}/artifacts/work}"
mkdir -p "${WORK_ROOT}"
WORKDIR="$(mktemp -d "${WORK_ROOT}/compose-media.XXXXXX")"
RAW_IMG="${WORKDIR}/installer.img"
MOUNT_DIR="${WORKDIR}/mnt"
LOOPDEV=""
ROOT_PART=""

cleanup() {
  if [[ -n "${MOUNT_DIR}" && -d "${MOUNT_DIR}" && "$(mountpoint -q "${MOUNT_DIR}" >/dev/null 2>&1; echo $?)" -eq 0 ]]; then
    umount "${MOUNT_DIR}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${LOOPDEV}" ]]; then
    losetup -d "${LOOPDEV}" >/dev/null 2>&1 || true
  fi
  rm -rf -- "${WORKDIR}"
}
trap cleanup EXIT

mkdir -p "${MOUNT_DIR}"

log "Decompressing Matchbox installer substrate"
xz -dc "${SUBSTRATE_ARTIFACT}" > "${RAW_IMG}"

log "Attaching loop device for Matchbox installer substrate"
LOOPDEV="$(losetup --find --show -Pf "${RAW_IMG}")"

wait_for_loop_parts() {
  local deadline=$((SECONDS + 10))
  local parts=()

  while (( SECONDS < deadline )); do
    mapfile -t parts < <(lsblk -rno PATH,TYPE "${LOOPDEV}" | awk '$2=="part" {print $1}')
    if (( ${#parts[@]} > 0 )); then
      printf '%s\n' "${parts[@]}"
      return 0
    fi
    sleep 1
  done

  return 1
}

find_root_partition() {
  local part=""

  while read -r part; do
    [[ -n "${part}" ]] || continue
    if mount -o rw "${part}" "${MOUNT_DIR}" >/dev/null 2>&1; then
      if [[ -f "${MOUNT_DIR}/opt/ourbox/tools/ourbox-install" ]]; then
        printf '%s\n' "${part}"
        return 0
      fi
      umount "${MOUNT_DIR}" >/dev/null 2>&1 || true
    fi
  done

  return 1
}

mapfile -t loop_parts < <(wait_for_loop_parts)
(( ${#loop_parts[@]} > 0 )) || die "no loop partitions found in Matchbox substrate ${SUBSTRATE_ARTIFACT}"

ROOT_PART="$(printf '%s\n' "${loop_parts[@]}" | find_root_partition || true)"
[[ -n "${ROOT_PART}" ]] || die "failed to locate the Matchbox installer root partition in ${SUBSTRATE_ARTIFACT}"

[[ -d "${MOUNT_DIR}/opt/ourbox/tools" ]] || die "Matchbox installer rootfs missing /opt/ourbox/tools"
[[ -f "${MOUNT_DIR}/opt/ourbox/tools/ourbox-install" ]] || die "Matchbox installer rootfs missing /opt/ourbox/tools/ourbox-install"
[[ -f "${MOUNT_DIR}/opt/ourbox/installer/defaults.env" ]] || die "Matchbox installer rootfs missing /opt/ourbox/installer/defaults.env"

install -d -m 0755 "${MOUNT_DIR}/opt/ourbox/mission"
rsync -a --delete "${MISSION_DIR}/" "${MOUNT_DIR}/opt/ourbox/mission/"
[[ -f "${MOUNT_DIR}/opt/ourbox/mission/mission-manifest.json" ]] \
  || die "mission-manifest.json missing after Matchbox mission embed"

sync
umount "${MOUNT_DIR}"
losetup -d "${LOOPDEV}"
LOOPDEV=""

log "Compressing composed Matchbox mission media"
rm -f "${OUT_IMG_XZ}" "${OUT_SHA}"
xz -z -c "${RAW_IMG}" > "${OUT_IMG_XZ}"
( cd "$(dirname "${OUT_IMG_XZ}")" && sha256sum "$(basename "${OUT_IMG_XZ}")" > "$(basename "${OUT_SHA}")" )

[[ -f "${OUT_IMG_XZ}" ]] || die "expected composed image not found: ${OUT_IMG_XZ}"
[[ -f "${OUT_SHA}" ]] || die "expected composed image checksum not found: ${OUT_SHA}"

if [[ -n "${FLASH_DEVICE}" ]]; then
  "${FLASH_HELPER}" "${OUT_IMG_XZ}" "${FLASH_DEVICE}"
fi

log "Matchbox mission media ready: ${OUT_IMG_XZ}"
log "Checksum file: ${OUT_SHA}"
