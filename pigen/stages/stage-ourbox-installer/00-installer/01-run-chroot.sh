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
    echo "PermitRootLogin yes"
  else
    echo "PermitRootLogin no"
  fi
  echo "PasswordAuthentication no"
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
  if [[ "${OURBOX_INSTALLER_SSH_MODE}" == "password" || "${OURBOX_INSTALLER_SSH_MODE}" == "both" ]]; then
    echo
    echo "Match User ${OURBOX_INSTALLER_SSH_USER}"
    echo "  PasswordAuthentication yes"
  fi
} > /etc/ssh/sshd_config.d/60-ourbox-installer.conf

chmod 0755 /opt/ourbox/tools/ourbox-install
chmod 0644 /opt/ourbox/tools/lib.sh

systemctl enable ssh
systemctl enable ourbox-installer.service
