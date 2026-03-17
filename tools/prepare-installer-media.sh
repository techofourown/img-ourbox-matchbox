#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tools/lib.sh"

UNIFIED_INSTALLER_ROOT="${OURBOX_INSTALLER_REPO_ROOT:-${ROOT}/../sw-ourbox-installer}"
UNIFIED_PREPARE="${UNIFIED_INSTALLER_ROOT}/tools/prepare-installer-media.sh"

usage() {
  cat <<EOF
Usage: $0 [sw-ourbox-installer options]

Matchbox mission media is now composed by the unified host-side installer repo:
  sw-ourbox-installer

This wrapper delegates to:
  ${UNIFIED_PREPARE}

Example:
  $0 --os-channel stable --output-dir /tmp/matchbox-media

Authoritative target selection, artifact resolution, cache reuse, and media
composition now live in sw-ourbox-installer. This repo only owns the Matchbox
target substrate, runtime install logic, and media adapter.
EOF
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

[[ -x "${UNIFIED_PREPARE}" ]] || die "Matchbox mission media is now composed by sw-ourbox-installer, but ${UNIFIED_PREPARE} was not found. Check out sw-ourbox-installer and run its prepare-installer-media.sh with --target matchbox."

exec "${UNIFIED_PREPARE}" --target matchbox "$@"
