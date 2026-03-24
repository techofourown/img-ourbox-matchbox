#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tools/lib.sh"

need_cmd tar
need_cmd find
need_cmd grep

ref_repo_base() {
  local ref="$1"
  local tail="${ref##*/}"

  if [[ "${ref}" == *@* ]]; then
    printf '%s\n' "${ref%%@*}"
    return 0
  fi

  if [[ "${tail}" == *:* ]]; then
    printf '%s\n' "${ref%:*}"
  else
    printf '%s\n' "${ref}"
  fi
}

resolve_selected_bundle_identity() {
  local digest=""
  local pinned_ref=""

  if [[ "${REF}" =~ @sha256:[0-9a-f]{64}$ ]]; then
    digest="${REF##*@}"
    pinned_ref="${REF}"
  else
    digest="$(grep -Eo 'sha256:[0-9a-f]{64}' "${META_DIR}/oras.pull.log" | tail -n1 || true)"
    [[ -n "${digest}" ]] || die "unable to determine fetched ourbox-substrate digest from ${META_DIR}/oras.pull.log"
    pinned_ref="$(ref_repo_base "${REF}")@${digest}"
  fi

  printf '%s\n%s\n' "${pinned_ref}" "${digest}"
}

write_selected_bundle_metadata() {
  local expected_contract_digest="$1"
  local selected_pinned_ref="$2"
  local selected_digest="$3"
  local manifest="${OUT}/manifest.env"
  local OURBOX_SUBSTRATE_SOURCE=""
  local OURBOX_SUBSTRATE_REVISION=""
  local OURBOX_SUBSTRATE_VERSION=""
  local OURBOX_SUBSTRATE_CREATED=""
  local OURBOX_PLATFORM_CONTRACT_REF=""
  local OURBOX_PLATFORM_CONTRACT_DIGEST=""
  local OURBOX_SUBSTRATE_ARCH=""
  local K3S_VERSION=""
  local OURBOX_PLATFORM_PROFILE=""
  local OURBOX_PLATFORM_IMAGES_LOCK_SHA256=""

  [[ -f "${manifest}" ]] || die "missing manifest.env in ${OUT}"
  # shellcheck disable=SC1090
  source "${manifest}"

  [[ "${OURBOX_SUBSTRATE_ARCH}" == "arm64" ]] || die "ourbox-substrate arch mismatch: expected arm64, got ${OURBOX_SUBSTRATE_ARCH:-unknown}"
  [[ "${OURBOX_PLATFORM_CONTRACT_DIGEST}" == "${expected_contract_digest}" ]] || die "ourbox-substrate contract digest mismatch: expected ${expected_contract_digest}, got ${OURBOX_PLATFORM_CONTRACT_DIGEST:-unknown}"
  [[ -n "${OURBOX_SUBSTRATE_SOURCE}" ]] || die "ourbox-substrate manifest missing OURBOX_SUBSTRATE_SOURCE"
  [[ -n "${OURBOX_SUBSTRATE_REVISION}" ]] || die "ourbox-substrate manifest missing OURBOX_SUBSTRATE_REVISION"
  [[ -n "${OURBOX_SUBSTRATE_VERSION}" ]] || die "ourbox-substrate manifest missing OURBOX_SUBSTRATE_VERSION"
  [[ -n "${OURBOX_SUBSTRATE_CREATED}" ]] || die "ourbox-substrate manifest missing OURBOX_SUBSTRATE_CREATED"
  [[ -n "${K3S_VERSION}" ]] || die "ourbox-substrate manifest missing K3S_VERSION"
  [[ -n "${OURBOX_PLATFORM_PROFILE}" ]] || die "ourbox-substrate manifest missing OURBOX_PLATFORM_PROFILE"
  [[ "${OURBOX_PLATFORM_IMAGES_LOCK_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die "ourbox-substrate manifest carries invalid OURBOX_PLATFORM_IMAGES_LOCK_SHA256"

  cat > "${OUT}/selected-bundle.env" <<EOF
OURBOX_SUBSTRATE_REF=${selected_pinned_ref}
OURBOX_SUBSTRATE_DIGEST=${selected_digest}
OURBOX_SUBSTRATE_SOURCE=${OURBOX_SUBSTRATE_SOURCE}
OURBOX_SUBSTRATE_REVISION=${OURBOX_SUBSTRATE_REVISION}
OURBOX_SUBSTRATE_VERSION=${OURBOX_SUBSTRATE_VERSION}
OURBOX_SUBSTRATE_CREATED=${OURBOX_SUBSTRATE_CREATED}
OURBOX_SUBSTRATE_ARCH=${OURBOX_SUBSTRATE_ARCH}
OURBOX_SUBSTRATE_PROFILE=${OURBOX_PLATFORM_PROFILE}
OURBOX_SUBSTRATE_K3S_VERSION=${K3S_VERSION}
OURBOX_SUBSTRATE_IMAGES_LOCK_SHA256=${OURBOX_PLATFORM_IMAGES_LOCK_SHA256}
OURBOX_PLATFORM_CONTRACT_REF=${OURBOX_PLATFORM_CONTRACT_REF}
OURBOX_PLATFORM_CONTRACT_DIGEST=${OURBOX_PLATFORM_CONTRACT_DIGEST}
EOF
}

# Resolve airgap platform ref.
# Callers must resolve channel intent at workflow/build start and pass the
# selected immutable ref explicitly.
[[ -n "${OURBOX_SUBSTRATE_REF:-}" ]] || die \
  "OURBOX_SUBSTRATE_REF is required.
Resolve the upstream ourbox-substrate channel at workflow/build start and pass
the resulting digest-pinned ref in the environment."
REF="${OURBOX_SUBSTRATE_REF}"

need_cmd oras

OUT="${ROOT}/artifacts/airgap"
PULL_DIR="${ROOT}/artifacts/.ourbox-substrate-pull"
META_DIR="${ROOT}/artifacts/.ourbox-substrate-meta"

log "Using ourbox-substrate ref: ${REF}"

# Enforce digest pinning in official builds.
# Nightly: warn (non-reproducible but permitted for integration coverage).
# Official candidate/release lanes: hard fail.
if [[ -n "${GITHUB_ACTIONS:-}" ]] && [[ "${REF}" != *"@sha256:"* ]]; then
  if [[ "${OURBOX_REQUIRE_PINNED_OFFICIAL_INPUTS:-0}" == "1" ]] || [[ "${GITHUB_WORKFLOW:-}" =~ [Rr]elease ]]; then
    die "OURBOX_SUBSTRATE_REF '${REF}' is not digest-pinned.
  Official candidate/release builds require @sha256: refs to ensure reproducibility.
  Resolve the upstream channel before calling fetch-ourbox-substrate.sh and pass
  the pinned ref via OURBOX_SUBSTRATE_REF."
  elif [[ "${GITHUB_WORKFLOW:-}" =~ [Nn]ightly ]]; then
    log "WARNING: OURBOX_SUBSTRATE_REF is not digest-pinned — nightly build will not be reproducible"
    log "  Resolve the upstream channel before calling fetch-ourbox-substrate.sh"
  fi
fi

# In CI, skip the interactive confirmation and auto-remove stale artifacts.
# Locally, prompt before removing existing artifacts.
if [[ -d "${OUT}" ]] && find "${OUT}" -mindepth 1 -print -quit >/dev/null 2>&1; then
  if [[ -n "${GITHUB_ACTIONS:-}" || "${CI:-}" == "1" ]]; then
    log "CI mode: removing existing artifacts in ${OUT}"
    rm -rf "${OUT}" || die "Failed to remove ${OUT}"
  else
    log "ERROR: Existing artifacts detected in ${OUT} (refusing to overwrite)"
    find "${OUT}" -maxdepth 2 -type f -print | sed 's/^/  /'
    echo
    log "You can remove them manually, or allow this script to remove them."
    read -r -p "Type REMOVE to delete ${OUT} and continue, or anything else to abort: " confirm
    if [[ "${confirm}" != "REMOVE" ]]; then
      die "Fetch aborted; existing artifacts not removed"
    fi

    log "WARNING: About to remove ${OUT}"
    if [[ -w "${OUT}" ]]; then
      rm -rf "${OUT}" || die "Failed to remove ${OUT}"
    else
      need_cmd sudo
      sudo rm -rf "${OUT}" || die "Failed to remove ${OUT} (sudo)"
    fi
  fi
fi

rm -rf "${PULL_DIR}" "${META_DIR}"
mkdir -p "${PULL_DIR}" "${META_DIR}" "${OUT}"

log "Pulling ourbox-substrate bundle (arm64)"
oras pull "${REF}" -o "${PULL_DIR}" | tee "${META_DIR}/oras.pull.log"

TARBALL="${PULL_DIR}/dist/ourbox-substrate.tar.gz"
[[ -f "${TARBALL}" ]] || {
  echo "Expected ${TARBALL} not found. Pulled files:" >&2
  find "${PULL_DIR}" -maxdepth 4 -type f -print >&2 || true
  exit 1
}

log "Extracting bundle into ${OUT}"
tar -xzf "${TARBALL}" -C "${OUT}"

# Basic validation
[[ -x "${OUT}/k3s/k3s" ]] || die "Missing k3s binary in ${OUT}/k3s/k3s"
[[ -f "${OUT}/manifest.env" ]] || die "Missing manifest.env in ${OUT}"

shopt -s nullglob
k3s_tars=("${OUT}/k3s/k3s-airgap-images-"*.tar)
platform_tars=("${OUT}/platform/images/"*.tar)
shopt -u nullglob

(( ${#k3s_tars[@]} > 0 )) || die "No k3s airgap image tar found in ${OUT}/k3s"
(( ${#platform_tars[@]} > 0 )) || die "No platform image tars found in ${OUT}/platform/images"

log "Artifacts created:"
ls -lah "${OUT}/k3s" "${OUT}/platform/images" "${OUT}/manifest.env"

log "Deriving platform contract ref from substrate bundle manifest"
BUNDLE_CONTRACT_REF="$(grep '^OURBOX_PLATFORM_CONTRACT_REF=' "${OUT}/manifest.env" | cut -d= -f2- | tr -d '\r')"
[[ -n "${BUNDLE_CONTRACT_REF}" ]] || die "OURBOX_PLATFORM_CONTRACT_REF not found in substrate bundle manifest: ${OUT}/manifest.env"
[[ "${BUNDLE_CONTRACT_REF}" =~ @sha256:[0-9a-f]{64}$ ]] || die "OURBOX_PLATFORM_CONTRACT_REF in bundle manifest is not digest-pinned: ${BUNDLE_CONTRACT_REF}"
if [[ -n "${OURBOX_PLATFORM_CONTRACT_REF:-}" ]] && [[ "${OURBOX_PLATFORM_CONTRACT_REF}" != "${BUNDLE_CONTRACT_REF}" ]]; then
  die "requested platform contract ref does not match the selected substrate bundle.
  requested: ${OURBOX_PLATFORM_CONTRACT_REF}
  bundle:    ${BUNDLE_CONTRACT_REF}"
fi
export OURBOX_PLATFORM_CONTRACT_REF="${BUNDLE_CONTRACT_REF}"

log "Fetching pinned platform contract (OCI artifact)"
"${ROOT}/tools/fetch-platform-contract.sh"

CONTRACT_DIGEST_FILE="${ROOT}/artifacts/platform-contract/extracted/platform-contract/contract.digest"
[[ -f "${CONTRACT_DIGEST_FILE}" ]] || die "platform contract digest file missing after fetch: ${CONTRACT_DIGEST_FILE}"
EXPECTED_CONTRACT_DIGEST="$(cat "${CONTRACT_DIGEST_FILE}")"
[[ "${EXPECTED_CONTRACT_DIGEST}" =~ ^sha256:[0-9a-f]{64}$ ]] || die "platform contract digest is invalid: ${EXPECTED_CONTRACT_DIGEST}"

mapfile -t bundle_identity < <(resolve_selected_bundle_identity)
SELECTED_AIRGAP_PINNED_REF="${bundle_identity[0]:-}"
SELECTED_AIRGAP_DIGEST="${bundle_identity[1]:-}"
[[ -n "${SELECTED_AIRGAP_PINNED_REF}" ]] || die "selected airgap pinned ref was not resolved"
[[ "${SELECTED_AIRGAP_DIGEST}" =~ ^sha256:[0-9a-f]{64}$ ]] || die "selected airgap digest is invalid: ${SELECTED_AIRGAP_DIGEST:-missing}"

write_selected_bundle_metadata "${EXPECTED_CONTRACT_DIGEST}" "${SELECTED_AIRGAP_PINNED_REF}" "${SELECTED_AIRGAP_DIGEST}"
log "Selected baked substrate bundle recorded at ${OUT}/selected-bundle.env"

log "Syncing pinned platform contract into pi-gen stage files"
"${ROOT}/tools/sync-platform-contract-into-pigen.sh"
