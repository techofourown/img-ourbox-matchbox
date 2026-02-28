#!/usr/bin/env bash
# Official OS artifact publication wrapper.
# Sources repo-defined release config only — no free-form inputs accepted.
# Called by the official-nightly and official-release GitHub Actions workflows.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tools/lib.sh"
# shellcheck disable=SC1091
source "${ROOT}/release/official-artifacts.env"

RELEASE_CONTEXT="${1:?Usage: publish-os-artifact-official.sh nightly|release}"

case "${RELEASE_CONTEXT}" in
  nightly)
    [[ -n "${GITHUB_SHA:-}" ]] || die "GITHUB_SHA not set"
    OURBOX_VERSION="nightly-${GITHUB_SHA:0:12}"
    OS_CHANNEL_TAGS="${OFFICIAL_OS_NIGHTLY_CHANNELS}"
    OS_IMMUTABLE_TAG="nightly-${GITHUB_SHA:0:12}-${OURBOX_TARGET}"
    ;;
  release)
    [[ -n "${GITHUB_REF_NAME:-}" ]] || die "GITHUB_REF_NAME not set"
    OURBOX_VERSION="${GITHUB_REF_NAME}"
    OS_CHANNEL_TAGS="${OFFICIAL_OS_RELEASE_CHANNELS}"
    OS_IMMUTABLE_TAG="${GITHUB_REF_NAME}-${OURBOX_TARGET}"
    ;;
  *)
    die "Unknown release context: ${RELEASE_CONTEXT} (expected: nightly|release)"
    ;;
esac

export OURBOX_TARGET
export OURBOX_MODEL_ID
export OURBOX_SKU
export OURBOX_VARIANT
export OURBOX_VERSION
export OS_REPO="${OFFICIAL_OS_REPO}"
export OS_CATALOG_TAG="${OFFICIAL_OS_CATALOG_TAG}"
export OS_CHANNEL_TAGS
export OS_IMMUTABLE_TAG
export OS_INCLUDE_BUILD_LOG=0   # never include build logs in official published artifacts

log "Official OS publish: context=${RELEASE_CONTEXT} version=${OURBOX_VERSION} tag=${OS_IMMUTABLE_TAG} channels=${OS_CHANNEL_TAGS}"

exec "${ROOT}/tools/publish-os-artifact.sh" deploy
