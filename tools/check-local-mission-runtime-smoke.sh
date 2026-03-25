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
BOOTSTRAP_SCRIPT="${ROOT}/pigen/stages/stage-ourbox-matchbox/02-ourbox-substrate/files/usr/local/sbin/ourbox-bootstrap"
MISSION_ROOT="${TMP}/mission"
MISSION_OS_DIR="${MISSION_ROOT}/artifacts/os"
MISSION_SUBSTRATE_DIR="${MISSION_ROOT}/artifacts/substrate"
SUBSTRATE_SOURCE_DIR="${TMP}/substrate-source"
SUBSTRATE_EXTRACT_DIR="${TMP}/substrate-extract"
TARGET_ROOT="${TMP}/target-root"

mkdir -p "${TOOLS_DIR}" "${MISSION_OS_DIR}" "${MISSION_SUBSTRATE_DIR}" \
  "${SUBSTRATE_SOURCE_DIR}/k3s" "${SUBSTRATE_SOURCE_DIR}/platform/images"

cp "${ROOT}/tools/lib.sh" "${TOOLS_DIR}/lib.sh"
cp "${ROOT}/tools/matchbox-storage-flow.sh" "${TOOLS_DIR}/matchbox-storage-flow.sh"
cp "${ROOT}/pigen/stages/stage-ourbox-installer/00-installer/files/opt/ourbox/tools/ourbox-install" "${INSTALLER_SCRIPT}"

OS_DIGEST="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
SUBSTRATE_DIGEST="sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

printf 'fixture os payload\n' > "${MISSION_OS_DIR}/os-payload.tar.xz"
printf '%s  %s\n' \
  "$(sha256sum "${MISSION_OS_DIR}/os-payload.tar.xz" | awk '{print $1}')" \
  "os-payload.tar.xz" > "${MISSION_OS_DIR}/os-payload.tar.xz.sha256"
cat > "${MISSION_OS_DIR}/os.meta.env" <<EOF
OURBOX_SUBSTRATE_REF=ghcr.io/example/ourbox-substrate@${SUBSTRATE_DIGEST}
EOF

cat > "${SUBSTRATE_SOURCE_DIR}/manifest.env" <<EOF
OURBOX_SUBSTRATE_SOURCE=https://github.com/example/sw-ourbox-os
OURBOX_SUBSTRATE_REVISION=fixture-revision
OURBOX_SUBSTRATE_VERSION=v0.0.1
OURBOX_SUBSTRATE_CREATED=2026-03-23T00:00:00Z
OURBOX_SUBSTRATE_ARCH=arm64
K3S_VERSION=v1.35.0+k3s1
OURBOX_PLATFORM_PROFILE=demo-apps
OURBOX_PLATFORM_IMAGES_LOCK_PATH=platform/images.lock.json
OURBOX_PLATFORM_IMAGES_LOCK_SHA256=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
EOF
printf '#!/bin/sh\nexit 0\n' > "${SUBSTRATE_SOURCE_DIR}/k3s/k3s"
chmod +x "${SUBSTRATE_SOURCE_DIR}/k3s/k3s"
printf 'fixture substrate images\n' > "${SUBSTRATE_SOURCE_DIR}/k3s/k3s-images-arm64.tar"
printf '{"images":[]}\n' > "${SUBSTRATE_SOURCE_DIR}/platform/images.lock.json"
printf 'OURBOX_PLATFORM_PROFILE=demo-apps\n' > "${SUBSTRATE_SOURCE_DIR}/platform/profile.env"
printf 'fixture image tar\n' > "${SUBSTRATE_SOURCE_DIR}/platform/images/platform-demo.tar"
tar -C "${SUBSTRATE_SOURCE_DIR}" -czf "${MISSION_SUBSTRATE_DIR}/ourbox-substrate.tar.gz" k3s platform manifest.env
cp "${SUBSTRATE_SOURCE_DIR}/manifest.env" "${MISSION_SUBSTRATE_DIR}/manifest.env"
cat > "${MISSION_SUBSTRATE_DIR}/catalog.json" <<'EOF'
{
  "schema": 1,
  "kind": "ourbox-application-catalog",
  "catalog_id": "demo-apps",
  "catalog_name": "Demo Apps",
  "default_app_ids": [
    "landing"
  ],
  "apps": [
    {
      "id": "landing",
      "image_names": [
        "landing"
      ],
      "services": [
        {
          "name": "landing",
          "image": "landing",
          "port": 80
        }
      ]
    }
  ]
}
EOF
cat > "${MISSION_SUBSTRATE_DIR}/selected-apps.json" <<'EOF'
{
  "schema": 1,
  "kind": "ourbox-selected-applications",
  "catalog_id": "demo-apps",
  "selection_mode": "custom",
  "selected_app_ids": [
    "landing"
  ]
}
EOF
cat > "${MISSION_SUBSTRATE_DIR}/application-images.lock.json" <<'EOF'
{
  "schema": 1,
  "images": [
    {
      "name": "landing",
      "ref": "ghcr.io/example/landing@sha256:1111111111111111111111111111111111111111111111111111111111111111"
    }
  ]
}
EOF

cat > "${MISSION_ROOT}/mission-manifest.json" <<EOF
{
  "kind": "ourbox-mission",
  "target": {
    "id": "matchbox",
    "media_kind": "installer-usb"
  },
  "requested": {
    "os": {
      "selection_source": "catalog",
      "release_channel": "stable",
      "requested_ref": ""
    },
    "selected_substrate": {
      "selection_source": "official-catalog",
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
    "selected_substrate": {
      "selection_source": "official-catalog",
      "release_channel": "",
      "artifact_ref": "ghcr.io/example/ourbox-substrate@${SUBSTRATE_DIGEST}",
      "artifact_digest": "${SUBSTRATE_DIGEST}",
      "payload_relpath": "artifacts/substrate/ourbox-substrate.tar.gz",
      "manifest_relpath": "artifacts/substrate/manifest.env"
    },
    "applications": {
      "catalog_id": "demo-apps",
      "catalog_name": "Demo Apps",
      "selection_mode": "custom",
      "selected_app_ids": [
        "landing"
      ],
      "catalog_relpath": "artifacts/substrate/catalog.json",
      "images_lock_relpath": "artifacts/substrate/application-images.lock.json",
      "selection_relpath": "artifacts/substrate/selected-apps.json"
    }
  },
  "staged_files": []
}
EOF

run_loader() {
  local mission_root="$1"
  local substrate_extract_dir="$2"

  # shellcheck disable=SC2016
  env \
    OURBOX_INSTALL_LIBRARY_ONLY=1 \
    OURBOX_INSTALL_TOOLS_ROOT="${TOOLS_DIR}" \
    OURBOX_INSTALL_MISSION_ROOT="${mission_root}" \
    OURBOX_INSTALL_SUBSTRATE_EXTRACT_DIR="${substrate_extract_dir}" \
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
      printf "OURBOX_SUBSTRATE_REF=%s\n" "${OURBOX_SUBSTRATE_REF}"
      printf "OURBOX_SUBSTRATE_DIGEST=%s\n" "${OURBOX_SUBSTRATE_DIGEST}"
      printf "OURBOX_SUBSTRATE_ARCH=%s\n" "${OURBOX_SUBSTRATE_ARCH}"
      printf "OURBOX_SUBSTRATE_PROFILE=%s\n" "${OURBOX_SUBSTRATE_PROFILE}"
      printf "SUBSTRATE_MANIFEST_PATH=%s\n" "${SUBSTRATE_MANIFEST_PATH}"
      printf "MISSION_APPLICATION_CATALOG_PATH=%s\n" "${MISSION_APPLICATION_CATALOG_PATH}"
      printf "MISSION_APPLICATION_IMAGES_LOCK_PATH=%s\n" "${MISSION_APPLICATION_IMAGES_LOCK_PATH}"
      printf "MISSION_SELECTED_APPLICATIONS_PATH=%s\n" "${MISSION_SELECTED_APPLICATIONS_PATH}"
    ' bash "${INSTALLER_SCRIPT}"
}

loader_output="$(run_loader "${MISSION_ROOT}" "${SUBSTRATE_EXTRACT_DIR}")"

grep -Fq "OS_ARTIFACT_REF=ghcr.io/example/ourbox-matchbox-os@${OS_DIGEST}" <<<"${loader_output}" \
  || die "matchbox runtime did not load the resolved OS artifact ref"
grep -Fq "INSTALL_SELECTION_SOURCE=catalog" <<<"${loader_output}" \
  || die "matchbox runtime did not load the resolved OS selection source"
grep -Fq "RELEASE_CHANNEL=stable" <<<"${loader_output}" \
  || die "matchbox runtime did not load the resolved OS release channel"
grep -Fq "OURBOX_SUBSTRATE_REF=ghcr.io/example/ourbox-substrate@${SUBSTRATE_DIGEST}" <<<"${loader_output}" \
  || die "matchbox runtime did not load the resolved substrate bundle ref"
grep -Fq "OURBOX_SUBSTRATE_DIGEST=${SUBSTRATE_DIGEST}" <<<"${loader_output}" \
  || die "matchbox runtime did not load the resolved substrate bundle digest"
grep -Fq "OURBOX_SUBSTRATE_ARCH=arm64" <<<"${loader_output}" \
  || die "matchbox runtime did not load the substrate bundle arch"
grep -Fq "OURBOX_SUBSTRATE_PROFILE=demo-apps" <<<"${loader_output}" \
  || die "matchbox runtime did not load the substrate bundle profile"
grep -Fq "PAYLOAD_PATH=${MISSION_ROOT}/artifacts/os/os-payload.tar.xz" <<<"${loader_output}" \
  || die "matchbox runtime did not resolve the mission OS payload path"
grep -Fq "PAYLOAD_META=${MISSION_ROOT}/artifacts/os/os.meta.env" <<<"${loader_output}" \
  || die "matchbox runtime did not resolve the mission OS metadata path"
grep -Fq "SUBSTRATE_MANIFEST_PATH=${MISSION_ROOT}/artifacts/substrate/manifest.env" <<<"${loader_output}" \
  || die "matchbox runtime did not resolve the substrate bundle manifest path"
grep -Fq "MISSION_APPLICATION_CATALOG_PATH=${MISSION_ROOT}/artifacts/substrate/catalog.json" <<<"${loader_output}" \
  || die "matchbox runtime did not resolve the mission application catalog path"
grep -Fq "MISSION_APPLICATION_IMAGES_LOCK_PATH=${MISSION_ROOT}/artifacts/substrate/application-images.lock.json" <<<"${loader_output}" \
  || die "matchbox runtime did not resolve the mission application images lock path"
grep -Fq "MISSION_SELECTED_APPLICATIONS_PATH=${MISSION_ROOT}/artifacts/substrate/selected-apps.json" <<<"${loader_output}" \
  || die "matchbox runtime did not resolve the mission selected applications path"

[[ -f "${SUBSTRATE_EXTRACT_DIR}/manifest.env" ]] \
  || die "matchbox runtime did not extract the substrate bundle manifest"
[[ -x "${SUBSTRATE_EXTRACT_DIR}/k3s/k3s" ]] \
  || die "matchbox runtime did not extract the substrate bundle runtime"

# shellcheck disable=SC2016
env \
  OURBOX_INSTALL_LIBRARY_ONLY=1 \
  OURBOX_INSTALL_TOOLS_ROOT="${TOOLS_DIR}" \
  OURBOX_INSTALL_MISSION_ROOT="${MISSION_ROOT}" \
  OURBOX_INSTALL_SUBSTRATE_EXTRACT_DIR="${SUBSTRATE_EXTRACT_DIR}" \
  OURBOX_INSTALL_SYS_ROOT_MP="${TARGET_ROOT}" \
  bash -lc '
    set -euo pipefail
    source "$1"
    load_local_mission
    overlay_selected_ourbox_substrate_into_mounted_root
  ' bash "${INSTALLER_SCRIPT}"

cmp -s "${SUBSTRATE_SOURCE_DIR}/platform/images.lock.json" \
  "${TARGET_ROOT}/opt/ourbox/substrate/platform/platform-images.lock.json" \
  || die "matchbox runtime did not preserve the platform-owned images lock in platform-images.lock.json"
cmp -s "${MISSION_SUBSTRATE_DIR}/application-images.lock.json" \
  "${TARGET_ROOT}/opt/ourbox/substrate/platform/images.lock.json" \
  || die "matchbox runtime did not stage the mission application images lock into images.lock.json"
cmp -s "${MISSION_SUBSTRATE_DIR}/catalog.json" \
  "${TARGET_ROOT}/opt/ourbox/substrate/platform/catalog.json" \
  || die "matchbox runtime did not stage the mission application catalog"
cmp -s "${MISSION_SUBSTRATE_DIR}/selected-apps.json" \
  "${TARGET_ROOT}/opt/ourbox/substrate/platform/selected-apps.json" \
  || die "matchbox runtime did not stage the mission selected applications file"

grep -Fq 'selected-app-surface.json' "${BOOTSTRAP_SCRIPT}" \
  || die "matchbox bootstrap does not persist selected-app-surface.json"
grep -Fq "[[ -f \"\${SELECTED_APP_SURFACE_STATE}\" ]] || return 1" "${BOOTSTRAP_SCRIPT}" \
  || die "matchbox bootstrap fast-path does not require selected-app-surface.json"
grep -Fq 'systemctl restart ourbox-mdns-aliases.service ourbox-status.service' "${BOOTSTRAP_SCRIPT}" \
  || die "matchbox bootstrap does not restart runtime surface consumers after render"

set +e
library_exec_output="$(OURBOX_INSTALL_LIBRARY_ONLY=1 bash "${INSTALLER_SCRIPT}" 2>&1)"
library_exec_status=$?
set -e

[[ "${library_exec_status}" -ne 0 ]] \
  || die "matchbox installer executed successfully in library-only mode instead of failing fast"
grep -Fq "OURBOX_INSTALL_LIBRARY_ONLY=1 is supported only when sourcing" <<<"${library_exec_output}" \
  || die "matchbox installer did not explain the bad library-only invocation"

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
bad_output="$(run_loader "${BAD_MISSION_ROOT}" "${TMP}/bad-substrate-extract" 2>&1)"
bad_status=$?
set -e

[[ "${bad_status}" -ne 0 ]] || die "matchbox runtime accepted a mission relpath that escaped the mission root"
grep -Fq "mission OS payload relpath must stay within the mission directory" <<<"${bad_output}" \
  || die "matchbox runtime did not explain the relpath traversal rejection"

log "Matchbox local mission runtime smoke passed"
