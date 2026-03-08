#!/usr/bin/env bash
# Official OS artifact promotion wrapper.
# Re-tags an already-published immutable artifact into a promoted channel.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tools/lib.sh"
# shellcheck disable=SC1091
source "${ROOT}/release/official-artifacts.env"

need_cmd oras
need_cmd git
need_cmd awk
need_cmd date

PROMOTION_CONTEXT="${1:?Usage: promote-os-artifact-official.sh stable|exp-labs}"
DEPLOY_DIR="${ROOT}/deploy"
mkdir -p "${DEPLOY_DIR}"

resolve_source_commit() {
  local release_ref="$1"
  local commit subject

  commit="$(git -C "${ROOT}" rev-parse "${release_ref}^{commit}" 2>/dev/null)" \
    || die "Unable to resolve commit for release ref ${release_ref}"
  subject="$(git -C "${ROOT}" log -1 --format=%s "${commit}" 2>/dev/null || true)"

  if [[ "${subject}" == chore\(release\):* ]]; then
    git -C "${ROOT}" rev-parse "${commit}^" 2>/dev/null \
      || die "Unable to resolve source commit behind release commit ${commit}"
  else
    printf '%s\n' "${commit}"
  fi
}

wait_for_source_digest() {
  local source_ref="$1"
  local timeout="${PROMOTE_WAIT_TIMEOUT_SECONDS:-14400}"
  local interval="${PROMOTE_WAIT_INTERVAL_SECONDS:-30}"
  local elapsed=0
  local digest=""

  while (( elapsed <= timeout )); do
    digest="$(oras resolve "${source_ref}" 2>/dev/null || true)"
    if [[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
      printf '%s\n' "${digest}"
      return 0
    fi
    if (( elapsed == 0 )); then
      log "Waiting for promotable source artifact: ${source_ref}"
    fi
    sleep "${interval}"
    elapsed=$((elapsed + interval))
  done

  return 1
}

update_catalog() {
  local channel_tag="$1" immutable_tag="$2" immutable_digest="$3"
  local tmp_dir="$4"
  local catalog_dir="${tmp_dir}/catalog"
  local catalog_file="${catalog_dir}/catalog.tsv"
  local catalog_ref="${OFFICIAL_OS_REPO}:${OFFICIAL_OS_CATALOG_TAG}"
  local pinned_ref="${OFFICIAL_OS_REPO}@${immutable_digest}"

  rm -rf "${catalog_dir}"
  mkdir -p "${catalog_dir}"

  if oras pull "${catalog_ref}" -o "${catalog_dir}" >/dev/null 2>&1; then
    log "Catalog pulled: ${catalog_ref}"
  else
    printf '%s\n' "${CATALOG_HEADER}" > "${catalog_file}"
  fi

  [[ -f "${catalog_file}" ]] || printf '%s\n' "${CATALOG_HEADER}" > "${catalog_file}"
  {
    printf '%s\n' "${CATALOG_HEADER}"
    tail -n +2 "${catalog_file}" 2>/dev/null || true
  } > "${catalog_file}.tmp"
  mv "${catalog_file}.tmp" "${catalog_file}"

  awk -F '\t' -v ch="${channel_tag}" -v tag="${immutable_tag}" '
    NR == 1 { print; next }
    !($1 == ch && $2 == tag) { print }
  ' "${catalog_file}" > "${catalog_file}.tmp"
  mv "${catalog_file}.tmp" "${catalog_file}"

  echo -e "${channel_tag}\t${immutable_tag}\t${PROMOTE_TS}\t${PROMOTE_VERSION}\t${OURBOX_VARIANT}\t${OURBOX_TARGET}\t${OURBOX_SKU}\t${GIT_SHA}\t${CONTRACT_DIGEST}\t${K3S_VERSION}\t${SHA256}\t${immutable_digest}\t${pinned_ref}" >> "${catalog_file}"

  log ">> Updating catalog: ${catalog_ref}"
  (cd "${catalog_dir}" && oras push "${catalog_ref}" \
    --artifact-type "application/vnd.techofourown.ourbox.matchbox.os-catalog.v1" \
    "catalog.tsv:text/tab-separated-values") >/dev/null
}

RELEASE_TAG="${RELEASE_TAG:-${GITHUB_REF_NAME:-}}"
[[ -n "${RELEASE_TAG}" ]] || die "release tag not set (RELEASE_TAG and GITHUB_REF_NAME are both empty)"

SOURCE_COMMIT="$(resolve_source_commit "${RELEASE_TAG}")"
SOURCE_SHA="$(git -C "${ROOT}" rev-parse --short=12 "${SOURCE_COMMIT}" 2>/dev/null)" \
  || die "Unable to derive short SHA for ${SOURCE_COMMIT}"

case "${PROMOTION_CONTEXT}" in
  stable)
    PROMOTE_VERSION="${RELEASE_TAG}"
    TARGET_CHANNEL_TAGS="${OFFICIAL_OS_STABLE_CHANNELS}"
    ;;
  exp-labs)
    PROMOTE_VERSION="${RELEASE_TAG}"
    TARGET_CHANNEL_TAGS="${OFFICIAL_OS_EXP_LABS_CHANNELS}"
    ;;
  *)
    die "Unknown promotion context: ${PROMOTION_CONTEXT} (expected: stable|exp-labs)"
    ;;
esac

SOURCE_IMMUTABLE_TAG="main-${SOURCE_SHA}-${OURBOX_TARGET}"
TARGET_IMMUTABLE_TAG="${PROMOTE_VERSION}-${OURBOX_TARGET}"
SOURCE_REF="${OFFICIAL_OS_REPO}:${SOURCE_IMMUTABLE_TAG}"

log "Resolving promotable source artifact: ${SOURCE_REF}"
IMMUTABLE_DIGEST="$(wait_for_source_digest "${SOURCE_REF}" || true)"
[[ "${IMMUTABLE_DIGEST}" =~ ^sha256:[0-9a-f]{64}$ ]] \
  || die "Timed out waiting for promotable source artifact ${SOURCE_REF}"

IMMUTABLE_PINNED_REF="${OFFICIAL_OS_REPO}@${IMMUTABLE_DIGEST}"
PROMOTE_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
CATALOG_HEADER=$'channel\ttag\tcreated\tversion\tvariant\ttarget\tsku\tgit_sha\tplatform_contract_digest\tk3s_version\timg_sha256\tartifact_digest\tpinned_ref'

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

log "Pulling source artifact metadata"
oras pull "${IMMUTABLE_PINNED_REF}" -o "${TMP}/source" >/dev/null
META_FILE="${TMP}/source/os.meta.env"
[[ -f "${META_FILE}" ]] || die "Source artifact ${IMMUTABLE_PINNED_REF} missing os.meta.env"
# shellcheck disable=SC1090
source "${META_FILE}"

SHA256="${OS_IMAGE_SHA256:-unknown}"
K3S_VERSION="${K3S_VERSION:-unknown}"
CONTRACT_DIGEST="${OURBOX_PLATFORM_CONTRACT_DIGEST:-unknown}"
GIT_SHA="${GIT_SHA:-${SOURCE_SHA}}"

log "Promoting ${IMMUTABLE_PINNED_REF} -> ${TARGET_IMMUTABLE_TAG} (${TARGET_CHANNEL_TAGS})"
oras tag "${IMMUTABLE_PINNED_REF}" "${TARGET_IMMUTABLE_TAG}" >/dev/null
for ch in ${TARGET_CHANNEL_TAGS}; do
  oras tag "${IMMUTABLE_PINNED_REF}" "${ch}" >/dev/null
  update_catalog "${ch}" "${TARGET_IMMUTABLE_TAG}" "${IMMUTABLE_DIGEST}" "${TMP}"
done

printf '%s\n' "${OFFICIAL_OS_REPO}:${TARGET_IMMUTABLE_TAG}" > "${DEPLOY_DIR}/os-artifact.ref"
printf '%s\n' "${IMMUTABLE_PINNED_REF}" > "${DEPLOY_DIR}/os-artifact.pinned.ref"
printf '%s\n' "${IMMUTABLE_DIGEST}" > "${DEPLOY_DIR}/os-artifact.digest"
printf '%s\n' "${SOURCE_REF}" > "${DEPLOY_DIR}/os-artifact.promote.source.ref"
cp "${META_FILE}" "${DEPLOY_DIR}/os-artifact.meta.env"

log "Official OS promote: context=${PROMOTION_CONTEXT} version=${PROMOTE_VERSION} source=${SOURCE_REF} digest=${IMMUTABLE_DIGEST}"
