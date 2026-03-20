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

# shellcheck disable=SC2034  # consumed by sourced storage-flow helper
MATCHBOX_SUDO="${SUDO}"
# shellcheck disable=SC2034  # consumed by sourced storage-flow helper
MATCHBOX_DATA_CHECK_MP="/tmp/ourbox-data-check"

# shellcheck disable=SC1091
source "${ROOT}/tools/matchbox-storage-flow.sh"

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
  mapfile -t disks < <(matchbox_nvme_disks)
  if [[ "${#disks[@]}" -ne 2 ]]; then
    echo
    lsblk -o NAME,SIZE,MODEL,SERIAL,TYPE,FSTYPE,LABEL,MOUNTPOINTS || true
    echo
    die "This workflow requires exactly 2 NVMe disks (DATA+SYSTEM). Found ${#disks[@]}. Run on Matchbox hardware with dual NVMe."
  fi

  matchbox_show_nvme_summary "${disks[@]}"

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
trap matchbox_cleanup_data_check_mp EXIT

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

resolve_default_airgap_platform_ref() {
  local repo="${OURBOX_AIRGAP_PLATFORM_REPO:-ghcr.io/techofourown/sw-ourbox-os/airgap-platform}"
  local tag="${OURBOX_AIRGAP_PLATFORM_TAG:-beta-arm64}"
  local digest=""

  if [[ -n "${OURBOX_AIRGAP_PLATFORM_REF:-}" ]]; then
    log "Using preselected airgap platform ref: ${OURBOX_AIRGAP_PLATFORM_REF}"
    return 0
  fi

  need_cmd oras
  digest="$(oras resolve "${repo}:${tag}")"
  [[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]] || die "oras resolve returned an invalid airgap digest for ${repo}:${tag}: ${digest:-missing}"
  export OURBOX_AIRGAP_PLATFORM_REF="${repo}@${digest}"
  log "Resolved airgap platform ref for ops-e2e: ${OURBOX_AIRGAP_PLATFORM_REF}"
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

  resolve_default_airgap_platform_ref

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
    mapfile -t disks < <(matchbox_nvme_disks)
  fi
  if [[ "${#disks[@]}" -ne 2 ]]; then
    echo
    lsblk -o NAME,SIZE,MODEL,SERIAL,TYPE,FSTYPE,LABEL,MOUNTPOINTS || true
    echo
    die "expected exactly 2 NVMe disks; found ${#disks[@]}. Disconnect extra NVMe devices and retry."
  fi

  matchbox_prepare_storage_layout "${disks[@]}"
  local dpart ddisk sys_disk
  dpart="${MATCHBOX_DATA_PART}"
  ddisk="${MATCHBOX_DATA_DISK}"
  sys_disk="${MATCHBOX_SYSTEM_DISK}"

  echo
  log "Disk selection:"
  log "  DATA   : ${ddisk} (partition ${dpart} LABEL=OURBOX_DATA)"
  log "  SYSTEM : ${sys_disk} (will be wiped)"

  echo
  matchbox_show_nvme_summary "${ddisk}" "${sys_disk}"

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
  matchbox_require_unmounted_disk "${sys_disk}"

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
