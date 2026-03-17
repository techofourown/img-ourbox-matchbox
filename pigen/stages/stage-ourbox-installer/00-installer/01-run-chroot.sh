#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  iproute2 \
  xz-utils \
  tar \
  util-linux \
  e2fsprogs \
  parted \
  openssl \
  coreutils \
  grep \
  sed \
  gawk \
  findutils

emit_shell_assignment() {
  local name="$1" value="$2"
  printf '%s=%q\n' "${name}" "${value}"
}

OURBOX_RECIPE_GIT_HASH="$(git -C /ourbox rev-parse HEAD 2>/dev/null || echo unknown)"

# shellcheck disable=SC1091
source /opt/ourbox/tools/installer-ssh-helper.sh

ourbox_installer_ssh_normalize_inputs
ourbox_installer_ssh_validate_requested_posture
ourbox_installer_ssh_validate_materialized_auth
ourbox_installer_ssh_apply_common_state /etc/ssh/sshd_config.d/60-ourbox-installer.conf

: "${OS_REPO:=ghcr.io/techofourown/ourbox-matchbox-os}"
if [[ -z "${INSTALL_DEFAULTS_REF+x}" ]]; then
  INSTALL_DEFAULTS_REF="ghcr.io/techofourown/sw-ourbox-os/install-defaults:stable"
fi
: "${INSTALLER_ID:=matchbox}"
: "${OS_TARGET:=rpi}"
: "${OS_CHANNEL:=stable}"
: "${OS_DEFAULT_REF:=}"
: "${AIRGAP_PLATFORM_REPO:=ghcr.io/techofourown/sw-ourbox-os/airgap-platform}"
: "${AIRGAP_PLATFORM_ARCH:=arm64}"
: "${AIRGAP_PLATFORM_CHANNEL:=stable}"
: "${AIRGAP_PLATFORM_REF:=}"
: "${AIRGAP_PLATFORM_CATALOG_ENABLED:=1}"
: "${AIRGAP_PLATFORM_CATALOG_TAG:=catalog-${AIRGAP_PLATFORM_ARCH}}"
: "${CHANNEL_STABLE_TAG:=${OS_TARGET}-stable}"
: "${CHANNEL_BETA_TAG:=${OS_TARGET}-beta}"
: "${CHANNEL_NIGHTLY_TAG:=${OS_TARGET}-nightly}"
: "${CHANNEL_EXP_LABS_TAG:=${OS_TARGET}-exp-labs}"
: "${OS_CATALOG_ENABLED:=1}"
: "${OS_CATALOG_TAG:=${OS_TARGET}-catalog}"
: "${OS_ARTIFACT_TYPE:=application/vnd.ourbox.matchbox.os-image.v1}"
: "${OS_ORAS_VERSION:=1.3.0}"
: "${OS_REGISTRY_USERNAME:=}"
: "${OS_REGISTRY_PASSWORD:=}"
: "${OURBOX_INSTALLER_SSH_TEARDOWN_ON_COMPLETE:=0}"
: "${INSTALLER_VERSION:=${OURBOX_VERSION:-dev}}"
: "${INSTALLER_GIT_HASH:=${OURBOX_RECIPE_GIT_HASH}}"

{
  cat <<'EOF'
# Defaults for fetching OS payloads at install time.
# This file is rendered at installer image build time.
# Users/ops can override by placing /boot/firmware/ourbox-installer.env on the installer media.

# OCI repo containing OS payload artifacts (oras-compatible)
EOF
  emit_shell_assignment "OS_REPO" "${OS_REPO}"
  cat <<'EOF'

# Optional remote defaults profile published by sw-ourbox-os.
# If available, this can override OS and airgap selection controls at install time.
EOF
  emit_shell_assignment "INSTALL_DEFAULTS_REF" "${INSTALL_DEFAULTS_REF}"
  emit_shell_assignment "INSTALLER_ID" "${INSTALLER_ID}"
  cat <<'EOF'

# Target + channel determine the moving tag to pull when OS_REF/OS_DEFAULT_REF is not set.
EOF
  emit_shell_assignment "OS_TARGET" "${OS_TARGET}"
  emit_shell_assignment "OS_CHANNEL" "${OS_CHANNEL}"
  emit_shell_assignment "OS_DEFAULT_REF" "${OS_DEFAULT_REF}"
  cat <<'EOF'

# Channel tags shown in installer channel selection.
EOF
  emit_shell_assignment "CHANNEL_STABLE_TAG" "${CHANNEL_STABLE_TAG}"
  emit_shell_assignment "CHANNEL_BETA_TAG" "${CHANNEL_BETA_TAG}"
  emit_shell_assignment "CHANNEL_NIGHTLY_TAG" "${CHANNEL_NIGHTLY_TAG}"
  emit_shell_assignment "CHANNEL_EXP_LABS_TAG" "${CHANNEL_EXP_LABS_TAG}"
  cat <<'EOF'

# Optional catalog artifact (small TSV) for interactive selection.
EOF
  emit_shell_assignment "OS_CATALOG_ENABLED" "${OS_CATALOG_ENABLED}"
  emit_shell_assignment "OS_CATALOG_TAG" "${OS_CATALOG_TAG}"
  cat <<'EOF'

# Airgap-platform defaults applied after OS selection.
EOF
  emit_shell_assignment "AIRGAP_PLATFORM_REPO" "${AIRGAP_PLATFORM_REPO}"
  emit_shell_assignment "AIRGAP_PLATFORM_ARCH" "${AIRGAP_PLATFORM_ARCH}"
  emit_shell_assignment "AIRGAP_PLATFORM_CHANNEL" "${AIRGAP_PLATFORM_CHANNEL}"
  emit_shell_assignment "AIRGAP_PLATFORM_REF" "${AIRGAP_PLATFORM_REF}"
  emit_shell_assignment "AIRGAP_PLATFORM_CATALOG_ENABLED" "${AIRGAP_PLATFORM_CATALOG_ENABLED}"
  emit_shell_assignment "AIRGAP_PLATFORM_CATALOG_TAG" "${AIRGAP_PLATFORM_CATALOG_TAG}"
  cat <<'EOF'

# Artifact type used when pushing OS payloads via ORAS.
EOF
  emit_shell_assignment "OS_ARTIFACT_TYPE" "${OS_ARTIFACT_TYPE}"
  cat <<'EOF'

# ORAS version to bootstrap on the installer if missing.
EOF
  emit_shell_assignment "OS_ORAS_VERSION" "${OS_ORAS_VERSION}"
  cat <<'EOF'

# Installer artifact identity baked at image build time.
EOF
  emit_shell_assignment "INSTALLER_VERSION" "${INSTALLER_VERSION}"
  emit_shell_assignment "INSTALLER_GIT_HASH" "${INSTALLER_GIT_HASH}"
  cat <<'EOF'

# Optional registry auth (if your repo is private)
EOF
  emit_shell_assignment "OS_REGISTRY_USERNAME" "${OS_REGISTRY_USERNAME}"
  emit_shell_assignment "OS_REGISTRY_PASSWORD" "${OS_REGISTRY_PASSWORD}"
  cat <<'EOF'

# Installer SSH policy (mode/user/hash/keys/root) is baked in at image build
# time by stage-ourbox-installer/00-installer/01-run-chroot.sh.
# Runtime overrides from /boot/firmware/ourbox-installer.env are intentionally
# not supported for those policy knobs.
EOF
  emit_shell_assignment "OURBOX_INSTALLER_SSH_TEARDOWN_ON_COMPLETE" "${OURBOX_INSTALLER_SSH_TEARDOWN_ON_COMPLETE}"
} > /opt/ourbox/installer/defaults.env

chmod 0755 /opt/ourbox/tools/ourbox-install
chmod 0644 /opt/ourbox/tools/lib.sh
chmod 0644 /opt/ourbox/tools/installer-selection-resolver.sh
chmod 0644 /opt/ourbox/tools/installer-ssh-helper.sh

install -d -m 0755 /run/sshd
test_hostkey_dir="$(mktemp -d)"
cleanup_test_hostkeys() {
  rm -rf "${test_hostkey_dir}"
}
trap cleanup_test_hostkeys EXIT
ssh-keygen -q -t ed25519 -N '' -f "${test_hostkey_dir}/ssh_host_ed25519_key" >/dev/null
sshd -t \
  -o "HostKey=${test_hostkey_dir}/ssh_host_ed25519_key" \
  >/dev/null
trap - EXIT
cleanup_test_hostkeys

systemctl enable ssh
systemctl enable ourbox-installer.service
