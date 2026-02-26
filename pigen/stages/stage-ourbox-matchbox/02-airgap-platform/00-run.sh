#!/usr/bin/env bash
set -euo pipefail

# pi-gen provides ROOTFS_DIR
: "${ROOTFS_DIR:?ROOTFS_DIR not set}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../../" && pwd)"

AIRGAP="${REPO_ROOT}/artifacts/airgap"

# Pull the exact versions used when creating the airgap artifacts.
# (This keeps the stage resilient to tar naming changes.)
if [[ -f "${AIRGAP}/manifest.env" ]]; then
  # shellcheck disable=SC1090
  source "${AIRGAP}/manifest.env"
fi

: "${NGINX_IMAGE:=docker.io/library/nginx:1.27-alpine}"
: "${DUFS_IMAGE:=docker.io/sigoden/dufs:v0.42.0}"
: "${FLATNOTES_IMAGE:=docker.io/dullage/flatnotes:v5.0.0}"

NGINX_TAR="$(echo "${NGINX_IMAGE}" | sed 's|/|_|g; s|:|_|g').tar"
DUFS_TAR="$(echo "${DUFS_IMAGE}" | sed 's|/|_|g; s|:|_|g').tar"
FLATNOTES_TAR="$(echo "${FLATNOTES_IMAGE}" | sed 's|/|_|g; s|:|_|g').tar"

# Refuse to build if the airgap artifacts aren't present
test -x "${AIRGAP}/k3s/k3s" || { echo "ERROR: missing ${AIRGAP}/k3s/k3s" >&2; exit 1; }
test -f "${AIRGAP}/k3s/k3s-airgap-images-arm64.tar" || { echo "ERROR: missing ${AIRGAP}/k3s/k3s-airgap-images-arm64.tar" >&2; exit 1; }
test -f "${AIRGAP}/platform/images/${NGINX_TAR}" || {
  echo "ERROR: missing ${AIRGAP}/platform/images/${NGINX_TAR}" >&2
  echo "Found in ${AIRGAP}/platform/images:" >&2
  ls -lah "${AIRGAP}/platform/images" >&2 || true
  exit 1
}
test -f "${AIRGAP}/platform/images/${DUFS_TAR}" || {
  echo "ERROR: missing ${AIRGAP}/platform/images/${DUFS_TAR}" >&2
  ls -lah "${AIRGAP}/platform/images" >&2 || true
  exit 1
}
test -f "${AIRGAP}/platform/images/${FLATNOTES_TAR}" || {
  echo "ERROR: missing ${AIRGAP}/platform/images/${FLATNOTES_TAR}" >&2
  ls -lah "${AIRGAP}/platform/images" >&2 || true
  exit 1
}

echo "==> Installing k3s binary"
install -D -m 0755 \
  "${AIRGAP}/k3s/k3s" \
  "${ROOTFS_DIR}/usr/local/bin/k3s"

echo "==> Copying airgap image tars"
install -D -m 0644 \
  "${AIRGAP}/k3s/k3s-airgap-images-arm64.tar" \
  "${ROOTFS_DIR}/opt/ourbox/airgap/k3s/k3s-airgap-images-arm64.tar"

install -D -m 0644 \
  "${AIRGAP}/platform/images/${NGINX_TAR}" \
  "${ROOTFS_DIR}/opt/ourbox/airgap/platform/images/${NGINX_TAR}"

install -D -m 0644 \
  "${AIRGAP}/platform/images/${DUFS_TAR}" \
  "${ROOTFS_DIR}/opt/ourbox/airgap/platform/images/${DUFS_TAR}"

install -D -m 0644 \
  "${AIRGAP}/platform/images/${FLATNOTES_TAR}" \
  "${ROOTFS_DIR}/opt/ourbox/airgap/platform/images/${FLATNOTES_TAR}"

echo "==> Copying Todo Bloom static files"
test -d "${AIRGAP}/platform/todo-bloom" || {
  echo "ERROR: missing ${AIRGAP}/platform/todo-bloom" >&2
  exit 1
}
install -d -m 0755 "${ROOTFS_DIR}/opt/ourbox/airgap/platform/todo-bloom"
install -m 0644 \
  "${AIRGAP}/platform/todo-bloom/index.html" \
  "${AIRGAP}/platform/todo-bloom/app.js" \
  "${AIRGAP}/platform/todo-bloom/styles.css" \
  "${ROOTFS_DIR}/opt/ourbox/airgap/platform/todo-bloom/"

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
