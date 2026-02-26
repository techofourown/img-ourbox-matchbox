#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REF_FILE="${ROOT}/contracts/platform-contract.ref"
[[ -f "${REF_FILE}" ]] || { echo "Missing ${REF_FILE}" >&2; exit 1; }

REF="$(cat "${REF_FILE}")"
DIGEST="${REF#*@}"

SRC="${ROOT}/artifacts/platform-contract/extracted/platform-contract"
[[ -d "${SRC}" ]] || {
  echo "Missing extracted contract dir: ${SRC}" >&2
  echo "Run: ./tools/fetch-platform-contract.sh" >&2
  exit 1
}

STAGE_FILES="${ROOT}/pigen/stages/stage-ourbox-matchbox/02-airgap-platform/files"
DST_BASE="${STAGE_FILES}/opt/ourbox/airgap/platform"
DST_MAN="${DST_BASE}/manifests"
DST_LAND="${DST_BASE}/landing"

rm -rf "${DST_MAN}" "${DST_LAND}"
mkdir -p "${DST_MAN}" "${DST_LAND}"

cp -a "${SRC}/manifests/." "${DST_MAN}/"
cp -a "${SRC}/landing/." "${DST_LAND}/"
cp -a "${SRC}/contract.env" "${DST_BASE}/contract.env"
printf '%s\n' "${DIGEST}" > "${DST_BASE}/contract.digest"
touch "${DST_MAN}/.gitkeep" "${DST_LAND}/.gitkeep"

echo "Synced platform contract into pi-gen stage files:"
echo "  ${DST_BASE}"
