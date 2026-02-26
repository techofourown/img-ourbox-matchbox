#!/usr/bin/env bash
set -euo pipefail

log(){ printf '[%s] %s\n' "$(date -Is)" "$*"; }
die(){ log "ERROR: $*"; exit 1; }

if [[ ${EUID} -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo -E -- "$0" "$@"
  fi
  die "must run as root (sudo not found)"
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSIONS_ENV="${ROOT}/tools/versions.env"

if [[ -f "${VERSIONS_ENV}" ]]; then
  # shellcheck disable=SC1090
  source "${VERSIONS_ENV}"
fi

: "${BUILDKIT_VERSION:=v0.23.2}"
: "${ORAS_VERSION:=1.3.0}"

pkg_install_apt() {
  export DEBIAN_FRONTEND=noninteractive
  log "Using apt-get"
  apt-get update -y

  # Basics we rely on throughout the runbook
  apt-get install -y \
    ca-certificates curl git openssl \
    xz-utils \
    parted \
    util-linux \
    coreutils \
    e2fsprogs

  # Podman (rootful is what we use; rootless deps included because they're cheap and reduce surprises)
  apt-get install -y \
    podman \
    uidmap slirp4netns fuse-overlayfs

  # If you build ARM images on x86_64, you need qemu/binfmt.
  if [[ "$(uname -m)" == "x86_64" ]]; then
    apt-get install -y qemu-user-static binfmt-support
  fi
}

pkg_install_dnf() {
  log "Using dnf"
  dnf -y install \
    ca-certificates curl git openssl \
    xz \
    parted \
    util-linux coreutils \
    e2fsprogs \
    podman \
    fuse-overlayfs slirp4netns shadow-utils

  if [[ "$(uname -m)" == "x86_64" ]]; then
    dnf -y install qemu-user-static
  fi
}

install_packages() {
  if command -v apt-get >/dev/null 2>&1; then
    pkg_install_apt
    return
  fi
  if command -v dnf >/dev/null 2>&1; then
    pkg_install_dnf
    return
  fi
  die "unsupported distro: need apt-get or dnf (please install podman + curl + git manually, then rerun)"
}

map_arch() {
  local m
  m="$(uname -m)"
  case "${m}" in
    x86_64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) die "unsupported architecture: ${m} (need x86_64 or arm64/aarch64)" ;;
  esac
}

install_buildkit() {
  # We pin BuildKit and install from GitHub releases so it works across distros.
  # Idempotent: if the requested version is already installed, we skip.
  local arch url tmpdir
  arch="$(map_arch)"
  url="https://github.com/moby/buildkit/releases/download/${BUILDKIT_VERSION}/buildkit-${BUILDKIT_VERSION}.linux-${arch}.tar.gz"

  if command -v buildkitd >/dev/null 2>&1; then
    local current
    current="$(buildkitd --version 2>/dev/null || true)"
    if echo "${current}" | grep -q "${BUILDKIT_VERSION}"; then
      log "BuildKit already installed (${current}); skipping"
      return
    fi
    log "BuildKit present but not ${BUILDKIT_VERSION} (${current}); upgrading to pinned version"
  else
    log "Installing BuildKit ${BUILDKIT_VERSION}"
  fi

  tmpdir="$(mktemp -d)"

  # Capture the directory path now (when setting the trap), so the EXIT trap
  # does not depend on the tmpdir variable still being in-scope later.
  trap 'rm -rf "'"${tmpdir}"'"' EXIT

  log "Downloading: ${url}"
  curl -fsSL -o "${tmpdir}/buildkit.tgz" "${url}"

  tar -C "${tmpdir}" -xzf "${tmpdir}/buildkit.tgz"

  # The tarball contains bin/buildkitd and bin/buildctl
  install -m 0755 "${tmpdir}/bin/buildkitd" /usr/local/bin/buildkitd
  install -m 0755 "${tmpdir}/bin/buildctl"  /usr/local/bin/buildctl

  log "BuildKit installed:"
  /usr/local/bin/buildkitd --version
  /usr/local/bin/buildctl  --version
}

install_oras() {
  local arch url tmpdir
  arch="$(map_arch)" # returns amd64 or arm64
  url="https://github.com/oras-project/oras/releases/download/v${ORAS_VERSION}/oras_${ORAS_VERSION}_linux_${arch}.tar.gz"

  if command -v oras >/dev/null 2>&1; then
    local current
    current="$(oras version 2>/dev/null || true)"
    if echo "${current}" | grep -q "Version: *${ORAS_VERSION}"; then
      log "ORAS already installed (${current}); skipping"
      return
    fi
    log "ORAS present but not v${ORAS_VERSION}; upgrading"
  else
    log "Installing ORAS v${ORAS_VERSION}"
  fi

  tmpdir="$(mktemp -d)"
  trap 'rm -rf '"'"'"'${tmpdir}'"'"'"'' EXIT

  curl -fsSL -o "${tmpdir}/oras.tgz" "${url}"
  tar -C "${tmpdir}" -xzf "${tmpdir}/oras.tgz" oras
  install -m 0755 "${tmpdir}/oras" /usr/local/bin/oras

  log "ORAS installed: $(oras version || true)"
}

configure_buildkit_service_systemd() {
  # Optional but helpful: keep buildkitd available as a daemon.
  # We only do this if systemd is present.
  if ! command -v systemctl >/dev/null 2>&1; then
    log "systemctl not found; skipping buildkitd service install"
    return
  fi

  mkdir -p /etc/systemd/system

  cat > /etc/systemd/system/buildkit.service <<'UNIT'
[Unit]
Description=BuildKit daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=/bin/mkdir -p /run/buildkit
ExecStart=/usr/local/bin/buildkitd --addr unix:///run/buildkit/buildkitd.sock
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable --now buildkit.service || true

  log "BuildKit service status:"
  systemctl --no-pager --full status buildkit.service || true
}

verify_tools() {
  command -v podman >/dev/null 2>&1 || die "podman missing after install"
  command -v buildctl >/dev/null 2>&1 || die "buildctl missing after install"
  command -v buildkitd >/dev/null 2>&1 || die "buildkitd missing after install"

  log "podman:  $(podman --version || true)"
  log "buildctl: $(buildctl --version || true)"
  log "buildkitd: $(buildkitd --version || true)"
}

main() {
  log "Bootstrapping host dependencies (Podman + BuildKit + basics)"
  install_packages
  install_buildkit
  install_oras
  configure_buildkit_service_systemd
  verify_tools

  log "Bootstrap complete."
  log "Next: run ./tools/ops-e2e.sh"
}

main "$@"
