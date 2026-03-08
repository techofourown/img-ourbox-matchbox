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

# shellcheck disable=SC2016
DEFAULT_INSTALLER_SSH_PASSWORD_HASH='$6$ourboxinstall$GgJGorVZ2X.yl0cQk8yIqYDawhEuB47d9m.k9t9HP1afvwC3ALmMxTDtKT2NjDBMqkUOVzvm7LK2ZHxBt2KxH1'
OURBOX_INSTALLER_SSH_MODE="${OURBOX_INSTALLER_SSH_MODE:-key}"
OURBOX_INSTALLER_SSH_USER="${OURBOX_INSTALLER_SSH_USER:-ourbox-installer}"
OURBOX_INSTALLER_SSH_PASSWORD_HASH="${OURBOX_INSTALLER_SSH_PASSWORD_HASH:-${DEFAULT_INSTALLER_SSH_PASSWORD_HASH}}"
OURBOX_INSTALLER_SSH_AUTHORIZED_KEYS="${OURBOX_INSTALLER_SSH_AUTHORIZED_KEYS:-}"
OURBOX_INSTALLER_SSH_ALLOW_ROOT="${OURBOX_INSTALLER_SSH_ALLOW_ROOT:-0}"

case "${OURBOX_INSTALLER_SSH_MODE}" in
  off|key|password|both) ;;
  *) OURBOX_INSTALLER_SSH_MODE="key" ;;
esac

if [[ "${OURBOX_INSTALLER_SSH_MODE}" != "off" ]]; then
  if ! id -u "${OURBOX_INSTALLER_SSH_USER}" >/dev/null 2>&1; then
    adduser --disabled-password --gecos "" "${OURBOX_INSTALLER_SSH_USER}" >/dev/null 2>&1 \
      || useradd -m -s /bin/bash "${OURBOX_INSTALLER_SSH_USER}" >/dev/null 2>&1
  fi

  if [[ "${OURBOX_INSTALLER_SSH_MODE}" == "password" || "${OURBOX_INSTALLER_SSH_MODE}" == "both" ]]; then
    if [[ -n "${OURBOX_INSTALLER_SSH_PASSWORD_HASH}" ]]; then
      echo "${OURBOX_INSTALLER_SSH_USER}:${OURBOX_INSTALLER_SSH_PASSWORD_HASH}" | chpasswd -e >/dev/null 2>&1 || true
    fi
  else
    passwd -l "${OURBOX_INSTALLER_SSH_USER}" >/dev/null 2>&1 || true
  fi

  SSH_HOME="$(awk -F: -v u="${OURBOX_INSTALLER_SSH_USER}" '$1==u {print $6; exit}' /etc/passwd 2>/dev/null || true)"
  if [[ -z "${SSH_HOME}" ]]; then
    SSH_HOME="/home/${OURBOX_INSTALLER_SSH_USER}"
  fi
  SSH_GROUP="$(id -gn "${OURBOX_INSTALLER_SSH_USER}" 2>/dev/null || printf '%s' "${OURBOX_INSTALLER_SSH_USER}")"
  SSH_DIR="${SSH_HOME}/.ssh"
  SSH_AUTH_KEYS="${SSH_DIR}/authorized_keys"

  install -d -m 0700 "${SSH_DIR}"
  chown "${OURBOX_INSTALLER_SSH_USER}:${SSH_GROUP}" "${SSH_DIR}"

  if [[ "${OURBOX_INSTALLER_SSH_MODE}" == "key" || "${OURBOX_INSTALLER_SSH_MODE}" == "both" ]]; then
    if [[ -n "${OURBOX_INSTALLER_SSH_AUTHORIZED_KEYS}" ]]; then
      printf '%s\n' "${OURBOX_INSTALLER_SSH_AUTHORIZED_KEYS}" > "${SSH_AUTH_KEYS}"
      chown "${OURBOX_INSTALLER_SSH_USER}:${SSH_GROUP}" "${SSH_AUTH_KEYS}"
      chmod 0600 "${SSH_AUTH_KEYS}"
    else
      rm -f "${SSH_AUTH_KEYS}"
    fi
  else
    rm -f "${SSH_AUTH_KEYS}"
  fi
fi

mkdir -p /etc/ssh/sshd_config.d
{
  if [[ "${OURBOX_INSTALLER_SSH_ALLOW_ROOT}" == "1" ]]; then
    if [[ "${OURBOX_INSTALLER_SSH_MODE}" == "password" || "${OURBOX_INSTALLER_SSH_MODE}" == "both" ]]; then
      echo "PermitRootLogin prohibit-password"
    else
      echo "PermitRootLogin yes"
    fi
  else
    echo "PermitRootLogin no"
  fi
  if [[ "${OURBOX_INSTALLER_SSH_MODE}" == "password" || "${OURBOX_INSTALLER_SSH_MODE}" == "both" ]]; then
    echo "PasswordAuthentication yes"
  else
    echo "PasswordAuthentication no"
  fi
  echo "PubkeyAuthentication yes"
  echo "KbdInteractiveAuthentication no"
  echo "X11Forwarding no"
  echo "AllowTcpForwarding no"
  if [[ "${OURBOX_INSTALLER_SSH_MODE}" == "off" ]]; then
    if [[ "${OURBOX_INSTALLER_SSH_ALLOW_ROOT}" == "1" ]]; then
      echo "AllowUsers root"
    else
      echo "AllowUsers nobody"
    fi
  else
    if [[ "${OURBOX_INSTALLER_SSH_ALLOW_ROOT}" == "1" ]]; then
      echo "AllowUsers ${OURBOX_INSTALLER_SSH_USER} root"
    else
      echo "AllowUsers ${OURBOX_INSTALLER_SSH_USER}"
    fi
  fi
} > /etc/ssh/sshd_config.d/60-ourbox-installer.conf

: "${OS_REPO:=ghcr.io/techofourown/ourbox-matchbox-os}"
if [[ -z "${INSTALL_DEFAULTS_REF+x}" ]]; then
  INSTALL_DEFAULTS_REF="ghcr.io/techofourown/sw-ourbox-os/install-defaults:stable"
fi
: "${INSTALLER_ID:=matchbox}"
: "${OS_TARGET:=rpi}"
: "${OS_CHANNEL:=stable}"
: "${OS_DEFAULT_REF:=}"
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
# If available, this can override OS_REPO/channel tags/default ref at install time.
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

# Artifact type used when pushing OS payloads via ORAS.
EOF
  emit_shell_assignment "OS_ARTIFACT_TYPE" "${OS_ARTIFACT_TYPE}"
  cat <<'EOF'

# ORAS version to bootstrap on the installer if missing.
EOF
  emit_shell_assignment "OS_ORAS_VERSION" "${OS_ORAS_VERSION}"
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
