#!/usr/bin/env bash
set -euo pipefail

# pi-gen provides ROOTFS_DIR
: "${ROOTFS_DIR:?ROOTFS_DIR not set}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../../" && pwd)"

SUBSTRATE="${REPO_ROOT}/artifacts/substrate"

# Refuse to build if the substrate artifacts aren't present
test -x "${SUBSTRATE}/k3s/k3s" || { echo "ERROR: missing ${SUBSTRATE}/k3s/k3s" >&2; exit 1; }
test -f "${SUBSTRATE}/k3s/k3s-images-arm64.tar" || { echo "ERROR: missing ${SUBSTRATE}/k3s/k3s-images-arm64.tar" >&2; exit 1; }

shopt -s nullglob
platform_tars=("${SUBSTRATE}/platform/images/"*.tar)
shopt -u nullglob
if (( ${#platform_tars[@]} == 0 )); then
  echo "ERROR: no platform image tars found in ${SUBSTRATE}/platform/images" >&2
  ls -lah "${SUBSTRATE}/platform/images" >&2 || true
  exit 1
fi

echo "==> Installing k3s binary"
install -D -m 0755 \
  "${SUBSTRATE}/k3s/k3s" \
  "${ROOTFS_DIR}/usr/local/bin/k3s"

echo "==> Copying substrate image tars"
install -D -m 0644 \
  "${SUBSTRATE}/k3s/k3s-images-arm64.tar" \
  "${ROOTFS_DIR}/opt/ourbox/substrate/k3s/k3s-images-arm64.tar"

for tar in "${platform_tars[@]}"; do
  install -D -m 0644 \
    "${tar}" \
    "${ROOTFS_DIR}/opt/ourbox/substrate/platform/images/$(basename "${tar}")"
done

echo "==> Installing platform manifests + systemd units + bootstrap script"
cp -a "${SCRIPT_DIR}/files/." "${ROOTFS_DIR}/"
