#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tools/lib.sh"

# Resolve platform contract ref.
# Priority: OURBOX_PLATFORM_CONTRACT_REF env var > release/official-inputs.env
if [[ -n "${OURBOX_PLATFORM_CONTRACT_REF:-}" ]]; then
  REF="${OURBOX_PLATFORM_CONTRACT_REF}"
else
  INPUTS_ENV="${ROOT}/release/official-inputs.env"
  [[ -f "${INPUTS_ENV}" ]] || die "missing ${INPUTS_ENV}; Matchbox platform fetch requires release/official-inputs.env or OURBOX_PLATFORM_CONTRACT_REF"
  # shellcheck disable=SC1090
  source "${INPUTS_ENV}"
  [[ -n "${PLATFORM_CONTRACT_REF:-}" ]] || die "PLATFORM_CONTRACT_REF not set in ${INPUTS_ENV}"
  REF="${PLATFORM_CONTRACT_REF}"
fi

need_cmd oras

OUT_BASE="${ROOT}/artifacts/platform-contract"
PULL_DIR="${OUT_BASE}/pull"
EXTRACT_DIR="${OUT_BASE}/extracted"
META_DIR="${OUT_BASE}/meta"

rm -rf "${PULL_DIR}" "${EXTRACT_DIR}" "${META_DIR}"
mkdir -p "${PULL_DIR}" "${EXTRACT_DIR}" "${META_DIR}"

log "Pulling platform contract:"
log "  ${REF}"

if [[ -n "${GITHUB_ACTIONS:-}" ]] && [[ "${REF}" != *"@sha256:"* ]]; then
  if [[ "${OURBOX_REQUIRE_PINNED_OFFICIAL_INPUTS:-0}" == "1" ]] || [[ "${GITHUB_WORKFLOW:-}" =~ [Rr]elease ]]; then
    die "PLATFORM_CONTRACT_REF '${REF}' is not digest-pinned.
  Official candidate/release builds require @sha256: refs to ensure reproducibility.
  Update the approved upstream snapshot in sw-ourbox-os instead of editing release/official-inputs.env by hand."
  elif [[ "${GITHUB_WORKFLOW:-}" =~ [Nn]ightly ]]; then
    log "WARNING: PLATFORM_CONTRACT_REF is not digest-pinned — nightly build will not be reproducible"
    log "  Update the approved upstream snapshot in sw-ourbox-os once the next release is approved"
  fi
fi

RESOLVED_DIGEST=""
if [[ "${REF}" =~ @sha256:[0-9a-f]{64}$ ]]; then
  RESOLVED_DIGEST="${REF##*@}"
else
  log "Resolving digest for ${REF}"
  set +e
  RESOLVED_DIGEST="$(oras resolve "${REF}" 2>/dev/null)"
  resolve_status=$?
  set -e
  if [[ "${resolve_status}" -ne 0 || ! "${RESOLVED_DIGEST}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    log "WARNING: oras resolve failed; digest will not be captured"
    RESOLVED_DIGEST=""
  else
    log "Resolved: ${RESOLVED_DIGEST}"
  fi
fi

PULL_REF="${REF}"
if [[ -n "${RESOLVED_DIGEST}" ]] && [[ "${REF}" != *"@sha256:"* ]]; then
  repo_prefix="${REF%/*}"
  ref_leaf="${REF##*/}"
  repo_leaf="${ref_leaf%%:*}"
  if [[ "${repo_leaf}" != "${ref_leaf}" ]]; then
    PULL_REF="${repo_prefix}/${repo_leaf}@${RESOLVED_DIGEST}"
    log "Pulling by resolved digest: ${PULL_REF}"
  else
    log "WARNING: could not derive immutable pull ref from ${REF}; pulling original ref"
  fi
fi

oras pull "${PULL_REF}" -o "${PULL_DIR}" | tee "${META_DIR}/oras.pull.log"

TARBALL="${PULL_DIR}/dist/platform-contract.tar.gz"
if [[ ! -f "${TARBALL}" ]]; then
  echo "Expected ${TARBALL} not found. Pulled files:" >&2
  find "${PULL_DIR}" -maxdepth 4 -type f -print >&2 || true
  exit 1
fi

tar -xzf "${TARBALL}" -C "${EXTRACT_DIR}"

[[ -f "${EXTRACT_DIR}/platform-contract/contract.env" ]] || {
  echo "Missing platform-contract/contract.env in extracted payload" >&2
  exit 1
}

"${ROOT}/tools/validate-platform-contract-shape.sh" "${EXTRACT_DIR}/platform-contract"

if [[ -n "${RESOLVED_DIGEST}" ]]; then
  printf '%s\n' "${RESOLVED_DIGEST}" > "${EXTRACT_DIR}/platform-contract/contract.digest"
  log "Digest recorded: ${RESOLVED_DIGEST}"
else
  log "WARNING: no digest captured; contract.digest will not be written"
fi

log "OK: extracted to ${EXTRACT_DIR}/platform-contract"
