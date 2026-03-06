#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REF_FILE="${ROOT}/contracts/platform-contract.ref"
[[ -f "${REF_FILE}" ]] || { echo "Missing ${REF_FILE}" >&2; exit 1; }

REF="$(cat "${REF_FILE}")"
CONTRACT_DIGEST_FILE="${ROOT}/artifacts/platform-contract/extracted/platform-contract/contract.digest"
if [[ -f "${CONTRACT_DIGEST_FILE}" ]]; then
  DIGEST="$(cat "${CONTRACT_DIGEST_FILE}")"
else
  DIGEST="${REF#*@}"
fi

SRC="${ROOT}/artifacts/platform-contract/extracted/platform-contract"
[[ -d "${SRC}" ]] || {
  echo "Missing extracted contract dir: ${SRC}" >&2
  echo "Run: ./tools/fetch-platform-contract.sh" >&2
  exit 1
}

STAGE_FILES="${ROOT}/pigen/stages/stage-ourbox-matchbox/02-airgap-platform/files"
DST_BASE="${STAGE_FILES}/opt/ourbox/airgap/platform"

rm -rf "${DST_BASE}"
mkdir -p "${DST_BASE}"

cp -a "${SRC}/." "${DST_BASE}/"
printf '%s\n' "${DIGEST}" > "${DST_BASE}/contract.digest"

echo "Synced platform contract into pi-gen stage files:"
echo "  ${DST_BASE}"
