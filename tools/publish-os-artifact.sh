#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tools/lib.sh"
# shellcheck disable=SC1091
source "${ROOT}/tools/registry.sh"

need_cmd oras
need_cmd sha256sum
need_cmd date

DEPLOY_DIR="${1:-deploy}"
: "${OURBOX_TARGET:=rpi}"
: "${OURBOX_VARIANT:=prod}"
: "${OURBOX_VERSION:=dev}"
: "${OURBOX_SKU:=TOO-OBX-MBX-BASE-001}"
: "${OS_REPO:=ghcr.io/techofourown/ourbox-matchbox-os}"
: "${OS_ARTIFACT_TYPE:=application/vnd.techofourown.ourbox.matchbox.os-image.v1}"
: "${OS_CATALOG_TAG:=${OURBOX_TARGET}-catalog}"
: "${OS_CHANNEL_TAGS:=${OURBOX_TARGET}-stable}"   # space-separated moving tags to update (e.g., "rpi-stable rpi-beta")
: "${OS_REGISTRY_USERNAME:=}"
: "${OS_REGISTRY_PASSWORD:=}"
: "${OS_INCLUDE_BUILD_LOG:=0}"   # 1 to publish build.log as artifact attachment
CATALOG_HEADER=$'channel\ttag\tcreated\tversion\tvariant\ttarget\tsku\tgit_sha\tplatform_contract_digest\tk3s_version\timg_sha256\tartifact_digest\tpinned_ref'

# shellcheck disable=SC2012
IMG_XZ="$(ls -1t "${DEPLOY_DIR}"/img-ourbox-matchbox-"${OURBOX_TARGET,,}"-*.img.xz 2>/dev/null | head -n 1 || true)"
if [ -z "${IMG_XZ}" ] || [ ! -f "${IMG_XZ}" ]; then
  die "No ${DEPLOY_DIR}/img-ourbox-matchbox-${OURBOX_TARGET,,}-*.img.xz found. Did the build finish?"
fi

BASE="$(basename "${IMG_XZ}" .img.xz)"
OS_IMMUTABLE_TAG="${OS_IMMUTABLE_TAG:-${BASE}}"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

log "Preparing OS artifact payload for ${OS_REPO}"

cp "${IMG_XZ}" "${TMP}/os.img.xz"
SHA256="$(sha256sum "${TMP}/os.img.xz" | awk '{print $1}')"
SIZE_BYTES="$(stat -c%s "${TMP}/os.img.xz")"
cat > "${TMP}/os.img.xz.sha256" <<EOF
${SHA256}  os.img.xz
EOF

INFO="${DEPLOY_DIR}/${BASE}.info"
BLOG="${DEPLOY_DIR}/build.log"
if [ -f "${INFO}" ]; then cp "${INFO}" "${TMP}/os.info"; fi
if [[ "${OS_INCLUDE_BUILD_LOG}" == "1" ]]; then
  if [ -f "${BLOG}" ]; then cp "${BLOG}" "${TMP}/build.log"; fi
fi

CONTRACT_DIGEST_FILE="${ROOT}/pigen/stages/stage-ourbox-matchbox/02-airgap-platform/files/opt/ourbox/airgap/platform/contract.digest"
CONTRACT_ENV_FILE="${ROOT}/pigen/stages/stage-ourbox-matchbox/02-airgap-platform/files/opt/ourbox/airgap/platform/contract.env"
CONTRACT_DIGEST="$(cat "${CONTRACT_DIGEST_FILE}" 2>/dev/null || echo unknown)"
if [[ -f "${CONTRACT_ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${CONTRACT_ENV_FILE}"
fi

AIRGAP_MANIFEST="${ROOT}/artifacts/airgap/manifest.env"
if [[ -f "${AIRGAP_MANIFEST}" ]]; then
  # shellcheck disable=SC1090
  source "${AIRGAP_MANIFEST}"
fi
K3S_VERSION="${K3S_VERSION:-unknown}"

GIT_SHA="$(git -C "${ROOT}" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
BUILD_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

cat > "${TMP}/os.meta.env" <<EOF
OS_IMAGE_BASENAME=${BASE}
OS_IMAGE_SHA256=${SHA256}
OS_IMAGE_SIZE_BYTES=${SIZE_BYTES}
OS_ARTIFACT_TYPE=${OS_ARTIFACT_TYPE}
OURBOX_TARGET=${OURBOX_TARGET}
OURBOX_VARIANT=${OURBOX_VARIANT}
OURBOX_VERSION=${OURBOX_VERSION}
OURBOX_SKU=${OURBOX_SKU}
BUILD_TS=${BUILD_TS}
GIT_SHA=${GIT_SHA}
OURBOX_PLATFORM_CONTRACT_DIGEST=${OURBOX_PLATFORM_CONTRACT_DIGEST:-${CONTRACT_DIGEST}}
OURBOX_PLATFORM_CONTRACT_SOURCE=${OURBOX_PLATFORM_CONTRACT_SOURCE:-unknown}
OURBOX_PLATFORM_CONTRACT_REVISION=${OURBOX_PLATFORM_CONTRACT_REVISION:-unknown}
OURBOX_PLATFORM_CONTRACT_VERSION=${OURBOX_PLATFORM_CONTRACT_VERSION:-unknown}
OURBOX_PLATFORM_CONTRACT_CREATED=${OURBOX_PLATFORM_CONTRACT_CREATED:-unknown}
K3S_VERSION=${K3S_VERSION}
GITHUB_WORKFLOW=${GITHUB_WORKFLOW:-}
GITHUB_RUN_ID=${GITHUB_RUN_ID:-}
GITHUB_RUN_ATTEMPT=${GITHUB_RUN_ATTEMPT:-}
EOF

push_ref() {
  local tag="$1"
  local ref="${OS_REPO}:${tag}"
  log ">> Pushing ${ref}"
  local args=(
    "${ref}"
    --artifact-type "${OS_ARTIFACT_TYPE}"
    --annotation "org.opencontainers.image.source=https://github.com/techofourown/img-ourbox-matchbox"
    --annotation "org.opencontainers.image.revision=${GIT_SHA}"
    --annotation "org.opencontainers.image.version=${OURBOX_VERSION}"
    --annotation "org.opencontainers.image.created=${BUILD_TS}"
    --annotation "techofourown.artifact.kind=os-image"
    --annotation "techofourown.target=${OURBOX_TARGET}"
    --annotation "techofourown.variant=${OURBOX_VARIANT}"
    --annotation "techofourown.sku=${OURBOX_SKU}"
    --annotation "techofourown.platform-contract.digest=${CONTRACT_DIGEST}"
    --annotation "techofourown.build.workflow=${GITHUB_WORKFLOW:-local}"
    --annotation "techofourown.build.run-id=${GITHUB_RUN_ID:-local}"
    --annotation "techofourown.build.run-attempt=${GITHUB_RUN_ATTEMPT:-1}"
    "${TMP}/os.img.xz:application/octet-stream"
    "${TMP}/os.img.xz.sha256:text/plain"
    "${TMP}/os.meta.env:text/plain"
  )
  [[ -f "${TMP}/os.info" ]] && args+=("${TMP}/os.info:text/plain")
  [[ -f "${TMP}/build.log" ]] && args+=("${TMP}/build.log:text/plain")
  local out status digest
  set +e
  out="$(oras push "${args[@]}" 2>&1)"
  status=$?
  set -e
  printf '%s\n' "${out}"
  if [[ "${status}" -ne 0 ]]; then
    die "oras push failed for ${ref} (exit ${status})"
  fi
  digest="$(printf '%s\n' "${out}" | grep -Eo 'sha256:[0-9a-f]{64}' | tail -n1)"
  [[ -n "${digest}" ]] || die "Failed to capture digest from oras output for ${ref}"
  LAST_PUSH_DIGEST="${digest}"
  log ">> Digest ${tag}: ${digest}"
}

maybe_login() {
  if [[ -n "${OS_REGISTRY_USERNAME}" ]]; then
    local registry="${OS_REPO%%/*}"
    log "Logging into ${registry} for publish"
    oras login "${registry}" -u "${OS_REGISTRY_USERNAME}" --password "${OS_REGISTRY_PASSWORD:-}"
  fi
}

update_catalog() {
  local channel_tag="$1" immutable_tag="$2" immutable_digest="$3"
  local catalog_tmp="${TMP}/catalog"
  local catalog_file="${catalog_tmp}/catalog.tsv"
  local pinned_ref="${OS_REPO}@${immutable_digest}"
  rm -rf "${catalog_tmp}"
  mkdir -p "${catalog_tmp}"

  local catalog_ref="${OS_REPO}:${OS_CATALOG_TAG}"
  if oras pull "${catalog_ref}" -o "${catalog_tmp}" >/dev/null 2>&1; then
    log "Catalog pulled: ${catalog_ref}"
  else
    printf '%s\n' "${CATALOG_HEADER}" > "${catalog_file}"
  fi

  [[ -f "${catalog_file}" ]] || printf '%s\n' "${CATALOG_HEADER}" > "${catalog_file}"
  {
    printf '%s\n' "${CATALOG_HEADER}"
    tail -n +2 "${catalog_file}" 2>/dev/null || true
  } > "${catalog_file}.tmp"
  mv "${catalog_file}.tmp" "${catalog_file}"

  local channel="${channel_tag:-custom}"
  # Replace only an existing row with the same (channel, tag).
  awk -F '\t' -v ch="${channel}" -v tag="${immutable_tag}" '
    NR == 1 { print; next }
    !($1 == ch && $2 == tag) { print }
  ' "${catalog_file}" > "${catalog_file}.tmp"
  mv "${catalog_file}.tmp" "${catalog_file}"

  echo -e "${channel}\t${immutable_tag}\t${BUILD_TS}\t${OURBOX_VERSION}\t${OURBOX_VARIANT}\t${OURBOX_TARGET}\t${OURBOX_SKU}\t${GIT_SHA}\t${CONTRACT_DIGEST}\t${K3S_VERSION}\t${SHA256}\t${immutable_digest}\t${pinned_ref}" >> "${catalog_file}"

  log ">> Updating catalog: ${catalog_ref}"
  oras push "${catalog_ref}" \
    --artifact-type "application/vnd.techofourown.ourbox.matchbox.os-catalog.v1" \
    "${catalog_file}:text/tab-separated-values"
}

# Push immutable tag first
maybe_login
LAST_PUSH_DIGEST=""
push_ref "${OS_IMMUTABLE_TAG}"
IMMUTABLE_DIGEST="${LAST_PUSH_DIGEST}"
IMMUTABLE_PINNED_REF="${OS_REPO}@${IMMUTABLE_DIGEST}"
echo "${OS_REPO}:${OS_IMMUTABLE_TAG}" > "${DEPLOY_DIR}/os-artifact.ref"
echo "${IMMUTABLE_PINNED_REF}" > "${DEPLOY_DIR}/os-artifact.pinned.ref"
echo "${IMMUTABLE_DIGEST}" > "${DEPLOY_DIR}/os-artifact.digest"

# Then moving channel tags (optional)
for ch in ${OS_CHANNEL_TAGS}; do
  push_ref "${ch}"
  update_catalog "${ch}" "${OS_IMMUTABLE_TAG}" "${IMMUTABLE_DIGEST}"
done

log "DONE: published ${OS_IMMUTABLE_TAG} (and channels: ${OS_CHANNEL_TAGS:-none}) to ${OS_REPO}"
