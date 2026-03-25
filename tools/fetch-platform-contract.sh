#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tools/lib.sh"

# Resolve platform contract ref.
# Callers must resolve channel intent at workflow/build start and pass the
# selected immutable ref explicitly.
[[ -n "${OURBOX_PLATFORM_CONTRACT_REF:-}" ]] || die \
  "OURBOX_PLATFORM_CONTRACT_REF is required.
Resolve the upstream platform-contract channel at workflow/build start and pass
the resulting digest-pinned ref in the environment."
REF="${OURBOX_PLATFORM_CONTRACT_REF}"

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
  Resolve the upstream channel before calling fetch-platform-contract.sh and pass
  the pinned ref via OURBOX_PLATFORM_CONTRACT_REF."
  elif [[ "${GITHUB_WORKFLOW:-}" =~ [Nn]ightly ]]; then
    log "WARNING: PLATFORM_CONTRACT_REF is not digest-pinned — nightly build will not be reproducible"
    log "  Resolve the upstream channel before calling fetch-platform-contract.sh"
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

"${ROOT}/tools/validate-platform-contract-shape.sh" "${EXTRACT_DIR}/platform-contract"

log "OK: extracted to ${EXTRACT_DIR}/platform-contract"
