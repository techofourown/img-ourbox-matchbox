#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_SH="${SCRIPT_DIR}/lib.sh"
if [[ ! -f "${LIB_SH}" ]]; then
  LIB_SH="$(cd "${SCRIPT_DIR}/.." && pwd)/tools/lib.sh"
fi
# shellcheck disable=SC1091
source "${LIB_SH}"

if [[ "${OURBOX_FLASH_HELPER_SELFTEST:-0}" == "1" ]]; then
  log "flash helper self-test passed"
  exit 0
fi

if [[ ${EUID} -ne 0 ]]; then
  log "Re-executing with sudo..."
  exec sudo -E -- "$0" "$@"
fi

IMG="${1:-}"
DEV="${2:-}"
if [[ -z "${IMG}" || -z "${DEV}" ]]; then
  die "Usage: $0 PATH_TO_INSTALLER_IMG_XZ TARGET_DEV"
fi

need_cmd xz
need_cmd xzcat
need_cmd dd
need_cmd lsblk
need_cmd readlink
need_cmd findmnt
need_cmd partprobe
need_cmd wipefs
need_cmd blockdev
need_cmd awk
need_cmd umount

[[ -f "${IMG}" ]] || die "image not found: ${IMG}"
IMG="$(readlink -f "${IMG}")"
DEV="$(readlink -f "${DEV}")"

[[ "$(lsblk -dn -o TYPE "${DEV}" 2>/dev/null | tr -d '[:space:]')" == "disk" ]] || die "target is not a raw disk: ${DEV}"

root_src="$(findmnt -nr -o SOURCE / 2>/dev/null || true)"
root_real="$(readlink -f "${root_src}" 2>/dev/null || echo "${root_src}")"
root_parent="$(lsblk -no PKNAME "${root_real}" 2>/dev/null || true)"
if [[ -n "${root_parent}" ]]; then
  root_real="/dev/${root_parent}"
fi
[[ "${DEV}" != "${root_real}" ]] || die "refusing to flash disk backing / (${root_real})"

while read -r name mp; do
  [[ -n "${mp}" ]] || continue
  umount "/dev/${name}" >/dev/null 2>&1 || umount "${mp}" >/dev/null 2>&1 || true
done < <(lsblk -nr -o NAME,MOUNTPOINT "${DEV}" | awk 'NF==2 && $2!="" {print $1, $2}')

if lsblk -nr -o MOUNTPOINT "${DEV}" | awk 'NF && $0 != "" {found=1} END{exit !found}'; then
  lsblk -o NAME,FSTYPE,LABEL,MOUNTPOINTS "${DEV}" || true
  die "device has mounted partitions; refusing to flash"
fi

size_bytes="$(blockdev --getsize64 "${DEV}")"
if (( size_bytes < 32000000000 )); then
  die "device is too small (${size_bytes} bytes); requires at least 32000000000 bytes"
fi

log "Verifying installer image integrity: ${IMG}"
xz -t "${IMG}"

lsblk -o NAME,SIZE,MODEL,SERIAL,TYPE,FSTYPE,LABEL,MOUNTPOINTS "${DEV}"

prompt1=""
prompt2=""
read -r -p "Type FLASH to erase and flash ${DEV}: " prompt1
[[ "${prompt1}" == "FLASH" ]] || die "confirmation did not match FLASH"
read -r -p "Type the target device path exactly (${DEV}): " prompt2
[[ "${prompt2}" == "${DEV}" ]] || die "device confirmation mismatch"

if command -v blkdiscard >/dev/null 2>&1; then
  blkdiscard -f "${DEV}" >/dev/null 2>&1 || true
fi
wipefs -a "${DEV}" >/dev/null 2>&1 || true

ZERO_MIB="${ZERO_MIB:-32}"
dd if=/dev/zero of="${DEV}" bs=1M count="${ZERO_MIB}" conv=fsync status=progress

total_mib="$((size_bytes / 1024 / 1024))"
if (( total_mib > ZERO_MIB )); then
  seek_mib="$((total_mib - ZERO_MIB))"
  dd if=/dev/zero of="${DEV}" bs=1M count="${ZERO_MIB}" seek="${seek_mib}" conv=fsync status=progress
fi
sync

xzcat "${IMG}" | dd of="${DEV}" bs=4M conv=fsync status=progress
sync
partprobe "${DEV}" || true
lsblk -f "${DEV}"
