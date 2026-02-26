#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tools/lib.sh"
# shellcheck disable=SC1091
source "${ROOT}/tools/registry.sh"
# shellcheck disable=SC1091
[ -f "${ROOT}/tools/versions.env" ] && source "${ROOT}/tools/versions.env"

need_cmd curl
need_cmd chmod
need_cmd sed
need_cmd oras

# Always operate from repo root so relative paths (artifacts/) are stable
cd "${ROOT}"

: "${K3S_VERSION:=}"
: "${NGINX_IMAGE:=docker.io/library/nginx:1.27-alpine}"
: "${DUFS_IMAGE:=docker.io/sigoden/dufs:v0.42.0}"
: "${FLATNOTES_IMAGE:=docker.io/dullage/flatnotes:v5.0.0}"

if [[ -z "${K3S_VERSION}" ]]; then
  if [[ "${RESOLVE_LATEST_K3S:-0}" == "1" ]]; then
    log "K3S_VERSION not set; resolving latest from GitHub releases (dev only)"
    K3S_VERSION="$(
      curl -fsSLI https://github.com/k3s-io/k3s/releases/latest \
        | tr -d '\r' \
        | sed -n 's/^location: .*\/tag\/\(v[^ ]*\)$/\1/ip' \
        | tail -n1
    )"
  else
    die "K3S_VERSION not set. Edit tools/versions.env (recommended) or export K3S_VERSION."
  fi
fi

NGINX_IMAGE="$(canonicalize_image_ref "${NGINX_IMAGE}")"
DUFS_IMAGE="$(canonicalize_image_ref "${DUFS_IMAGE}")"
FLATNOTES_IMAGE="$(canonicalize_image_ref "${FLATNOTES_IMAGE}")"

log "Using K3S_VERSION=${K3S_VERSION}"
log "Using NGINX_IMAGE=${NGINX_IMAGE}"
log "Using DUFS_IMAGE=${DUFS_IMAGE}"
log "Using FLATNOTES_IMAGE=${FLATNOTES_IMAGE}"

# Preflight: check for existing artifacts that would block fetch
log "Preflight: checking for existing artifacts (fetch script will not overwrite)"
NGINX_TAR="$(echo "${NGINX_IMAGE}" | sed 's|/|_|g; s|:|_|g').tar"
DUFS_TAR="$(echo "${DUFS_IMAGE}" | sed 's|/|_|g; s|:|_|g').tar"
FLATNOTES_TAR="$(echo "${FLATNOTES_IMAGE}" | sed 's|/|_|g; s|:|_|g').tar"

blocking_files=()
[[ -f "artifacts/airgap/k3s/k3s" ]] && blocking_files+=("artifacts/airgap/k3s/k3s")
[[ -f "artifacts/airgap/k3s/k3s-airgap-images-arm64.tar" ]] && blocking_files+=("artifacts/airgap/k3s/k3s-airgap-images-arm64.tar")
[[ -f "artifacts/airgap/platform/images/${NGINX_TAR}" ]] && blocking_files+=("artifacts/airgap/platform/images/${NGINX_TAR}")
[[ -f "artifacts/airgap/platform/images/${DUFS_TAR}" ]] && blocking_files+=("artifacts/airgap/platform/images/${DUFS_TAR}")
[[ -f "artifacts/airgap/platform/images/${FLATNOTES_TAR}" ]] && blocking_files+=("artifacts/airgap/platform/images/${FLATNOTES_TAR}")
[[ -d "artifacts/airgap/platform/todo-bloom" ]] && blocking_files+=("artifacts/airgap/platform/todo-bloom")

if (( ${#blocking_files[@]} > 0 )); then
  log "ERROR: Existing artifacts detected (refusing to overwrite):"
  for f in "${blocking_files[@]}"; do
    echo "  ${f}"
    ls -lh "${f}" 2>/dev/null | sed 's/^/    /' || true
  done
  echo
  log "This script will NOT overwrite existing artifacts."
  echo
  log "You can:"
  log "  1. Remove them manually and re-run:"
  log "     rm -rf artifacts/airgap"
  log "     # or if permission denied:"
  log "     sudo rm -rf artifacts/airgap"
  echo
  log "  2. Have this script remove them for you (with confirmation)"
  echo

  read -r -p "Type REMOVE to delete artifacts/airgap and continue, or anything else to abort: " confirm
  if [[ "${confirm}" != "REMOVE" ]]; then
    die "Fetch aborted; existing artifacts not removed"
  fi

  log "WARNING: About to remove artifacts/airgap and all contents"
  if [[ -w "artifacts/airgap" ]]; then
    log "Removing artifacts/airgap (no sudo needed)"
    rm -rf "artifacts/airgap" || die "Failed to remove artifacts/airgap"
  else
    need_cmd sudo
    log "Removing artifacts/airgap (requires sudo due to permissions)"
    sudo rm -rf "artifacts/airgap" || die "Failed to remove artifacts/airgap with sudo"
  fi
  log "Artifacts removed; proceeding with fetch"
fi

OUT="artifacts/airgap"
mkdir -p "$OUT/k3s" "$OUT/platform/images" "$OUT/platform/todo-bloom"

log "Fetch k3s binary (arm64) @ ${K3S_VERSION}"
curl -fsSL \
  -o "$OUT/k3s/k3s" \
  "https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION}/k3s-arm64"
chmod +x "$OUT/k3s/k3s"

log "Fetch k3s airgap images (arm64) @ ${K3S_VERSION}"
curl -fsSL \
  -o "$OUT/k3s/k3s-airgap-images-arm64.tar" \
  "https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION}/k3s-airgap-images-arm64.tar"

CLI="$(pick_container_cli)"
log "Using container CLI: ${CLI}"

log "Pull + save demo image (arm64): ${NGINX_IMAGE}"

case "$(cli_base "${CLI}")" in
  nerdctl|docker)
    # shellcheck disable=SC2086
    $CLI pull --platform=linux/arm64 "${NGINX_IMAGE}"
    if [[ "$(cli_base "${CLI}")" = "nerdctl" ]]; then
      # shellcheck disable=SC2086
      $CLI save --platform=linux/arm64 -o "$OUT/platform/images/${NGINX_TAR}" "${NGINX_IMAGE}"
    else
      # shellcheck disable=SC2086
      $CLI save -o "$OUT/platform/images/${NGINX_TAR}" "${NGINX_IMAGE}"
    fi
    ;;
  podman)
    # shellcheck disable=SC2086
    $CLI pull --arch=arm64 --os=linux "${NGINX_IMAGE}"
    # shellcheck disable=SC2086
    $CLI save -o "$OUT/platform/images/${NGINX_TAR}" "${NGINX_IMAGE}"
    ;;
  *)
    die "Unsupported container CLI: ${CLI}"
    ;;
esac

log "Pull + save dufs image (arm64): ${DUFS_IMAGE}"

case "$(cli_base "${CLI}")" in
  nerdctl|docker)
    # shellcheck disable=SC2086
    $CLI pull --platform=linux/arm64 "${DUFS_IMAGE}"
    if [[ "$(cli_base "${CLI}")" = "nerdctl" ]]; then
      # shellcheck disable=SC2086
      $CLI save --platform=linux/arm64 -o "$OUT/platform/images/${DUFS_TAR}" "${DUFS_IMAGE}"
    else
      # shellcheck disable=SC2086
      $CLI save -o "$OUT/platform/images/${DUFS_TAR}" "${DUFS_IMAGE}"
    fi
    ;;
  podman)
    # shellcheck disable=SC2086
    $CLI pull --arch=arm64 --os=linux "${DUFS_IMAGE}"
    # shellcheck disable=SC2086
    $CLI save -o "$OUT/platform/images/${DUFS_TAR}" "${DUFS_IMAGE}"
    ;;
  *)
    die "Unsupported container CLI: ${CLI}"
    ;;
esac

log "Pull + save flatnotes image (arm64): ${FLATNOTES_IMAGE}"

case "$(cli_base "${CLI}")" in
  nerdctl|docker)
    # shellcheck disable=SC2086
    $CLI pull --platform=linux/arm64 "${FLATNOTES_IMAGE}"
    if [[ "$(cli_base "${CLI}")" = "nerdctl" ]]; then
      # shellcheck disable=SC2086
      $CLI save --platform=linux/arm64 -o "$OUT/platform/images/${FLATNOTES_TAR}" "${FLATNOTES_IMAGE}"
    else
      # shellcheck disable=SC2086
      $CLI save -o "$OUT/platform/images/${FLATNOTES_TAR}" "${FLATNOTES_IMAGE}"
    fi
    ;;
  podman)
    # shellcheck disable=SC2086
    $CLI pull --arch=arm64 --os=linux "${FLATNOTES_IMAGE}"
    # shellcheck disable=SC2086
    $CLI save -o "$OUT/platform/images/${FLATNOTES_TAR}" "${FLATNOTES_IMAGE}"
    ;;
  *)
    die "Unsupported container CLI: ${CLI}"
    ;;
esac

TODO_BLOOM_REPO="https://raw.githubusercontent.com/EverybodyCode/todo/main"
log "Fetch Todo Bloom static files from ${TODO_BLOOM_REPO}"
curl -fsSL -o "$OUT/platform/todo-bloom/index.html" "${TODO_BLOOM_REPO}/index.html"
curl -fsSL -o "$OUT/platform/todo-bloom/app.js"     "${TODO_BLOOM_REPO}/app.js"
curl -fsSL -o "$OUT/platform/todo-bloom/styles.css"  "${TODO_BLOOM_REPO}/styles.css"

log "Writing airgap manifest"
cat > "$OUT/manifest.env" <<EOF_MANIFEST
K3S_VERSION=${K3S_VERSION}
NGINX_IMAGE=${NGINX_IMAGE}
DUFS_IMAGE=${DUFS_IMAGE}
FLATNOTES_IMAGE=${FLATNOTES_IMAGE}
EOF_MANIFEST

log "Artifacts created:"
ls -lah "$OUT/k3s" "$OUT/platform/images" "$OUT/platform/todo-bloom" "$OUT/manifest.env"

log "Fetching pinned platform contract (OCI artifact)"
"${ROOT}/tools/fetch-platform-contract.sh"

log "Syncing pinned platform contract into pi-gen stage files"
"${ROOT}/tools/sync-platform-contract-into-pigen.sh"
