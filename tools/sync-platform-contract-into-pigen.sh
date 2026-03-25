#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SRC="${ROOT}/artifacts/platform-contract/extracted/platform-contract"
[[ -d "${SRC}" ]] || {
  echo "Missing extracted contract dir: ${SRC}" >&2
  echo "Run: ./tools/fetch-platform-contract.sh" >&2
  exit 1
}

"${ROOT}/tools/validate-platform-contract-shape.sh" "${SRC}"

STAGE_FILES="${ROOT}/pigen/stages/stage-ourbox-matchbox/02-ourbox-substrate/files"
DST_BASE="${STAGE_FILES}/opt/ourbox/substrate/platform"

rm -rf "${DST_BASE}"
mkdir -p "${DST_BASE}"

cp -a "${SRC}/." "${DST_BASE}/"

echo "Synced platform contract into pi-gen stage files:"
echo "  ${DST_BASE}"
