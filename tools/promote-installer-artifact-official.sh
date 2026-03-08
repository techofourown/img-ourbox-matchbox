#!/usr/bin/env bash
# Official installer artifact promotion wrapper.
# Re-tags an already-published immutable artifact into a promoted channel.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tools/lib.sh"
# shellcheck disable=SC1091
source "${ROOT}/release/official-artifacts.env"

need_cmd oras
need_cmd git

PROMOTION_CONTEXT="${1:?Usage: promote-installer-artifact-official.sh stable|exp-labs}"
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
      log "Waiting for promotable source installer artifact: ${source_ref}"
    fi
    sleep "${interval}"
    elapsed=$((elapsed + interval))
  done

  return 1
}

RELEASE_TAG="${RELEASE_TAG:-${GITHUB_REF_NAME:-}}"
[[ -n "${RELEASE_TAG}" ]] || die "release tag not set (RELEASE_TAG and GITHUB_REF_NAME are both empty)"

SOURCE_COMMIT="$(resolve_source_commit "${RELEASE_TAG}")"
SOURCE_SHA="$(git -C "${ROOT}" rev-parse --short=12 "${SOURCE_COMMIT}" 2>/dev/null)" \
  || die "Unable to derive short SHA for ${SOURCE_COMMIT}"

case "${PROMOTION_CONTEXT}" in
  stable)
    PROMOTE_VERSION="${RELEASE_TAG}"
    TARGET_CHANNEL_TAGS="${OFFICIAL_INSTALLER_STABLE_CHANNELS}"
    ;;
  exp-labs)
    PROMOTE_VERSION="${RELEASE_TAG}"
    TARGET_CHANNEL_TAGS="${OFFICIAL_INSTALLER_EXP_LABS_CHANNELS}"
    ;;
  *)
    die "Unknown promotion context: ${PROMOTION_CONTEXT} (expected: stable|exp-labs)"
    ;;
esac

SOURCE_IMMUTABLE_TAG="main-${SOURCE_SHA}-${OURBOX_TARGET}-installer"
TARGET_IMMUTABLE_TAG="${PROMOTE_VERSION}-${OURBOX_TARGET}-installer"
SOURCE_REF="${OFFICIAL_INSTALLER_REPO}:${SOURCE_IMMUTABLE_TAG}"

log "Resolving promotable source installer artifact: ${SOURCE_REF}"
IMMUTABLE_DIGEST="$(wait_for_source_digest "${SOURCE_REF}" || true)"
[[ "${IMMUTABLE_DIGEST}" =~ ^sha256:[0-9a-f]{64}$ ]] \
  || die "Timed out waiting for promotable source artifact ${SOURCE_REF}"

IMMUTABLE_PINNED_REF="${OFFICIAL_INSTALLER_REPO}@${IMMUTABLE_DIGEST}"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

log "Pulling source installer metadata"
oras pull "${IMMUTABLE_PINNED_REF}" -o "${TMP}/source" >/dev/null
META_FILE="${TMP}/source/installer.meta.env"
[[ -f "${META_FILE}" ]] || die "Source artifact ${IMMUTABLE_PINNED_REF} missing installer.meta.env"

log "Promoting ${IMMUTABLE_PINNED_REF} -> ${TARGET_IMMUTABLE_TAG} (${TARGET_CHANNEL_TAGS})"
oras tag "${IMMUTABLE_PINNED_REF}" "${TARGET_IMMUTABLE_TAG}" >/dev/null
for ch in ${TARGET_CHANNEL_TAGS}; do
  oras tag "${IMMUTABLE_PINNED_REF}" "${ch}" >/dev/null
done

printf '%s\n' "${OFFICIAL_INSTALLER_REPO}:${TARGET_IMMUTABLE_TAG}" > "${DEPLOY_DIR}/installer-artifact.ref"
printf '%s\n' "${IMMUTABLE_PINNED_REF}" > "${DEPLOY_DIR}/installer-artifact.pinned.ref"
printf '%s\n' "${IMMUTABLE_DIGEST}" > "${DEPLOY_DIR}/installer-artifact.digest"
printf '%s\n' "${SOURCE_REF}" > "${DEPLOY_DIR}/installer-artifact.promote.source.ref"
cp "${META_FILE}" "${DEPLOY_DIR}/installer-artifact.meta.env"

log "Official installer promote: context=${PROMOTION_CONTEXT} version=${PROMOTE_VERSION} source=${SOURCE_REF} digest=${IMMUTABLE_DIGEST}"
