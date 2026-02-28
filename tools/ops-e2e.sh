#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "${ROOT}/tools/lib.sh"
# shellcheck disable=SC1091
source "${ROOT}/tools/registry.sh"

need_cmd lsblk
need_cmd readlink
need_cmd sed
need_cmd awk
need_cmd git
need_cmd mount
need_cmd umount
need_cmd mountpoint
need_cmd find
need_cmd blkid
need_cmd findmnt

SUDO=""
if [[ ${EUID} -ne 0 ]]; then
  need_cmd sudo
  SUDO="sudo -E"
fi

# Captured during preflight to avoid re-scanning later.
PREFLIGHT_NVME_DISKS=()

REGISTRY_ROUNDTRIP=0
if [[ "${1:-}" == "--registry-roundtrip" ]]; then
  REGISTRY_ROUNDTRIP=1
  shift
fi
if [[ $# -ne 0 ]]; then
  die "Usage: $0 [--registry-roundtrip]"
fi

banner() {
  echo
  echo "=================================================================="
  echo "OurBox Matchbox OS — End-to-end build + flash (interactive, destructive)"
  echo "=================================================================="
  echo
}

prompt_confirm_exact() {
  local expected="$1"
  local prompt="$2"
  local ans=""
  read -r -p "${prompt} " ans
  [[ "${ans}" == "${expected}" ]] || die "confirmation did not match (expected: ${expected})"
}

prompt_nonempty() {
  local prompt="$1"
  local default="${2:-}"
  local ans=""
  if [[ -n "${default}" ]]; then
    read -r -p "${prompt} [${default}]: " ans
    ans="${ans:-${default}}"
  else
    read -r -p "${prompt}: " ans
  fi
  [[ -n "${ans}" ]] || die "value required"
  echo "${ans}"
}

ensure_not_booted_from_nvme() {
  local root_src root_real root_parent
  root_src="$(findmnt -nr -o SOURCE / 2>/dev/null || true)"
  root_real="$(readlink -f "${root_src}" 2>/dev/null || echo "${root_src}")"
  root_parent="$(lsblk -no PKNAME "${root_real}" 2>/dev/null || true)"
  if [[ -n "${root_parent}" ]]; then
    root_real="/dev/${root_parent}"
  fi

  if [[ "${root_real}" == /dev/nvme* ]]; then
    die "root filesystem is on an NVMe device (${root_real}). Boot from SD/USB before flashing NVMe."
  fi
}

preflight_flash_topology_or_die() {
  log "Preflight: verifying this host is safe for build+flash"

  # Require exactly 2 NVMe disks (Matchbox contract)
  mapfile -t disks < <(nvme_disks)
  if [[ "${#disks[@]}" -ne 2 ]]; then
    echo
    lsblk -o NAME,SIZE,MODEL,SERIAL,TYPE,FSTYPE,LABEL,MOUNTPOINTS || true
    echo
    die "This workflow requires exactly 2 NVMe disks (DATA+SYSTEM). Found ${#disks[@]}. Run on Matchbox hardware with dual NVMe."
  fi

  show_nvme_summary "${disks[@]}"

  # Hard stop if root is on NVMe (you are running from the disk you're about to overwrite)
  local root_src root_real root_parent
  root_src="$(findmnt -nr -o SOURCE / 2>/dev/null || true)"
  root_real="$(readlink -f "${root_src}" 2>/dev/null || echo "${root_src}")"

  # If we got /dev/root or a mapper, walk to the parent block device when possible.
  root_parent="$(lsblk -no PKNAME "${root_real}" 2>/dev/null || true)"
  if [[ -n "${root_parent}" ]]; then
    root_real="/dev/${root_parent}"
  fi

  if [[ "${root_real}" == /dev/nvme* ]]; then
    die "Root filesystem (/) is on NVMe (${root_real}). DO NOT run ops-e2e on an installed system. Boot from SD/USB (rescue/installer mode) and rerun."
  fi

  # Refuse if any NVMe partitions are mounted (DATA in use, or someone mounted SYSTEM)
  if lsblk -nr -o MOUNTPOINT "${disks[@]}" | awk 'NF && $0 != "" {found=1} END{exit !found}'; then
    echo
    log "NVMe partitions are currently mounted:"
    lsblk -o NAME,FSTYPE,LABEL,MOUNTPOINTS "${disks[@]}" || true
    echo
    die "NVMe disks are in use (mounted). Unmount them and stop any services using them (k3s/containerd). Then rerun from SD/USB."
  fi

  # Extra hard stop if k3s is running (don't even try to unmount/inspect DATA)
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet k3s.service; then
    die "k3s.service is running. ops-e2e must be run from a clean SD/USB boot environment, not a live OurBox node."
  fi

  # Store disks for later (global array)
  PREFLIGHT_NVME_DISKS=("${disks[@]}")
}

nvme_disks() {
  # Returns /dev/nvme0n1 style disk paths (type=disk)
  lsblk -dn -o NAME,TYPE \
    | awk '$2=="disk" && $1 ~ /^nvme[0-9]+n[0-9]+$/ {print "/dev/"$1}'
}

show_nvme_summary() {
  local disks=("$@")
  echo
  echo "NVMe disks detected:"
  echo
  # Show disks and partitions
  lsblk -o NAME,SIZE,MODEL,SERIAL,TYPE,FSTYPE,LABEL,MOUNTPOINTS "${disks[@]}" || true
  echo
}

data_part_by_label() {
  resolve_label OURBOX_DATA
}

parent_disk_of_part() {
  local part="$1"
  echo "/dev/$(lsblk -no PKNAME "${part}")"
}

unmount_anything_on_disk() {
  local disk="$1"
  # Unmount any mounted partitions on this disk (best-effort).
  while read -r name mp; do
    [[ -n "${mp}" ]] || continue
    log "Unmounting ${mp} (/dev/${name})"
    ${SUDO} umount "/dev/${name}" >/dev/null 2>&1 || ${SUDO} umount "${mp}" >/dev/null 2>&1 || true
  done < <(lsblk -nr -o NAME,MOUNTPOINT "${disk}" | awk 'NF==2 && $2!="" {print $1, $2}')
}

require_unmounted_disk() {
  local disk="$1"
  unmount_anything_on_disk "${disk}"

  # If anything is still mounted from that disk, stop now.
  if lsblk -nr -o MOUNTPOINT "${disk}" | awk 'NF && $0 != "" {found=1} END{exit !found}'; then
    echo
    lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS "${disk}" || true
    echo
    die "Could not unmount all partitions on ${disk}. Something is using the disk. Stop services (k3s/containerd) and retry from SD/USB."
  fi
}

DATA_CHECK_MP="/tmp/ourbox-data-check"

cleanup_data_check_mp() {
  if mountpoint -q "${DATA_CHECK_MP}"; then
    ${SUDO} umount "${DATA_CHECK_MP}" >/dev/null 2>&1 || true
  fi
}
trap cleanup_data_check_mp EXIT

inspect_data_partition() {
  local part="$1"

  DATA_HAS_CONTENT=0
  DATA_BOOTSTRAP_DONE_TS=""
  DATA_DEVICE_ID=""

  mkdir -p "${DATA_CHECK_MP}"
  if mountpoint -q "${DATA_CHECK_MP}"; then
    ${SUDO} umount "${DATA_CHECK_MP}" >/dev/null 2>&1 || true
  fi

  # Try a truly non-destructive read-only mount (no journal replay).
  if ! ${SUDO} mount -t ext4 -o ro,noload "${part}" "${DATA_CHECK_MP}" >/dev/null 2>&1; then
    # Fallback: ro mount if noload isn't supported for some reason.
    ${SUDO} mount -t ext4 -o ro "${part}" "${DATA_CHECK_MP}" >/dev/null 2>&1 || return 1
  fi

  # bootstrap marker
  if [[ -f "${DATA_CHECK_MP}/state/bootstrap.done" ]]; then
    DATA_BOOTSTRAP_DONE_TS="$(cat "${DATA_CHECK_MP}/state/bootstrap.done" 2>/dev/null || true)"
  fi

  # optional nice-to-have for operator visibility
  if [[ -f "${DATA_CHECK_MP}/device/device_id" ]]; then
    DATA_DEVICE_ID="$(cat "${DATA_CHECK_MP}/device/device_id" 2>/dev/null || true)"
  fi

  # consider "non-empty" if anything besides lost+found exists at the top level
  local found=""
  found="$(${SUDO} find "${DATA_CHECK_MP}" -mindepth 1 -maxdepth 1 ! -name lost+found -print -quit 2>/dev/null)"
  if [[ -n "${found}" ]]; then
    DATA_HAS_CONTENT=1
  fi

  ${SUDO} umount "${DATA_CHECK_MP}" >/dev/null 2>&1 || true
  return 0
}

reset_data_bootstrap_marker() {
  local part="$1"

  mkdir -p "${DATA_CHECK_MP}"
  if mountpoint -q "${DATA_CHECK_MP}"; then
    ${SUDO} umount "${DATA_CHECK_MP}" >/dev/null 2>&1 || true
  fi

  ${SUDO} mount -t ext4 -o rw "${part}" "${DATA_CHECK_MP}"

  if [[ -f "${DATA_CHECK_MP}/state/bootstrap.done" ]]; then
    ${SUDO} rm -f "${DATA_CHECK_MP}/state/bootstrap.done"
  fi

  sync
  ${SUDO} umount "${DATA_CHECK_MP}" >/dev/null 2>&1 || true

  log "Reset bootstrap marker on DATA: removed /state/bootstrap.done"
}

gate_on_existing_data_state() {
  local dpart="$1"
  local ddisk="$2"

  # Ensure the disk is fully unmounted before inspection.
  require_unmounted_disk "${ddisk}"

  # Defaults
  DATA_HAS_CONTENT=0
  DATA_BOOTSTRAP_DONE_TS=""
  DATA_DEVICE_ID=""

  if ! inspect_data_partition "${dpart}"; then
    die "Could not inspect DATA partition contents (${dpart}). Refusing to proceed (would be unsafe)."
  fi

  # Only gate if there's meaningful content
  if [[ "${DATA_HAS_CONTENT}" -eq 1 ]]; then
    echo
    echo "=================================================================="
    echo "DATA disk is NOT empty"
    echo "=================================================================="
    echo
    echo "DATA partition: ${dpart}"
    echo "DATA disk     : ${ddisk}"
    [[ -n "${DATA_DEVICE_ID}" ]] && echo "device_id     : ${DATA_DEVICE_ID}"
    [[ -n "${DATA_BOOTSTRAP_DONE_TS}" ]] && echo "bootstrap.done: ${DATA_BOOTSTRAP_DONE_TS}"
    echo

    if [[ -n "${DATA_BOOTSTRAP_DONE_TS}" ]]; then
      echo "This DATA disk was previously bootstrapped."
      echo "If you flash a NEW SYSTEM disk and keep this DATA disk as-is:"
      echo "  - ourbox-bootstrap will be skipped"
      echo "  - k3s will remain disabled and the platform will NOT auto-start"
      echo
      echo "Recommended: RESET-BOOTSTRAP (preserves data, re-runs bootstrap on next boot)."
    else
      echo "This DATA disk contains files, but has no bootstrap.done marker."
      echo "Bootstrapping may overwrite or conflict with existing contents."
      echo
      echo "Recommended: ERASE-DATA (fresh start)."
    fi

    echo
    echo "Choose one:"
    echo "  RESET-BOOTSTRAP  (recommended when re-flashing SYSTEM but preserving DATA)"
    echo "  ERASE-DATA       (DESTROYS the entire DATA NVMe disk)"
    echo "  KEEP-DATA        (NOT recommended; expect k3s not to auto-start)"
    echo

    local ans=""
    read -r -p "Type RESET-BOOTSTRAP, ERASE-DATA, or KEEP-DATA: " ans
    case "${ans}" in
      RESET-BOOTSTRAP)
        reset_data_bootstrap_marker "${dpart}"
        ;;
      ERASE-DATA)
        init_data_disk_ext4_labeled "${ddisk}"
        ;;
      KEEP-DATA)
        log "Keeping DATA disk untouched (operator chose KEEP-DATA)."
        log "NOTE: If bootstrap.done exists, k3s will not auto-start after flashing."
        ;;
      *)
        die "invalid choice: ${ans}"
        ;;
    esac
  fi
}

init_data_disk_ext4_labeled() {
  local disk="$1"

  need_cmd parted
  need_cmd mkfs.ext4
  need_cmd partprobe
  need_cmd wipefs
  need_cmd dd
  need_cmd blockdev

  log "About to DESTROY and initialize DATA disk: ${disk}"
  unmount_anything_on_disk "${disk}"

  echo
  show_nvme_summary "${disk}"
  echo "This will erase EVERYTHING on ${disk} and create a single ext4 partition labeled OURBOX_DATA."
  prompt_confirm_exact "ERASE-DATA" "Type ERASE-DATA to continue:"

  # Strong wipe so we start from a known blank state (disk-level, not partition-level).
  if command -v blkdiscard >/dev/null 2>&1; then
    log "blkdiscard (best-effort): ${disk}"
    ${SUDO} blkdiscard -f "${disk}" >/dev/null 2>&1 || true
  fi

  log "wipefs (best-effort): ${disk}"
  ${SUDO} wipefs -a "${disk}" >/dev/null 2>&1 || true

  ZERO_MIB="${ZERO_MIB:-32}"
  log "Zeroing first ${ZERO_MIB}MiB of ${disk}"
  ${SUDO} dd if=/dev/zero of="${disk}" bs=1M count="${ZERO_MIB}" conv=fsync status=progress

  size_bytes="$(${SUDO} blockdev --getsize64 "${disk}")"
  total_mib="$((size_bytes / 1024 / 1024))"
  if (( total_mib > ZERO_MIB )); then
    seek_mib="$((total_mib - ZERO_MIB))"
    log "Zeroing last ${ZERO_MIB}MiB of ${disk}"
    ${SUDO} dd if=/dev/zero of="${disk}" bs=1M count="${ZERO_MIB}" seek="${seek_mib}" conv=fsync status=progress
  fi
  sync

  ${SUDO} parted -s "${disk}" mklabel gpt
  ${SUDO} parted -s "${disk}" mkpart primary ext4 1MiB 100%
  ${SUDO} partprobe "${disk}" || true

  local part="${disk}p1"
  ${SUDO} mkfs.ext4 -F -L OURBOX_DATA "${part}"
  sync

  local label=""
  label="$(${SUDO} blkid -o value -s LABEL "${part}" 2>/dev/null || true)"
  [[ "${label}" == "OURBOX_DATA" ]] || die "mkfs completed but LABEL is not OURBOX_DATA on ${part} (got: ${label:-<empty>})"

  local resolved=""
  resolved="$(resolve_label OURBOX_DATA)"
  [[ -n "${resolved}" ]] || die "DATA label OURBOX_DATA not resolvable after format (udev/blkid issue)"

  # extra safety: ensure it resolves to the disk we just formatted
  if [[ "$(readlink -f "${resolved}")" != "$(readlink -f "${part}")" ]]; then
    die "OURBOX_DATA resolves to ${resolved}, expected ${part}. Refusing (duplicate labels or stale state)."
  fi

  log "DATA disk initialized: ${part} (LABEL=OURBOX_DATA)"
  echo
}

pick_other_disk() {
  local a="$1" b="$2" chosen="$3"
  if [[ "${chosen}" == "${a}" ]]; then
    echo "${b}"
  else
    echo "${a}"
  fi
}

pick_data_disk_if_missing() {
  local disks=("$@")
  local dpart
  dpart="$(data_part_by_label)"
  if [[ -n "${dpart}" ]]; then
    echo ""  # no need to pick
    return 0
  fi

  echo
  echo "No filesystem labeled OURBOX_DATA was found."
  echo "We can initialize one NVMe disk as DATA (ext4, LABEL=OURBOX_DATA)."
  echo "You must choose which NVMe disk becomes DATA."
  echo

  show_nvme_summary "${disks[@]}"

  echo "Choose the DATA disk:"
  echo "  1) ${disks[0]}"
  echo "  2) ${disks[1]}"
  local choice=""
  read -r -p "Enter 1 or 2: " choice
  [[ "${choice}" == "1" || "${choice}" == "2" ]] || die "invalid choice"

  if [[ "${choice}" == "1" ]]; then
    echo "${disks[0]}"
  else
    echo "${disks[1]}"
  fi
}

byid_for_disk() {
  local disk="$1"
  local best=""

  # Prefer nvme-eui.* if present, otherwise first matching by-id symlink.
  for p in /dev/disk/by-id/*; do
    [[ -L "${p}" ]] || continue
    [[ "${p}" == *-part* ]] && continue
    local target
    target="$(readlink -f "${p}" 2>/dev/null || true)"
    [[ "${target}" == "${disk}" ]] || continue

    local base
    base="$(basename "${p}")"
    if [[ "${base}" == nvme-eui.* ]]; then
      echo "${p}"
      return 0
    fi
    [[ -z "${best}" ]] && best="${p}"
  done

  [[ -n "${best}" ]] || return 1
  echo "${best}"
}

newest_img_xz() {
  : "${OURBOX_TARGET:=rpi}"
  local img_glob="${ROOT}/deploy/img-ourbox-matchbox-${OURBOX_TARGET,,}-*.img.xz"
  local img=""
  # shellcheck disable=SC2012,SC2086
  img="$(ls -1t ${img_glob} 2>/dev/null | head -n 1 || true)"
  [[ -n "${img}" && -f "${img}" ]] || die "no ${img_glob} found; build likely failed"

  local base
  base="$(basename "${img}")"
  # We already selected using an OS-only glob:
  #   img-ourbox-matchbox-${OURBOX_TARGET,,}-*.img.xz
  # Do not reject substring "installer" here; valid variant/version names may include it.
  [[ "${base}" == img-ourbox-matchbox-${OURBOX_TARGET,,}-*.img.xz ]] \
    || die "selected image does not match expected OS pattern img-ourbox-matchbox-${OURBOX_TARGET,,}-*.img.xz: ${img}"

  echo "${img}"
}

compute_os_artifact_ref_from_img() {
  local img="$1"
  local base
  base="$(basename "${img}" .img.xz)"
  imgref os "${base}"
}

main() {
  banner

  log "Preflight: checking for legacy naming terms"
  "${ROOT}/tools/check_legacy_terms.sh"

  # Fail fast before any downloads/builds
  preflight_flash_topology_or_die

  # Explicit operator consent before spending hours building and flashing
  prompt_confirm_exact "BUILD-AND-FLASH" \
    "This will build an OS image (can take a long time) and then ERASE a SYSTEM NVMe disk. Type BUILD-AND-FLASH to continue:"

  ensure_not_booted_from_nvme

  log "Ensuring submodules are present"
  (cd "${ROOT}" && git submodule update --init --recursive)

  log "Bootstrapping host dependencies (Podman + BuildKit + basics)"
  "${ROOT}/tools/bootstrap-host.sh"

  # Prefer podman automatically (registry.sh now defaults to sudo podman when needed)
  export DOCKER="${DOCKER:-$(pick_container_cli)}"
  log "Using container CLI: ${DOCKER}"

  log "Fetching airgap artifacts"
  "${ROOT}/tools/fetch-airgap-platform.sh"

  if [[ -f "${ROOT}/artifacts/airgap/manifest.env" ]]; then
    # shellcheck disable=SC1090,SC1091
    source "${ROOT}/artifacts/airgap/manifest.env"
    log "Airgap pins: ARCH=${AIRGAP_PLATFORM_ARCH:-?} K3S_VERSION=${K3S_VERSION:-?}"
  fi

  log "Running build-host loop preflight"
  "${ROOT}/tools/preflight-build-host.sh"

  : "${OURBOX_TARGET:=rpi}"
  : "${OURBOX_VARIANT:=dev}"
  : "${OURBOX_VERSION:=dev}"

  log "Building OS image (OURBOX_VARIANT=${OURBOX_VARIANT} OURBOX_VERSION=${OURBOX_VERSION})"
  OURBOX_TARGET="${OURBOX_TARGET}" OURBOX_VARIANT="${OURBOX_VARIANT}" OURBOX_VERSION="${OURBOX_VERSION}" "${ROOT}/tools/build-image.sh"

  local img_xz
  img_xz="$(newest_img_xz)"
  log "Built image: ${img_xz}"
  xz -t "${img_xz}"

  local flash_img="${img_xz}"

  if [[ "${REGISTRY_ROUNDTRIP}" == "1" ]]; then
    log "Registry round-trip requested: publish + pull (no manual copy/paste)"
    OURBOX_TARGET="${OURBOX_TARGET}" "${ROOT}/tools/publish-os-artifact.sh" "${ROOT}/deploy"
    rm -rf "${ROOT}/deploy-from-registry" || true
    "${ROOT}/tools/pull-os-artifact.sh" --latest "${ROOT}/deploy-from-registry"
    xz -t "${ROOT}/deploy-from-registry/os.img.xz"
    flash_img="${ROOT}/deploy-from-registry/os.img.xz"
    log "Using pulled artifact for flashing: ${flash_img}"
  fi

  # NVMe safety: exactly two NVMe disks (reuse preflight discovery if present)
  local disks=()
  if [[ ${#PREFLIGHT_NVME_DISKS[@]} -eq 2 ]]; then
    disks=("${PREFLIGHT_NVME_DISKS[@]}")
  else
    mapfile -t disks < <(nvme_disks)
  fi
  if [[ "${#disks[@]}" -ne 2 ]]; then
    echo
    lsblk -o NAME,SIZE,MODEL,SERIAL,TYPE,FSTYPE,LABEL,MOUNTPOINTS || true
    echo
    die "expected exactly 2 NVMe disks; found ${#disks[@]}. Disconnect extra NVMe devices and retry."
  fi

  show_nvme_summary "${disks[@]}"

  # Ensure DATA disk exists (or initialize it)
  local dpart ddisk data_disk_choice
  dpart="$(data_part_by_label)"
  if [[ -z "${dpart}" ]]; then
    data_disk_choice="$(pick_data_disk_if_missing "${disks[@]}")"
    init_data_disk_ext4_labeled "${data_disk_choice}"
    dpart="$(data_part_by_label)"
    [[ -n "${dpart}" ]] || die "failed to create OURBOX_DATA label"
  fi

  ddisk="$(parent_disk_of_part "${dpart}")"
  if [[ "${ddisk}" != /dev/nvme* ]]; then
    die "OURBOX_DATA label is not on an NVMe disk (${ddisk}); refusing for safety"
  fi
  local fstype
  fstype="$(lsblk -no FSTYPE "${dpart}" 2>/dev/null || true)"
  if [[ "${fstype}" != "ext4" ]]; then
    die "DATA disk ${dpart} has LABEL=OURBOX_DATA but FSTYPE=${fstype:-unknown}. Contract requires ext4."
  fi

  # DATA disk sanity: if it contains prior state, force operator decision before flashing.
  gate_on_existing_data_state "${dpart}" "${ddisk}"

  # If ERASE-DATA occurred, the label/partition may have changed; re-resolve for correctness.
  dpart="$(data_part_by_label)"
  [[ -n "${dpart}" ]] || die "DATA disk LABEL=OURBOX_DATA not resolvable after DATA disk action (udev/blkid not updated). Refusing to continue to protect DATA disk."
  ddisk="$(parent_disk_of_part "${dpart}")"
  if [[ "${ddisk}" != /dev/nvme* ]]; then
    die "OURBOX_DATA label is not on an NVMe disk (${ddisk}); refusing for safety"
  fi
  fstype="$(lsblk -no FSTYPE "${dpart}" 2>/dev/null || true)"
  if [[ "${fstype}" != "ext4" ]]; then
    die "DATA disk ${dpart} has LABEL=OURBOX_DATA but FSTYPE=${fstype:-unknown}. Contract requires ext4."
  fi

  # SYSTEM disk is the other NVMe disk
  local sys_disk
  sys_disk="$(pick_other_disk "${disks[0]}" "${disks[1]}" "${ddisk}")"

  echo
  log "Disk selection:"
  log "  DATA   : ${ddisk} (partition ${dpart} LABEL=OURBOX_DATA)"
  log "  SYSTEM : ${sys_disk} (will be wiped)"

  echo
  show_nvme_summary "${ddisk}" "${sys_disk}"

  echo "WARNING: This will ERASE and overwrite the SYSTEM disk: ${sys_disk}"
  prompt_confirm_exact "${sys_disk}" "To confirm, type the SYSTEM disk path exactly:"

  # Prefer by-id for flashing (flash script accepts raw NVMe too, but by-id is best)
  local sys_byid=""
  if sys_byid="$(byid_for_disk "${sys_disk}")"; then
    log "SYSTEM by-id: ${sys_byid}"
  else
    log "WARNING: could not find /dev/disk/by-id symlink for ${sys_disk}; flashing will use the raw device path"
    sys_byid="${sys_disk}"
  fi

  # Unmount anything on SYSTEM and fail if still busy
  require_unmounted_disk "${sys_disk}"

  log "Flashing SYSTEM NVMe"
  "${ROOT}/tools/flash-system-nvme.sh" "${flash_img}" "${sys_byid}" || die "flash failed; refusing to continue"

  echo
  local default_user="${SUDO_USER:-$(whoami)}"
  local new_user
  new_user="$(prompt_nonempty "Username for first boot" "${default_user}")"

  log "Writing userconf.txt to boot partition (will prompt for password)"
  "${ROOT}/tools/preboot-userconf.sh" "${sys_disk}" "${new_user}"

  echo
  echo "DONE."
  echo
  echo "Next steps:"
  echo "  - Power down"
  echo "  - Remove SD/USB (or fix boot order)"
  echo "  - Boot from NVMe SYSTEM"
  echo
  echo "After first boot, verify:"
  echo "  findmnt /"
  echo "  findmnt /var/lib/ourbox"
  echo "  systemctl status k3s --no-pager || true"
  echo "  sudo /usr/local/bin/k3s kubectl get pods -A"
  echo "  curl -sSf http://127.0.0.1:30080 | head"
  echo
}

main
