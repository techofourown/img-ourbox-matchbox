#!/usr/bin/env bash
# Official OS artifact publication wrapper.
# Sources repo-defined release config only — no free-form inputs accepted.
# Called by the official candidate and integration nightly GitHub Actions workflows.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tools/lib.sh"
# shellcheck disable=SC1091
source "${ROOT}/release/official-artifacts.env"

RELEASE_CONTEXT="${1:?Usage: publish-os-artifact-official.sh beta|nightly}"

case "${RELEASE_CONTEXT}" in
  beta|candidate)
    [[ -n "${GITHUB_SHA:-}" ]] || die "GITHUB_SHA not set"
    OURBOX_VERSION="main-${GITHUB_SHA:0:12}"
    OS_CHANNEL_TAGS="${OFFICIAL_OS_BETA_CHANNELS}"
    OS_IMMUTABLE_TAG="main-${GITHUB_SHA:0:12}-${OURBOX_TARGET}"
    ;;
  nightly)
    [[ -n "${GITHUB_SHA:-}" ]] || die "GITHUB_SHA not set"
    OURBOX_VERSION="nightly-${GITHUB_SHA:0:12}"
    OS_CHANNEL_TAGS="${OFFICIAL_OS_NIGHTLY_CHANNELS}"
    OS_IMMUTABLE_TAG="nightly-${GITHUB_SHA:0:12}-${OURBOX_TARGET}"
    ;;
  *)
    die "Unknown release context: ${RELEASE_CONTEXT} (expected: beta|nightly)"
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
