#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tools/lib.sh"

need_cmd oras
: "${OS_REGISTRY_USERNAME:=}"
: "${OS_REGISTRY_PASSWORD:=}"
need_cmd sha256sum
: "${OS_REGISTRY_USERNAME:=}"
: "${OS_REGISTRY_PASSWORD:=}"

maybe_login() {
  if [[ -n "${OS_REGISTRY_USERNAME}" ]]; then
    local registry="${REF%%/*}"
    log "Logging into ${registry} for pull"
    oras login "${registry}" -u "${OS_REGISTRY_USERNAME}" --password "${OS_REGISTRY_PASSWORD:-}"
  fi
}

if [[ "${1:-}" == "--latest" ]]; then
  shift
  OUTDIR="${1:-deploy-from-registry}"
  REF_FILE="${ROOT}/deploy/os-artifact.ref"
  [[ -f "${REF_FILE}" ]] || die "${REF_FILE} not found. Run ./tools/publish-os-artifact.sh deploy first, or pass IMAGE_REF explicitly."
  REF="$(cat "${REF_FILE}")"
else
  REF="${1:-}"
  OUTDIR="${2:-deploy-from-registry}"
  [[ -n "${REF}" ]] || die "Usage: $0 IMAGE_REF [OUTDIR]  or  $0 --latest [OUTDIR]"
fi

mkdir -p "${OUTDIR}"

log ">> Pull: ${REF}"
maybe_login
oras pull "${REF}" -o "${OUTDIR}"

if [[ ! -f "${OUTDIR}/os.img.xz" ]]; then
  die "oras pull succeeded but ${OUTDIR}/os.img.xz missing"
fi

if [[ -f "${OUTDIR}/os.img.xz.sha256" ]]; then
  expected="$(awk 'NF>=1 {print $1; exit}' "${OUTDIR}/os.img.xz.sha256")"
  actual="$(sha256sum "${OUTDIR}/os.img.xz" | awk '{print $1}')"
  [[ "${expected}" == "${actual}" ]] || die "sha mismatch (expected ${expected}, got ${actual})"
  log "sha256 verified: ${actual}"
fi

log "DONE: extracted artifact files:"
ls -lah "${OUTDIR}"
