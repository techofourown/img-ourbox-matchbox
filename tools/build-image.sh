#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "${ROOT}/tools/lib.sh"

cleanup_loopdevs_on_exit() {
  local rc=$?
  trap - EXIT
  "${ROOT}/tools/sanitize-loopdevs.sh" || true
  exit "${rc}"
}
trap cleanup_loopdevs_on_exit EXIT

# Always operate from repo root so any relative paths (including vendor/pi-gen) are stable.
cd "${ROOT}"

# pi-gen's docker wrapper writes logs to ./deploy (e.g. deploy/build-docker.log).
# On a fresh clone, deploy/ may not exist; create it up-front so the build can't fail at the end.
mkdir -p "${ROOT}/deploy"
# Ensure deploy/ is writable by the invoking user (pi-gen may run under sudo and leave root-owned outputs).
if [[ ! -w "${ROOT}/deploy" ]]; then
  if command -v sudo >/dev/null 2>&1; then
    log "deploy/ not writable; fixing ownership with sudo"
    sudo chown -R "$(id -u):$(id -g)" "${ROOT}/deploy"
  fi
fi

[[ -w "${ROOT}/deploy" ]] || die "deploy/ is not writable: ${ROOT}/deploy (fix ownership/permissions and rerun)"
log "Ensured deploy dir exists: ${ROOT}/deploy"

LOCK_FILE="${ROOT}/deploy/ourbox-build.lock"
exec 9>"${LOCK_FILE}"
flock -n 9 || die "another build is already running (lock: ${LOCK_FILE})"

# Marker to detect build outputs from this run (prevents stale artifacts).
BUILD_MARKER="${ROOT}/deploy/.build-start"
: > "${BUILD_MARKER}"
# shellcheck disable=SC1091
source "${ROOT}/tools/registry.sh"

# Pick a container CLI (caller can override with DOCKER=...)
DOCKER="${DOCKER:-$(pick_container_cli)}"
export DOCKER

SUDO=""
if [[ ${EUID} -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
  SUDO="sudo -E"
fi

# If we're using nerdctl, we need buildkitd running.
ensure_buildkitd

log "Preflight: validating loop-device health before build"
"${ROOT}/tools/preflight-build-host.sh"

# Ensure build dependencies are pulled from OUR registry and tagged to the names vendor expects.
"${ROOT}/tools/pull-required-images.sh"

# Defaults (override by prefixing env vars when invoking)
: "${OURBOX_TARGET:=rpi}"
: "${OURBOX_MODEL_ID:=TOO-OBX-MBX-01}"
: "${OURBOX_SKU_ID:=TOO-OBX-MBX-BASE-001}"
: "${OURBOX_VARIANT:=prod}"
: "${OURBOX_VERSION:=dev}"

# Compatibility bridge: OURBOX_SKU points to the SKU_ID for internal use
OURBOX_SKU="${OURBOX_SKU_ID}"

# Mount the repo so STAGE_LIST can reference /ourbox/...
# Also suppress the upstream stage2 export so we only ship the OurBox artifact.
export PIGEN_DOCKER_OPTS="${PIGEN_DOCKER_OPTS:-} \
  --volume ${ROOT}:/ourbox:ro \
  --volume ${ROOT}/pigen/overrides/stage2/SKIP_IMAGES:/pi-gen/stage2/SKIP_IMAGES:ro \
  -e OURBOX_TARGET=${OURBOX_TARGET} \
  -e OURBOX_MODEL_ID=${OURBOX_MODEL_ID} \
  -e OURBOX_SKU_ID=${OURBOX_SKU_ID} \
  -e OURBOX_SKU=${OURBOX_SKU} \
  -e OURBOX_VARIANT=${OURBOX_VARIANT} \
  -e OURBOX_VERSION=${OURBOX_VERSION}"

log "Preflight: checking for legacy naming terms"
"${ROOT}/tools/check_legacy_terms.sh"

log "Preflight: verifying airgap artifacts exist"
[[ -x "${ROOT}/artifacts/airgap/k3s/k3s" ]] || die "missing k3s binary; run ./tools/fetch-airgap-platform.sh"
[[ -f "${ROOT}/artifacts/airgap/k3s/k3s-airgap-images-arm64.tar" ]] || die "missing k3s airgap tar; run ./tools/fetch-airgap-platform.sh"
[[ -f "${ROOT}/artifacts/airgap/manifest.env" ]] || die "missing airgap manifest.env; run ./tools/fetch-airgap-platform.sh"
if ! compgen -G "${ROOT}/artifacts/airgap/platform/images/*.tar" >/dev/null; then
  die "missing platform image tars; run ./tools/fetch-airgap-platform.sh"
fi

if $DOCKER ps -a --format '{{.Names}}' 2>/dev/null | grep -qx 'pigen_work'; then
  log "Removing stale pi-gen container: pigen_work"
  $DOCKER rm -f -v pigen_work >/dev/null 2>&1 || true
fi

log "Preflight: sanitizing host loop devices to protect pi-gen export-image"
"${ROOT}/tools/sanitize-loopdevs.sh"

if [[ "$(cli_base "${DOCKER}")" == "podman" && "${DOCKER}" == *" "* && -n "${SUDO}" ]]; then
  log "NOTE: running pi-gen under sudo with DOCKER=podman (avoids sudo-in-DOCKER quoting issues)"
  DOCKER=podman ${SUDO} "${ROOT}/vendor/pi-gen/build-docker.sh" -c "${ROOT}/pigen/config/ourbox.conf"
else
  "${ROOT}/vendor/pi-gen/build-docker.sh" -c "${ROOT}/pigen/config/ourbox.conf"
fi

# Normalize outputs into deploy/ (pi-gen can drop artifacts in repo root).
log "Collecting build artifacts into ${ROOT}/deploy (normalizing pi-gen output paths)"

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
  die "Failed to move ${src} -> ${dst} (permission denied; sudo not available)"
}

shopt -s nullglob
for f in "${ROOT}"/img-*; do
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

# build.log often lands at repo root; copy it into deploy/ for publishing convenience.
if [[ -f "${ROOT}/build.log" && "${ROOT}/build.log" -nt "${BUILD_MARKER}" ]]; then
  if cp -f "${ROOT}/build.log" "${ROOT}/deploy/build.log" 2>/dev/null; then
    :
  elif command -v sudo >/dev/null 2>&1; then
    sudo cp -f "${ROOT}/build.log" "${ROOT}/deploy/build.log" >/dev/null 2>&1 || true
  fi
fi

# Normalize ownership so subsequent tools (publish, etc.) can write into deploy/ without sudo.
if command -v sudo >/dev/null 2>&1; then
  sudo chown -R "$(id -u):$(id -g)" "${ROOT}/deploy" >/dev/null 2>&1 || true
fi

log "Postflight: validating deploy outputs"
# shellcheck disable=SC2012
IMG_XZ="$(ls -1t "${ROOT}/deploy"/img-*.img.xz 2>/dev/null | head -n 1 || true)"
[[ -n "${IMG_XZ}" && -f "${IMG_XZ}" ]] || die "build did not produce deploy/img-*.img.xz"
[[ "${IMG_XZ}" -nt "${BUILD_MARKER}" ]] || die "deploy/img-*.img.xz exists but is not from this build (stale artifact)"

need_cmd xz
xz -t "${IMG_XZ}"

log "Build OK: ${IMG_XZ}"
log "Next: ./tools/publish-os-artifact.sh deploy"
