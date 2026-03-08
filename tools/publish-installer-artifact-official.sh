#!/usr/bin/env bash
# Official installer artifact publication wrapper.
# Sources repo-defined release config only — no free-form inputs accepted.
# Called by the official candidate and integration nightly GitHub Actions workflows.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tools/lib.sh"
# shellcheck disable=SC1091
source "${ROOT}/release/official-artifacts.env"

RELEASE_CONTEXT="${1:?Usage: publish-installer-artifact-official.sh beta|nightly}"

case "${RELEASE_CONTEXT}" in
  beta|candidate)
    [[ -n "${GITHUB_SHA:-}" ]] || die "GITHUB_SHA not set"
    OURBOX_VERSION="main-${GITHUB_SHA:0:12}"
    INSTALLER_CHANNEL_TAGS="${OFFICIAL_INSTALLER_BETA_CHANNELS}"
    INSTALLER_IMMUTABLE_TAG="main-${GITHUB_SHA:0:12}-${OURBOX_TARGET}-installer"
    ;;
  nightly)
    [[ -n "${GITHUB_SHA:-}" ]] || die "GITHUB_SHA not set"
    OURBOX_VERSION="nightly-${GITHUB_SHA:0:12}"
    INSTALLER_CHANNEL_TAGS="${OFFICIAL_INSTALLER_NIGHTLY_CHANNELS}"
    INSTALLER_IMMUTABLE_TAG="nightly-${GITHUB_SHA:0:12}-${OURBOX_TARGET}-installer"
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
export INSTALLER_REPO="${OFFICIAL_INSTALLER_REPO}"
export INSTALLER_CHANNEL_TAGS
export INSTALLER_IMMUTABLE_TAG
export INSTALLER_INCLUDE_BUILD_LOG=0   # never include build logs in official published artifacts

log "Official installer publish: context=${RELEASE_CONTEXT} version=${OURBOX_VERSION} tag=${INSTALLER_IMMUTABLE_TAG} channels=${INSTALLER_CHANNEL_TAGS}"

exec "${ROOT}/tools/publish-installer-artifact.sh" deploy
