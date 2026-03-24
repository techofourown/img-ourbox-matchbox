#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTRACT_DIGEST_FILE="${ROOT}/artifacts/platform-contract/extracted/platform-contract/contract.digest"
[[ -f "${CONTRACT_DIGEST_FILE}" ]] || {
  echo "Missing platform contract digest file: ${CONTRACT_DIGEST_FILE}" >&2
  echo "Run: ./tools/fetch-platform-contract.sh" >&2
  exit 1
}
DIGEST="$(cat "${CONTRACT_DIGEST_FILE}")"

SRC="${ROOT}/artifacts/platform-contract/extracted/platform-contract"
[[ -d "${SRC}" ]] || {
  echo "Missing extracted contract dir: ${SRC}" >&2
  echo "Run: ./tools/fetch-platform-contract.sh" >&2
  exit 1
}

"${ROOT}/tools/validate-platform-contract-shape.sh" "${SRC}"

STAGE_FILES="${ROOT}/pigen/stages/stage-ourbox-matchbox/02-ourbox-substrate/files"
DST_BASE="${STAGE_FILES}/opt/ourbox/airgap/platform"

rm -rf "${DST_BASE}"
mkdir -p "${DST_BASE}"

cp -a "${SRC}/." "${DST_BASE}/"
printf '%s\n' "${DIGEST}" > "${DST_BASE}/contract.digest"

echo "Synced platform contract into pi-gen stage files:"
echo "  ${DST_BASE}"
