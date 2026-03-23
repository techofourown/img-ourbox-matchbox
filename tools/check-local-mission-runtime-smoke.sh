#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tools/lib.sh"

need_cmd python3
need_cmd sha256sum
need_cmd tar

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

TOOLS_DIR="${TMP}/tools"
INSTALLER_SCRIPT="${TMP}/ourbox-install"
MISSION_ROOT="${TMP}/mission"
MISSION_OS_DIR="${MISSION_ROOT}/artifacts/os"
MISSION_AIRGAP_DIR="${MISSION_ROOT}/artifacts/airgap"
AIRGAP_SOURCE_DIR="${TMP}/airgap-source"
AIRGAP_EXTRACT_DIR="${TMP}/airgap-extract"

mkdir -p "${TOOLS_DIR}" "${MISSION_OS_DIR}" "${MISSION_AIRGAP_DIR}" \
  "${AIRGAP_SOURCE_DIR}/k3s" "${AIRGAP_SOURCE_DIR}/platform/images"

cp "${ROOT}/tools/lib.sh" "${TOOLS_DIR}/lib.sh"
cp "${ROOT}/tools/matchbox-storage-flow.sh" "${TOOLS_DIR}/matchbox-storage-flow.sh"
cp "${ROOT}/pigen/stages/stage-ourbox-installer/00-installer/files/opt/ourbox/tools/ourbox-install" "${INSTALLER_SCRIPT}"

PLATFORM_DIGEST="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
OS_DIGEST="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
AIRGAP_DIGEST="sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

printf 'fixture os payload\n' > "${MISSION_OS_DIR}/os-payload.tar.xz"
printf '%s  %s\n' \
  "$(sha256sum "${MISSION_OS_DIR}/os-payload.tar.xz" | awk '{print $1}')" \
  "os-payload.tar.xz" > "${MISSION_OS_DIR}/os-payload.tar.xz.sha256"
cat > "${MISSION_OS_DIR}/os.meta.env" <<EOF
OURBOX_PLATFORM_CONTRACT_DIGEST=${PLATFORM_DIGEST}
EOF

cat > "${AIRGAP_SOURCE_DIR}/manifest.env" <<EOF
OURBOX_SUBSTRATE_SOURCE=https://github.com/example/sw-ourbox-os
OURBOX_SUBSTRATE_REVISION=fixture-revision
OURBOX_SUBSTRATE_VERSION=v0.0.1
OURBOX_SUBSTRATE_CREATED=2026-03-23T00:00:00Z
OURBOX_PLATFORM_CONTRACT_DIGEST=${PLATFORM_DIGEST}
OURBOX_SUBSTRATE_ARCH=arm64
K3S_VERSION=v1.35.0+k3s1
OURBOX_PLATFORM_PROFILE=demo-apps
OURBOX_PLATFORM_IMAGES_LOCK_PATH=platform/images.lock.json
OURBOX_PLATFORM_IMAGES_LOCK_SHA256=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
EOF
printf '#!/bin/sh\nexit 0\n' > "${AIRGAP_SOURCE_DIR}/k3s/k3s"
chmod +x "${AIRGAP_SOURCE_DIR}/k3s/k3s"
printf 'fixture airgap images\n' > "${AIRGAP_SOURCE_DIR}/k3s/k3s-airgap-images-arm64.tar"
printf '{"images":[]}\n' > "${AIRGAP_SOURCE_DIR}/platform/images.lock.json"
printf 'PROFILE=demo-apps\n' > "${AIRGAP_SOURCE_DIR}/platform/profile.env"
printf 'fixture image tar\n' > "${AIRGAP_SOURCE_DIR}/platform/images/platform-demo.tar"
tar -C "${AIRGAP_SOURCE_DIR}" -czf "${MISSION_AIRGAP_DIR}/airgap-platform.tar.gz" k3s platform manifest.env
cp "${AIRGAP_SOURCE_DIR}/manifest.env" "${MISSION_AIRGAP_DIR}/manifest.env"

cat > "${MISSION_ROOT}/mission-manifest.json" <<EOF
{
  "kind": "ourbox-mission",
  "target": {
    "id": "matchbox",
    "media_kind": "installer-image"
  },
  "platform_contract": {
    "digest": "${PLATFORM_DIGEST}"
  },
  "requested": {
    "os": {
      "selection_source": "catalog",
      "release_channel": "stable",
      "requested_ref": ""
    },
    "airgap": {
      "selection_mode": "host-selected",
      "selection_source": "application-catalogs",
      "release_channel": "",
      "requested_ref": ""
    }
  },
  "resolved": {
    "os": {
      "selection_source": "catalog",
      "release_channel": "stable",
      "artifact_ref": "ghcr.io/example/ourbox-matchbox-os@${OS_DIGEST}",
      "artifact_digest": "${OS_DIGEST}",
      "payload": {
        "relpath": "artifacts/os/os-payload.tar.xz"
      },
      "metadata_relpath": "artifacts/os/os.meta.env"
    },
    "airgap": {
      "selection_mode": "host-selected",
      "selection_source": "application-catalogs",
      "release_channel": "",
      "artifact_ref": "ghcr.io/example/airgap-platform@${AIRGAP_DIGEST}",
      "artifact_digest": "${AIRGAP_DIGEST}",
      "payload_relpath": "artifacts/airgap/airgap-platform.tar.gz",
      "manifest_relpath": "artifacts/airgap/manifest.env"
    }
  },
  "staged_files": []
}
EOF

run_loader() {
  local mission_root="$1"
  local airgap_extract_dir="$2"

  # shellcheck disable=SC2016
  env \
    OURBOX_INSTALL_LIBRARY_ONLY=1 \
    OURBOX_INSTALL_TOOLS_ROOT="${TOOLS_DIR}" \
    OURBOX_INSTALL_MISSION_ROOT="${mission_root}" \
    OURBOX_INSTALL_AIRGAP_EXTRACT_DIR="${airgap_extract_dir}" \
    bash -lc '
      set -euo pipefail
      source "$1"
      load_local_mission
      printf "OS_ARTIFACT_REF=%s\n" "${OS_ARTIFACT_REF}"
      printf "INSTALL_SELECTION_SOURCE=%s\n" "${INSTALL_SELECTION_SOURCE}"
      printf "RELEASE_CHANNEL=%s\n" "${RELEASE_CHANNEL}"
      printf "PAYLOAD_PATH=%s\n" "${PAYLOAD_PATH}"
      printf "PAYLOAD_META=%s\n" "${PAYLOAD_META}"
      printf "PAYLOAD_SHA256=%s\n" "${PAYLOAD_SHA256}"
      printf "PLATFORM_CONTRACT_DIGEST=%s\n" "${PLATFORM_CONTRACT_DIGEST}"
      printf "OURBOX_SUBSTRATE_REF=%s\n" "${OURBOX_SUBSTRATE_REF}"
      printf "OURBOX_SUBSTRATE_DIGEST=%s\n" "${OURBOX_SUBSTRATE_DIGEST}"
      printf "OURBOX_SUBSTRATE_ARCH=%s\n" "${OURBOX_SUBSTRATE_ARCH}"
      printf "OURBOX_SUBSTRATE_PROFILE=%s\n" "${OURBOX_SUBSTRATE_PROFILE}"
      printf "AIRGAP_MANIFEST_PATH=%s\n" "${AIRGAP_MANIFEST_PATH}"
    ' bash "${INSTALLER_SCRIPT}"
}

loader_output="$(run_loader "${MISSION_ROOT}" "${AIRGAP_EXTRACT_DIR}")"

grep -Fq "OS_ARTIFACT_REF=ghcr.io/example/ourbox-matchbox-os@${OS_DIGEST}" <<<"${loader_output}" \
  || die "matchbox runtime did not load the resolved OS artifact ref"
grep -Fq "INSTALL_SELECTION_SOURCE=catalog" <<<"${loader_output}" \
  || die "matchbox runtime did not load the resolved OS selection source"
grep -Fq "RELEASE_CHANNEL=stable" <<<"${loader_output}" \
  || die "matchbox runtime did not load the resolved OS release channel"
grep -Fq "PLATFORM_CONTRACT_DIGEST=${PLATFORM_DIGEST}" <<<"${loader_output}" \
  || die "matchbox runtime did not load the platform contract digest"
grep -Fq "OURBOX_SUBSTRATE_REF=ghcr.io/example/airgap-platform@${AIRGAP_DIGEST}" <<<"${loader_output}" \
  || die "matchbox runtime did not load the resolved application bundle ref"
grep -Fq "OURBOX_SUBSTRATE_DIGEST=${AIRGAP_DIGEST}" <<<"${loader_output}" \
  || die "matchbox runtime did not load the resolved application bundle digest"
grep -Fq "OURBOX_SUBSTRATE_ARCH=arm64" <<<"${loader_output}" \
  || die "matchbox runtime did not load the application bundle arch"
grep -Fq "OURBOX_SUBSTRATE_PROFILE=demo-apps" <<<"${loader_output}" \
  || die "matchbox runtime did not load the application bundle profile"
grep -Fq "PAYLOAD_PATH=${MISSION_ROOT}/artifacts/os/os-payload.tar.xz" <<<"${loader_output}" \
  || die "matchbox runtime did not resolve the mission OS payload path"
grep -Fq "PAYLOAD_META=${MISSION_ROOT}/artifacts/os/os.meta.env" <<<"${loader_output}" \
  || die "matchbox runtime did not resolve the mission OS metadata path"
grep -Fq "AIRGAP_MANIFEST_PATH=${MISSION_ROOT}/artifacts/airgap/manifest.env" <<<"${loader_output}" \
  || die "matchbox runtime did not resolve the application bundle manifest path"

[[ -f "${AIRGAP_EXTRACT_DIR}/manifest.env" ]] \
  || die "matchbox runtime did not extract the application bundle manifest"
[[ -x "${AIRGAP_EXTRACT_DIR}/k3s/k3s" ]] \
  || die "matchbox runtime did not extract the application bundle runtime"

BAD_MISSION_ROOT="${TMP}/bad-mission"
cp -a "${MISSION_ROOT}" "${BAD_MISSION_ROOT}"
python3 - <<'PY' "${BAD_MISSION_ROOT}/mission-manifest.json"
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as handle:
    manifest = json.load(handle)

manifest["resolved"]["os"]["payload"]["relpath"] = "../escape.img.xz"

with open(path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2)
    handle.write("\n")
PY

set +e
bad_output="$(run_loader "${BAD_MISSION_ROOT}" "${TMP}/bad-airgap-extract" 2>&1)"
bad_status=$?
set -e

[[ "${bad_status}" -ne 0 ]] || die "matchbox runtime accepted a mission relpath that escaped the mission root"
grep -Fq "mission OS payload relpath must stay within the mission directory" <<<"${bad_output}" \
  || die "matchbox runtime did not explain the relpath traversal rejection"

log "Matchbox local mission runtime smoke passed"
