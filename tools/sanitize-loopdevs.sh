#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tools/lib.sh"

SUDO=""
if [[ ${EUID} -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || die "sanitize-loopdevs requires root or sudo"
  SUDO="sudo -E"
fi

need_cmd losetup
need_cmd awk
need_cmd grep
need_cmd sort
need_cmd xargs

# Best-effort: ensure loop module is loaded (does nothing if not needed / not available)
if command -v modprobe >/dev/null 2>&1; then
  ${SUDO} modprobe loop >/dev/null 2>&1 || true
fi

log "Loop preflight: checking for stale loop devices (lost/deleted)"

# Extract /dev/loopN from losetup output lines containing (lost) or (deleted)
stale="$(
  ${SUDO} losetup -a 2>/dev/null \
    | awk '/\((lost|deleted)\)/{
        dev=$1; sub(/:.*/, "", dev); print dev
      }' \
    | sort -u
)"

if [[ -n "${stale}" ]]; then
  log "Found stale loop devices (safe to detach):"
  # Print the exact losetup lines for operator debugging
  ${SUDO} losetup -a 2>/dev/null | grep -E '\((lost|deleted)\)' || true

  # Detach each stale loop device
  # shellcheck disable=SC2086
  echo "${stale}" | xargs -r -n1 ${SUDO} losetup -d || true
fi

if command -v udevadm >/dev/null 2>&1; then
  ${SUDO} udevadm settle >/dev/null 2>&1 || true
fi

# Verify clean state
if ${SUDO} losetup -a 2>/dev/null | grep -Eq '\((lost|deleted)\)'; then
  log "ERROR: stale loop devices remain after attempted cleanup:"
  ${SUDO} losetup -a 2>/dev/null | grep -E '\((lost|deleted)\)' || true
  die "Loop devices still in lost/deleted state; refusing to run pi-gen export-image"
fi

log "OK: loop device state is clean"
