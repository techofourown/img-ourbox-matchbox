#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tools/lib.sh"

need_cmd python3

FIXTURE_K3S_VERSION="v1.31.5+k3s1"

TMP="$(mktemp -d)"
DEPLOY_DIR="${TMP}/deploy"
BIN_DIR="${TMP}/bin"
STATE_DIR="${TMP}/state"
mkdir -p "${DEPLOY_DIR}" "${BIN_DIR}" "${STATE_DIR}"

SUBSTRATE_MANIFEST="${ROOT}/artifacts/substrate/manifest.env"
SUBSTRATE_SELECTED_BUNDLE_ENV="${ROOT}/artifacts/substrate/selected-bundle.env"
SUBSTRATE_BUNDLE_DIGEST="sha256:3333333333333333333333333333333333333333333333333333333333333333"
SUBSTRATE_LOCK_SHA="4444444444444444444444444444444444444444444444444444444444444444"

had_substrate_manifest=0
had_substrate_selected_bundle=0
backup_substrate_manifest="${TMP}/manifest.env.bak"
backup_substrate_selected_bundle="${TMP}/selected-bundle.env.bak"

cleanup() {
  if [[ "${had_substrate_manifest}" == "1" ]]; then
    cp -a "${backup_substrate_manifest}" "${SUBSTRATE_MANIFEST}"
  else
    rm -f "${SUBSTRATE_MANIFEST}"
  fi

  if [[ "${had_substrate_selected_bundle}" == "1" ]]; then
    cp -a "${backup_substrate_selected_bundle}" "${SUBSTRATE_SELECTED_BUNDLE_ENV}"
  else
    rm -f "${SUBSTRATE_SELECTED_BUNDLE_ENV}"
  fi

  rm -rf "${TMP}"
}
trap cleanup EXIT

if [[ -f "${SUBSTRATE_MANIFEST}" ]]; then
  had_substrate_manifest=1
  cp -a "${SUBSTRATE_MANIFEST}" "${backup_substrate_manifest}"
fi
if [[ -f "${SUBSTRATE_SELECTED_BUNDLE_ENV}" ]]; then
  had_substrate_selected_bundle=1
  cp -a "${SUBSTRATE_SELECTED_BUNDLE_ENV}" "${backup_substrate_selected_bundle}"
fi

mkdir -p "$(dirname "${SUBSTRATE_MANIFEST}")"
cat > "${SUBSTRATE_MANIFEST}" <<EOF
OURBOX_SUBSTRATE_SOURCE=https://github.com/techofourown/sw-ourbox-os
OURBOX_SUBSTRATE_REVISION=fixture-substrate-revision
OURBOX_SUBSTRATE_VERSION=v0.0.0-substrate-fixture
OURBOX_SUBSTRATE_CREATED=2026-03-09T00:00:00Z
OURBOX_SUBSTRATE_ARCH=arm64
K3S_VERSION=${FIXTURE_K3S_VERSION}
OURBOX_PLATFORM_PROFILE=demo-apps
OURBOX_PLATFORM_IMAGES_LOCK_PATH=platform/images.lock.json
OURBOX_PLATFORM_IMAGES_LOCK_SHA256=${SUBSTRATE_LOCK_SHA}
EOF
cat > "${SUBSTRATE_SELECTED_BUNDLE_ENV}" <<EOF
OURBOX_SUBSTRATE_REF=ghcr.io/techofourown/sw-ourbox-os/ourbox-substrate@${SUBSTRATE_BUNDLE_DIGEST}
OURBOX_SUBSTRATE_DIGEST=${SUBSTRATE_BUNDLE_DIGEST}
OURBOX_SUBSTRATE_SOURCE=https://github.com/techofourown/sw-ourbox-os
OURBOX_SUBSTRATE_REVISION=fixture-substrate-revision
OURBOX_SUBSTRATE_VERSION=v0.0.0-substrate-fixture
OURBOX_SUBSTRATE_CREATED=2026-03-09T00:00:00Z
OURBOX_SUBSTRATE_ARCH=arm64
OURBOX_SUBSTRATE_PROFILE=demo-apps
OURBOX_SUBSTRATE_K3S_VERSION=${FIXTURE_K3S_VERSION}
OURBOX_SUBSTRATE_IMAGES_LOCK_SHA256=${SUBSTRATE_LOCK_SHA}
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

"${ROOT}/tools/publish-os-artifact.sh" "${DEPLOY_DIR}"

python3 - "${DEPLOY_DIR}/os-artifact.meta.json" "${DEPLOY_DIR}/os-artifact.publish.json" "${STATE_DIR}/latest-catalog.tsv" "${SUBSTRATE_BUNDLE_DIGEST}" "${SUBSTRATE_LOCK_SHA}" "${FIXTURE_K3S_VERSION}" <<'PY'
import json
import sys

meta_path, publish_path, catalog_path, substrate_digest, lock_sha, k3s_version = sys.argv[1:]

with open(meta_path, "r", encoding="utf-8") as fh:
    meta = json.load(fh)
with open(publish_path, "r", encoding="utf-8") as fh:
    publish = json.load(fh)
with open(catalog_path, "r", encoding="utf-8") as fh:
    catalog = fh.read()

assert meta["OURBOX_SUBSTRATE_REF"] == f"ghcr.io/techofourown/sw-ourbox-os/ourbox-substrate@{substrate_digest}"
assert meta["OURBOX_SUBSTRATE_DIGEST"] == substrate_digest
assert meta["OURBOX_SUBSTRATE_SOURCE"] == "https://github.com/techofourown/sw-ourbox-os"
assert meta["OURBOX_SUBSTRATE_ARCH"] == "arm64"
assert meta["OURBOX_SUBSTRATE_PROFILE"] == "demo-apps"
assert meta["OURBOX_SUBSTRATE_K3S_VERSION"] == k3s_version
assert meta["OURBOX_SUBSTRATE_IMAGES_LOCK_SHA256"] == lock_sha
assert publish["meta_env"]["OURBOX_SUBSTRATE_DIGEST"] == substrate_digest
assert publish["meta_env"]["OURBOX_SUBSTRATE_K3S_VERSION"] == k3s_version
assert "\nstable\t" in f"\n{catalog}"
assert "\nrpi-stable\t" not in f"\n{catalog}"
PY

log "OS publish smoke passed"
