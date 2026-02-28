#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tools/lib.sh"

usage() {
  cat <<EOF
Usage: $0 [--build-local] [--installer-ref REF] [--installer-channel CHANNEL] [--installer-outdir DIR]

Always interactive:
- lists removable/USB disks
- shows mount/label context
- requires operator selection in-session before flashing

Default mode (recommended):
- bootstraps host tools
- pulls official installer artifact from registry
- flashes selected media

Local source-build mode (--build-local):
- bootstraps host tools
- fetches airgap platform bundle
- builds OS + installer artifacts locally
- flashes selected media
EOF
}

BUILD_LOCAL=0
INSTALLER_REF=""
INSTALLER_CHANNEL="${INSTALLER_CHANNEL:-stable}"
INSTALLER_OUTDIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-local)
      BUILD_LOCAL=1
      shift
      ;;
    --installer-ref)
      [[ $# -ge 2 ]] || die "--installer-ref requires a value"
      INSTALLER_REF="$2"
      shift 2
      ;;
    --installer-channel)
      [[ $# -ge 2 ]] || die "--installer-channel requires a value"
      INSTALLER_CHANNEL="$2"
      shift 2
      ;;
    --installer-outdir)
      [[ $# -ge 2 ]] || die "--installer-outdir requires a value"
      INSTALLER_OUTDIR="$2"
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

if [[ "${BUILD_LOCAL}" == "1" && -n "${INSTALLER_REF}" ]]; then
  die "--installer-ref cannot be combined with --build-local"
fi

need_cmd lsblk
need_cmd readlink
need_cmd findmnt
need_cmd awk
need_cmd sed

root_backing_disk() {
  local root_src root_real root_parent
  root_src="$(findmnt -nr -o SOURCE / 2>/dev/null || true)"
  root_real="$(readlink -f "${root_src}" 2>/dev/null || echo "${root_src}")"
  root_parent="$(lsblk -no PKNAME "${root_real}" 2>/dev/null || true)"
  if [[ -n "${root_parent}" ]]; then
    echo "/dev/${root_parent}"
  else
    echo "${root_real}"
  fi
}

ROOT_DISK="$(root_backing_disk)"

preferred_byid_for_disk() {
  local disk="$1"
  local best=""
  local p target base

  for p in /dev/disk/by-id/*; do
    [[ -L "${p}" ]] || continue
    [[ "${p}" == *-part* ]] && continue
    target="$(readlink -f "${p}" 2>/dev/null || true)"
    [[ "${target}" == "${disk}" ]] || continue

    base="$(basename "${p}")"
    if [[ "${base}" == usb-* ]]; then
      echo "${p}"
      return 0
    fi
    [[ -z "${best}" ]] && best="${p}"
  done

  if [[ -n "${best}" ]]; then echo "${best}"; fi
}

is_candidate_media_disk() {
  local disk="$1"
  local type tran rm

  type="$(lsblk -dn -o TYPE "${disk}" 2>/dev/null | tr -d '[:space:]')"
  [[ "${type}" == "disk" ]] || return 1
  [[ "${disk}" != "${ROOT_DISK}" ]] || return 1

  tran="$(lsblk -dn -o TRAN "${disk}" 2>/dev/null | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
  rm="$(lsblk -dn -o RM "${disk}" 2>/dev/null | tr -d '[:space:]')"
  [[ "${tran}" == "usb" || "${rm}" == "1" ]] || return 1

  return 0
}

declare -a CANDIDATE_DISKS=()

refresh_candidate_disks() {
  CANDIDATE_DISKS=()
  while read -r disk; do
    [[ -n "${disk}" ]] || continue
    if is_candidate_media_disk "${disk}"; then
      CANDIDATE_DISKS+=("${disk}")
    fi
  done < <(lsblk -dn -o NAME,TYPE | awk '$2=="disk" {print "/dev/"$1}')
}

print_candidate_disks() {
  local idx disk size tran model serial byid

  echo
  echo "Detected removable/USB target candidates:"
  echo
  printf '  %-3s %-14s %-8s %-6s %-22s %-14s\n' "#" "Device" "Size" "Tran" "Model" "Serial"
  for idx in "${!CANDIDATE_DISKS[@]}"; do
    disk="${CANDIDATE_DISKS[$idx]}"
    size="$(lsblk -dn -o SIZE "${disk}" 2>/dev/null | tr -d '[:space:]')"
    tran="$(lsblk -dn -o TRAN "${disk}" 2>/dev/null | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
    model="$(lsblk -dn -o MODEL "${disk}" 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    serial="$(lsblk -dn -o SERIAL "${disk}" 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [[ -n "${tran}" ]] || tran="-"
    [[ -n "${model}" ]] || model="-"
    [[ -n "${serial}" ]] || serial="-"
    printf '  %-3s %-14s %-8s %-6s %-22.22s %-14.14s\n' "$((idx + 1))" "${disk}" "${size}" "${tran}" "${model}" "${serial}"

    byid="$(preferred_byid_for_disk "${disk}" || true)"
    if [[ -n "${byid}" ]]; then
      echo "      by-id: ${byid}"
    fi

    echo "      partitions (name fstype label mountpoints):"
    lsblk -nr -o NAME,FSTYPE,LABEL,MOUNTPOINTS "${disk}" 2>/dev/null | sed 's/^/        /'
  done
  echo
}

validate_target_dev_or_die() {
  local target="$1"
  local target_real target_type

  [[ -n "${target}" ]] || die "target device is empty"
  [[ "${target}" != *"<"* && "${target}" != *">"* ]] || die "target contains angle brackets; use a real /dev path"
  [[ -e "${target}" ]] || die "target device does not exist: ${target}"

  target_real="$(readlink -f "${target}")"
  target_type="$(lsblk -dn -o TYPE "${target_real}" 2>/dev/null | tr -d '[:space:]')"
  [[ "${target_type}" == "disk" ]] || die "target is not a raw disk: ${target_real}"
  [[ "${target_real}" != "${ROOT_DISK}" ]] || die "refusing target that backs / (${ROOT_DISK})"
}

select_target_device_interactive() {
  local choice idx selected byid confirm

  while true; do
    refresh_candidate_disks
    if (( ${#CANDIDATE_DISKS[@]} == 0 )); then
      echo
      echo "No removable/USB disk candidates found."
      echo "Insert the target SD/USB media, then rescan."
      read -r -p "Press ENTER to rescan, or type q to quit: " choice
      [[ "${choice}" == "q" || "${choice}" == "Q" ]] && die "no target media selected"
      continue
    fi

    print_candidate_disks
    read -r -p "Select target number (r=rescan, q=quit): " choice
    case "${choice}" in
      r|R) continue ;;
      q|Q) die "operator canceled target media selection" ;;
    esac

    [[ "${choice}" =~ ^[0-9]+$ ]] || { log "invalid selection: ${choice}"; continue; }
    idx="$((choice - 1))"
    (( idx >= 0 && idx < ${#CANDIDATE_DISKS[@]} )) || { log "selection out of range: ${choice}"; continue; }

    selected="${CANDIDATE_DISKS[$idx]}"
    byid="$(preferred_byid_for_disk "${selected}" || true)"
    if [[ -n "${byid}" ]]; then
      selected="${byid}"
    fi

    validate_target_dev_or_die "${selected}"
    echo
    lsblk -o NAME,SIZE,MODEL,SERIAL,TYPE,FSTYPE,LABEL,MOUNTPOINTS "${selected}" || true
    echo
    read -r -p "Type SELECT to use ${selected}: " confirm
    [[ "${confirm}" == "SELECT" ]] || { log "selection not confirmed; returning to list"; continue; }
    TARGET_DEV="${selected}"
    return 0
  done
}

log "Entering interactive media selection."
TARGET_DEV=""
select_target_device_interactive
validate_target_dev_or_die "${TARGET_DEV}"
log "Using target media device: ${TARGET_DEV}"

"${ROOT}/tools/bootstrap-host.sh"

: "${OURBOX_TARGET:=rpi}"
: "${OURBOX_VARIANT:=dev}"
: "${OURBOX_VERSION:=dev}"

installer_img=""
if [[ "${BUILD_LOCAL}" == "1" ]]; then
  log "Mode: local source build for OS + installer artifacts."
  "${ROOT}/tools/fetch-airgap-platform.sh"
  OURBOX_TARGET="${OURBOX_TARGET}" OURBOX_VARIANT="${OURBOX_VARIANT}" OURBOX_VERSION="${OURBOX_VERSION}" "${ROOT}/tools/build-image.sh"
  OURBOX_TARGET="${OURBOX_TARGET}" OURBOX_VARIANT="${OURBOX_VARIANT}" OURBOX_VERSION="${OURBOX_VERSION}" "${ROOT}/tools/build-installer-image.sh"
  # shellcheck disable=SC2012
  installer_img="$(ls -1t "${ROOT}"/deploy/*installer-ourbox-matchbox-"${OURBOX_TARGET,,}"-*.img.xz 2>/dev/null | head -n 1 || true)"
else
  : "${INSTALLER_OUTDIR:=${ROOT}/deploy-installer-from-registry}"
  log "Mode: pull published installer artifact from registry."
  pull_args=(--outdir "${INSTALLER_OUTDIR}")
  if [[ -n "${INSTALLER_REF}" ]]; then
    pull_args+=(--ref "${INSTALLER_REF}")
  else
    pull_args+=(--channel "${INSTALLER_CHANNEL}")
  fi
  OURBOX_TARGET="${OURBOX_TARGET}" "${ROOT}/tools/pull-installer-artifact.sh" "${pull_args[@]}"
  installer_img="${INSTALLER_OUTDIR}/installer.img.xz"
fi

if [[ -z "${installer_img}" || ! -f "${installer_img}" ]]; then
  log "ERROR: installer image not found."
  log "Expected: ${installer_img:-<none>}"
  if [[ -n "${INSTALLER_OUTDIR}" ]]; then
    log "Installer output dir contents:"
    ls -lah "${INSTALLER_OUTDIR}" || true
  fi
  log "Deploy dir contents:"
  ls -lah "${ROOT}/deploy" || true
  die "no installer image available to flash"
fi

"${ROOT}/tools/flash-installer-media.sh" "${installer_img}" "${TARGET_DEV}"

echo "Done. Move installer media to the Pi, boot it, follow prompts, wait for power-off, then boot from NVMe."
