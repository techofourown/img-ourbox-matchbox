#!/usr/bin/env bash
set -euo pipefail

# pi-gen provides ROOTFS_DIR
: "${ROOTFS_DIR:?ROOTFS_DIR not set}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../../" && pwd)"

AIRGAP="${REPO_ROOT}/artifacts/airgap"

# Refuse to build if the airgap artifacts aren't present
test -x "${AIRGAP}/k3s/k3s" || { echo "ERROR: missing ${AIRGAP}/k3s/k3s" >&2; exit 1; }
test -f "${AIRGAP}/k3s/k3s-airgap-images-arm64.tar" || { echo "ERROR: missing ${AIRGAP}/k3s/k3s-airgap-images-arm64.tar" >&2; exit 1; }

shopt -s nullglob
platform_tars=("${AIRGAP}/platform/images/"*.tar)
shopt -u nullglob
if (( ${#platform_tars[@]} == 0 )); then
  echo "ERROR: no platform image tars found in ${AIRGAP}/platform/images" >&2
  ls -lah "${AIRGAP}/platform/images" >&2 || true
  exit 1
fi

echo "==> Installing k3s binary"
install -D -m 0755 \
  "${AIRGAP}/k3s/k3s" \
  "${ROOTFS_DIR}/usr/local/bin/k3s"

echo "==> Copying airgap image tars"
install -D -m 0644 \
  "${AIRGAP}/k3s/k3s-airgap-images-arm64.tar" \
  "${ROOTFS_DIR}/opt/ourbox/airgap/k3s/k3s-airgap-images-arm64.tar"

for tar in "${platform_tars[@]}"; do
  install -D -m 0644 \
    "${tar}" \
    "${ROOTFS_DIR}/opt/ourbox/airgap/platform/images/$(basename "${tar}")"
done

echo "==> Installing platform manifests + systemd units + bootstrap script"
cp -a "${SCRIPT_DIR}/files/." "${ROOTFS_DIR}/"

echo "==> Recording platform contract metadata in /etc/ourbox/release"
RELEASE_FILE="${ROOTFS_DIR}/etc/ourbox/release"
CONTRACT_ENV="${ROOTFS_DIR}/opt/ourbox/airgap/platform/contract.env"
CONTRACT_DIGEST_FILE="${ROOTFS_DIR}/opt/ourbox/airgap/platform/contract.digest"

[[ -f "${RELEASE_FILE}" ]] || { echo "ERROR: missing ${RELEASE_FILE}" >&2; exit 1; }
[[ -f "${CONTRACT_ENV}" ]] || { echo "ERROR: missing ${CONTRACT_ENV} (did you sync the platform contract?)" >&2; exit 1; }
[[ -f "${CONTRACT_DIGEST_FILE}" ]] || { echo "ERROR: missing ${CONTRACT_DIGEST_FILE} (did you sync the platform contract?)" >&2; exit 1; }

# Remove any existing contract lines to avoid duplicates on reruns
tmp_release="$(mktemp)"
grep -v '^OURBOX_PLATFORM_CONTRACT_' "${RELEASE_FILE}" > "${tmp_release}" || true
cat "${tmp_release}" > "${RELEASE_FILE}"
rm -f "${tmp_release}"

CONTRACT_SOURCE="unknown"
CONTRACT_REVISION="unknown"
CONTRACT_VERSION="unknown"
CONTRACT_CREATED="unknown"

while IFS='=' read -r key value; do
  case "${key}" in
    OURBOX_PLATFORM_CONTRACT_SOURCE) CONTRACT_SOURCE="${value}" ;;
    OURBOX_PLATFORM_CONTRACT_REVISION) CONTRACT_REVISION="${value}" ;;
    OURBOX_PLATFORM_CONTRACT_VERSION) CONTRACT_VERSION="${value}" ;;
    OURBOX_PLATFORM_CONTRACT_CREATED) CONTRACT_CREATED="${value}" ;;
  esac
done < "${CONTRACT_ENV}"

{
  echo "OURBOX_PLATFORM_CONTRACT_DIGEST=$(cat "${CONTRACT_DIGEST_FILE}")"
  echo "OURBOX_PLATFORM_CONTRACT_SOURCE=${CONTRACT_SOURCE}"
  echo "OURBOX_PLATFORM_CONTRACT_REVISION=${CONTRACT_REVISION}"
  echo "OURBOX_PLATFORM_CONTRACT_VERSION=${CONTRACT_VERSION}"
  echo "OURBOX_PLATFORM_CONTRACT_CREATED=${CONTRACT_CREATED}"
} >> "${RELEASE_FILE}"
