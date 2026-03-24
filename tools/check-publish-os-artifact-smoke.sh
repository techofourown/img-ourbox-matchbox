#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tools/lib.sh"

need_cmd python3

RAW_CONTRACT_DIGEST="sha256:1111111111111111111111111111111111111111111111111111111111111111"
OVERRIDE_CONTRACT_DIGEST="sha256:2222222222222222222222222222222222222222222222222222222222222222"
FIXTURE_K3S_VERSION="v1.31.5+k3s1"

TMP="$(mktemp -d)"
DEPLOY_DIR="${TMP}/deploy"
BIN_DIR="${TMP}/bin"
STATE_DIR="${TMP}/state"
mkdir -p "${DEPLOY_DIR}" "${BIN_DIR}" "${STATE_DIR}"

CONTRACT_DIGEST_FILE="${ROOT}/pigen/stages/stage-ourbox-matchbox/02-ourbox-substrate/files/opt/ourbox/airgap/platform/contract.digest"
CONTRACT_ENV_FILE="${ROOT}/pigen/stages/stage-ourbox-matchbox/02-ourbox-substrate/files/opt/ourbox/airgap/platform/contract.env"
AIRGAP_MANIFEST="${ROOT}/artifacts/airgap/manifest.env"
AIRGAP_SELECTED_BUNDLE_ENV="${ROOT}/artifacts/airgap/selected-bundle.env"
AIRGAP_BUNDLE_DIGEST="sha256:3333333333333333333333333333333333333333333333333333333333333333"
AIRGAP_LOCK_SHA="4444444444444444444444444444444444444444444444444444444444444444"

had_contract_digest=0
had_contract_env=0
had_airgap_manifest=0
had_airgap_selected_bundle=0
backup_contract_digest="${TMP}/contract.digest.bak"
backup_contract_env="${TMP}/contract.env.bak"
backup_airgap_manifest="${TMP}/manifest.env.bak"
backup_airgap_selected_bundle="${TMP}/selected-bundle.env.bak"

cleanup() {
  if [[ "${had_contract_digest}" == "1" ]]; then
    cp -a "${backup_contract_digest}" "${CONTRACT_DIGEST_FILE}"
  else
    rm -f "${CONTRACT_DIGEST_FILE}"
  fi

  if [[ "${had_contract_env}" == "1" ]]; then
    cp -a "${backup_contract_env}" "${CONTRACT_ENV_FILE}"
  else
    rm -f "${CONTRACT_ENV_FILE}"
  fi

  if [[ "${had_airgap_manifest}" == "1" ]]; then
    cp -a "${backup_airgap_manifest}" "${AIRGAP_MANIFEST}"
  else
    rm -f "${AIRGAP_MANIFEST}"
  fi

  if [[ "${had_airgap_selected_bundle}" == "1" ]]; then
    cp -a "${backup_airgap_selected_bundle}" "${AIRGAP_SELECTED_BUNDLE_ENV}"
  else
    rm -f "${AIRGAP_SELECTED_BUNDLE_ENV}"
  fi

  rm -rf "${TMP}"
}
trap cleanup EXIT

if [[ -f "${CONTRACT_DIGEST_FILE}" ]]; then
  had_contract_digest=1
  cp -a "${CONTRACT_DIGEST_FILE}" "${backup_contract_digest}"
fi
if [[ -f "${CONTRACT_ENV_FILE}" ]]; then
  had_contract_env=1
  cp -a "${CONTRACT_ENV_FILE}" "${backup_contract_env}"
fi
if [[ -f "${AIRGAP_MANIFEST}" ]]; then
  had_airgap_manifest=1
  cp -a "${AIRGAP_MANIFEST}" "${backup_airgap_manifest}"
fi
if [[ -f "${AIRGAP_SELECTED_BUNDLE_ENV}" ]]; then
  had_airgap_selected_bundle=1
  cp -a "${AIRGAP_SELECTED_BUNDLE_ENV}" "${backup_airgap_selected_bundle}"
fi

mkdir -p "$(dirname "${CONTRACT_DIGEST_FILE}")" "$(dirname "${AIRGAP_MANIFEST}")"
printf '%s\n' "${RAW_CONTRACT_DIGEST}" > "${CONTRACT_DIGEST_FILE}"
cat > "${CONTRACT_ENV_FILE}" <<EOF
OURBOX_PLATFORM_CONTRACT_SOURCE=ghcr.io/techofourown/sw-ourbox-os/platform-contract@${RAW_CONTRACT_DIGEST}
OURBOX_PLATFORM_CONTRACT_REVISION=fixture-revision
OURBOX_PLATFORM_CONTRACT_VERSION=v0.0.0-fixture
OURBOX_PLATFORM_CONTRACT_CREATED=2026-03-09T00:00:00Z
EOF
cat > "${AIRGAP_MANIFEST}" <<EOF
OURBOX_SUBSTRATE_SOURCE=https://github.com/techofourown/sw-ourbox-os
OURBOX_SUBSTRATE_REVISION=fixture-airgap-revision
OURBOX_SUBSTRATE_VERSION=v0.0.0-airgap-fixture
OURBOX_SUBSTRATE_CREATED=2026-03-09T00:00:00Z
OURBOX_PLATFORM_CONTRACT_REF=ghcr.io/techofourown/sw-ourbox-os/platform-contract@${RAW_CONTRACT_DIGEST}
OURBOX_PLATFORM_CONTRACT_DIGEST=${RAW_CONTRACT_DIGEST}
OURBOX_SUBSTRATE_ARCH=arm64
K3S_VERSION=${FIXTURE_K3S_VERSION}
OURBOX_PLATFORM_PROFILE=demo-apps
OURBOX_PLATFORM_IMAGES_LOCK_PATH=platform/images.lock.json
OURBOX_PLATFORM_IMAGES_LOCK_SHA256=${AIRGAP_LOCK_SHA}
EOF
cat > "${AIRGAP_SELECTED_BUNDLE_ENV}" <<EOF
OURBOX_SUBSTRATE_REF=ghcr.io/techofourown/sw-ourbox-os/ourbox-substrate@${AIRGAP_BUNDLE_DIGEST}
OURBOX_SUBSTRATE_DIGEST=${AIRGAP_BUNDLE_DIGEST}
OURBOX_SUBSTRATE_SOURCE=https://github.com/techofourown/sw-ourbox-os
OURBOX_SUBSTRATE_REVISION=fixture-airgap-revision
OURBOX_SUBSTRATE_VERSION=v0.0.0-airgap-fixture
OURBOX_SUBSTRATE_CREATED=2026-03-09T00:00:00Z
OURBOX_SUBSTRATE_ARCH=arm64
OURBOX_SUBSTRATE_PROFILE=demo-apps
OURBOX_SUBSTRATE_K3S_VERSION=${FIXTURE_K3S_VERSION}
OURBOX_SUBSTRATE_IMAGES_LOCK_SHA256=${AIRGAP_LOCK_SHA}
OURBOX_PLATFORM_CONTRACT_REF=ghcr.io/techofourown/sw-ourbox-os/platform-contract@${RAW_CONTRACT_DIGEST}
OURBOX_PLATFORM_CONTRACT_DIGEST=${RAW_CONTRACT_DIGEST}
EOF

printf 'fixture os image\n' > "${DEPLOY_DIR}/img-ourbox-matchbox-rpi-fixture.img.xz"

export ORAS_STUB_STATE="${STATE_DIR}"
export ORAS_STUB_LOG="${STATE_DIR}/oras.log"
export ORAS_STUB_CATALOG_TAG="rpi-catalog"
cat > "${BIN_DIR}/oras" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

state="${ORAS_STUB_STATE:?}"
log="${ORAS_STUB_LOG:?}"
catalog_tag="${ORAS_STUB_CATALOG_TAG:?}"
mkdir -p "${state}"

cmd="${1:?}"
shift || true
printf '%s\t%s\n' "${cmd}" "$*" >> "${log}"

case "${cmd}" in
  pull)
    ref="${1:?}"
    if [[ "${ref}" == *":${catalog_tag}" ]]; then
      echo "manifest not found" >&2
      exit 1
    fi
    echo "unexpected oras pull: ${ref}" >&2
    exit 97
    ;;
  push)
    ref="${1:?}"
    if [[ "${ref}" == *":${catalog_tag}" ]]; then
      cp "catalog.tsv" "${state}/latest-catalog.tsv"
      printf 'Digest: sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n'
    else
      printf 'Digest: sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'
    fi
    ;;
  *)
    echo "unsupported oras command: ${cmd}" >&2
    exit 99
    ;;
esac
EOF
chmod +x "${BIN_DIR}/oras"

export PATH="${BIN_DIR}:${PATH}"
export OURBOX_GIT_SHA="0123456789ab"
export OURBOX_VERSION="test-publish-smoke"
export OURBOX_PLATFORM_CONTRACT_DIGEST="${OVERRIDE_CONTRACT_DIGEST}"

"${ROOT}/tools/publish-os-artifact.sh" "${DEPLOY_DIR}"

python3 - "${DEPLOY_DIR}/os-artifact.meta.json" "${DEPLOY_DIR}/os-artifact.publish.json" "${STATE_DIR}/latest-catalog.tsv" "${OVERRIDE_CONTRACT_DIGEST}" "${RAW_CONTRACT_DIGEST}" "${AIRGAP_BUNDLE_DIGEST}" "${AIRGAP_LOCK_SHA}" "${FIXTURE_K3S_VERSION}" <<'PY'
import json
import sys

meta_path, publish_path, catalog_path, override_digest, raw_digest, airgap_digest, lock_sha, k3s_version = sys.argv[1:]

with open(meta_path, "r", encoding="utf-8") as fh:
    meta = json.load(fh)
with open(publish_path, "r", encoding="utf-8") as fh:
    publish = json.load(fh)
with open(catalog_path, "r", encoding="utf-8") as fh:
    catalog = fh.read()

assert meta["OURBOX_PLATFORM_CONTRACT_DIGEST"] == override_digest
assert meta["OURBOX_SUBSTRATE_REF"] == f"ghcr.io/techofourown/sw-ourbox-os/ourbox-substrate@{airgap_digest}"
assert meta["OURBOX_SUBSTRATE_DIGEST"] == airgap_digest
assert meta["OURBOX_SUBSTRATE_SOURCE"] == "https://github.com/techofourown/sw-ourbox-os"
assert meta["OURBOX_SUBSTRATE_ARCH"] == "arm64"
assert meta["OURBOX_SUBSTRATE_PROFILE"] == "demo-apps"
assert meta["OURBOX_SUBSTRATE_K3S_VERSION"] == k3s_version
assert meta["OURBOX_SUBSTRATE_IMAGES_LOCK_SHA256"] == lock_sha
assert publish["control_fields"]["platform_contract_digest"] == override_digest
assert publish["meta_env"]["OURBOX_PLATFORM_CONTRACT_DIGEST"] == override_digest
assert publish["meta_env"]["OURBOX_SUBSTRATE_DIGEST"] == airgap_digest
assert publish["meta_env"]["OURBOX_SUBSTRATE_K3S_VERSION"] == k3s_version
assert override_digest in catalog
assert raw_digest not in catalog
assert "\nstable\t" in f"\n{catalog}"
assert "\nrpi-stable\t" not in f"\n{catalog}"
PY

grep -F "techofourown.platform-contract.digest=${OVERRIDE_CONTRACT_DIGEST}" "${ORAS_STUB_LOG}" >/dev/null \
  || die "ORAS push did not use the effective platform contract digest override"
if grep -F "techofourown.platform-contract.digest=${RAW_CONTRACT_DIGEST}" "${ORAS_STUB_LOG}" >/dev/null; then
  die "ORAS push used the raw contract digest instead of the effective override"
fi

log "OS publish smoke passed"
