#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates \
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
  findutils \
  python3

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

: "${INSTALLER_ID:=matchbox}"
: "${OURBOX_INSTALLER_SSH_TEARDOWN_ON_COMPLETE:=0}"
: "${INSTALLER_VERSION:=${OURBOX_VERSION:-dev}}"
: "${INSTALLER_GIT_HASH:=${OURBOX_RECIPE_GIT_HASH}}"

{
  cat <<'EOF'
# Defaults for the local-mission Matchbox installer runtime.
# This file is rendered at installer image build time.
# The host-composed mission staged into /opt/ourbox/mission is the authoritative
# source for OS and application-bundle selection.

# Installer identity baked at image build time.
EOF
  emit_shell_assignment "INSTALLER_ID" "${INSTALLER_ID}"
  emit_shell_assignment "INSTALLER_VERSION" "${INSTALLER_VERSION}"
  emit_shell_assignment "INSTALLER_GIT_HASH" "${INSTALLER_GIT_HASH}"
  cat <<'EOF'

# Installer SSH behavior is baked at image build time.
EOF
  emit_shell_assignment "OURBOX_INSTALLER_SSH_TEARDOWN_ON_COMPLETE" "${OURBOX_INSTALLER_SSH_TEARDOWN_ON_COMPLETE}"
} > /opt/ourbox/installer/defaults.env

chmod 0755 /opt/ourbox/tools/ourbox-install
chmod 0644 /opt/ourbox/tools/lib.sh
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
