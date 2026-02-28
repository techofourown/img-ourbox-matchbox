#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "${ROOT}/tools/lib.sh"
# shellcheck disable=SC1091
source "${ROOT}/tools/registry.sh"

cleanup_loopdevs_on_exit() {
  local rc=$?
  trap - EXIT
  "${ROOT}/tools/sanitize-loopdevs.sh" || true
  exit "${rc}"
}
trap cleanup_loopdevs_on_exit EXIT

: "${OURBOX_TARGET:=rpi}"

cd "${ROOT}"
mkdir -p "${ROOT}/deploy"
if [[ ! -w "${ROOT}/deploy" ]]; then
  if command -v sudo >/dev/null 2>&1; then
    log "deploy/ not writable; fixing ownership with sudo"
    sudo chown -R "$(id -u):$(id -g)" "${ROOT}/deploy"
  fi
fi
[[ -w "${ROOT}/deploy" ]] || die "deploy/ is not writable: ${ROOT}/deploy"

log "Preflight: validating loop-device health before build"
"${ROOT}/tools/preflight-build-host.sh"

LOCK_FILE="${ROOT}/deploy/ourbox-build.lock"
exec 9>"${LOCK_FILE}"
flock -n 9 || die "another build is already running (lock: ${LOCK_FILE})"

BUILD_MARKER="${ROOT}/deploy/.build-installer-start"
: > "${BUILD_MARKER}"

DOCKER="${DOCKER:-$(pick_container_cli)}"
export DOCKER
SUDO=""
if [[ ${EUID} -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
  SUDO="sudo -E"
fi

ensure_buildkitd

: "${OURBOX_MODEL_ID:=TOO-OBX-MBX-01}"
: "${OURBOX_SKU_ID:=TOO-OBX-MBX-BASE-001}"
: "${OURBOX_VARIANT:=dev}"
: "${OURBOX_VERSION:=dev}"

export PIGEN_DOCKER_OPTS="${PIGEN_DOCKER_OPTS:-} \
  --volume ${ROOT}:/ourbox:ro \
  --volume ${ROOT}/pigen/overrides/stage2/SKIP_IMAGES:/pi-gen/stage2/SKIP_IMAGES:ro \
  --volume ${ROOT}/pigen/overrides/export-image/01-user-rename/SKIP:/pi-gen/export-image/01-user-rename/SKIP:ro \
  -e OURBOX_VARIANT=${OURBOX_VARIANT} \
  -e OURBOX_VERSION=${OURBOX_VERSION} \
  -e OURBOX_MODEL_ID=${OURBOX_MODEL_ID} \
  -e OURBOX_SKU_ID=${OURBOX_SKU_ID} \
  -e OURBOX_TARGET=${OURBOX_TARGET}"

if $DOCKER ps -a --format '{{.Names}}' 2>/dev/null | grep -qx 'pigen_work'; then
  log "Removing stale pi-gen container: pigen_work"
  $DOCKER rm -f -v pigen_work >/dev/null 2>&1 || true
fi

log "Preflight: sanitizing host loop devices to protect pi-gen export-image"
"${ROOT}/tools/sanitize-loopdevs.sh"

if [[ "$(cli_base "${DOCKER}")" == "podman" && "${DOCKER}" == *" "* && -n "${SUDO}" ]]; then
  DOCKER=podman ${SUDO} "${ROOT}/vendor/pi-gen/build-docker.sh" -c "${ROOT}/pigen/config/ourbox-installer.conf"
else
  "${ROOT}/vendor/pi-gen/build-docker.sh" -c "${ROOT}/pigen/config/ourbox-installer.conf"
fi

move_into_deploy() {
  local src="$1"
  local dst
  dst="${ROOT}/deploy/$(basename "${src}")"

  if mv -f "${src}" "${dst}" 2>/dev/null; then
    return 0
  fi
  if command -v sudo >/dev/null 2>&1; then
    sudo mv -f "${src}" "${dst}"
    return 0
  fi
  die "failed to move ${src} -> ${dst}"
}

shopt -s nullglob
for f in "${ROOT}"/*installer-ourbox-matchbox-"${OURBOX_TARGET,,}"-*; do
  [[ -f "${f}" ]] || continue
  [[ "${f}" -nt "${BUILD_MARKER}" ]] || continue
  case "${f}" in
    *.img.xz|*.img|*.zip|*.info|*.bmap|*.sha256)
      log "Moving artifact: $(basename "${f}") -> deploy/"
      move_into_deploy "${f}"
      ;;
  esac
done
shopt -u nullglob

if [[ -f "${ROOT}/build.log" && "${ROOT}/build.log" -nt "${BUILD_MARKER}" ]]; then
  if cp -f "${ROOT}/build.log" "${ROOT}/deploy/build-installer.log" 2>/dev/null; then
    :
  elif command -v sudo >/dev/null 2>&1; then
    sudo cp -f "${ROOT}/build.log" "${ROOT}/deploy/build-installer.log" >/dev/null 2>&1 || true
  fi
fi

if command -v sudo >/dev/null 2>&1; then
  sudo chown -R "$(id -u):$(id -g)" "${ROOT}/deploy" >/dev/null 2>&1 || true
fi

# shellcheck disable=SC2012
installer_img="$(ls -1t "${ROOT}"/deploy/*installer-ourbox-matchbox-"${OURBOX_TARGET,,}"-*.img.xz 2>/dev/null | head -n 1 || true)"

if [[ -z "${installer_img}" || ! -f "${installer_img}" ]]; then
  log "ERROR: installer artifact not found where expected."
  log "Searched: ${ROOT}/deploy/*installer-ourbox-matchbox-${OURBOX_TARGET,,}-*.img.xz"
  log "Deploy dir contents:"
  ls -lah "${ROOT}/deploy" || true
  log "Repo root candidates (may exist if pi-gen wrote outside deploy/):"
  ls -lah "${ROOT}"/*installer-ourbox-matchbox-"${OURBOX_TARGET,,}"-* 2>/dev/null || true
  die "build did not produce an installer .img.xz artifact"
fi

[[ "${installer_img}" -nt "${BUILD_MARKER}" ]] || die "installer artifact is stale (not from this run): ${installer_img}"

xz -t "${installer_img}"
log "Installer image ready: ${installer_img}"
