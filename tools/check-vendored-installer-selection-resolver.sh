#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tools/lib.sh"
# shellcheck disable=SC1091
source "${ROOT}/tools/installer-selection-resolver.upstream.env"

need_cmd curl
need_cmd diff

VENDORED_RESOLVER="${ROOT}/tools/installer-selection-resolver.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
UPSTREAM_RESOLVER="${TMP}/installer-selection-resolver.sh"
UPSTREAM_URL="https://raw.githubusercontent.com/${SW_OURBOX_OS_REPO}/${SW_OURBOX_OS_REVISION}/${SW_OURBOX_OS_PATH}"

log "Fetching upstream installer-selection resolver: ${UPSTREAM_URL}"
curl -fsSL "${UPSTREAM_URL}" -o "${UPSTREAM_RESOLVER}" \
  || die "failed to fetch upstream installer-selection resolver"

diff -u "${UPSTREAM_RESOLVER}" "${VENDORED_RESOLVER}" \
  || die "vendored installer-selection resolver drifted from ${SW_OURBOX_OS_REPO}@${SW_OURBOX_OS_REVISION}"

log "Vendored installer-selection resolver matches ${SW_OURBOX_OS_REPO}@${SW_OURBOX_OS_REVISION}"
