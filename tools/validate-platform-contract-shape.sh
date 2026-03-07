#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTRACT_DIR="${1:-${ROOT}/artifacts/platform-contract/extracted/platform-contract}"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ -d "${CONTRACT_DIR}" ]] || die "platform contract directory not found: ${CONTRACT_DIR}"

# The current runtime seam expects render/verify tools, demo-app profile data,
# and the workload manifests that were absent from the older two-file contract.
required_paths=(
  "contract.env"
  "tools/check-target-prereqs.sh"
  "tools/contract-identity.sh"
  "tools/render-contract.py"
  "tools/verify-runtime.sh"
  "profiles/demo-apps/profile.env"
  "profiles/demo-apps/images.lock.json"
  "manifests/20-landing-deployment.yaml"
  "manifests/31-dufs-deployment.yaml"
  "manifests/41-flatnotes-deployment.yaml"
  "manifests/50-demo-apps-ingress.yaml"
)

missing=()
for rel in "${required_paths[@]}"; do
  [[ -e "${CONTRACT_DIR}/${rel}" ]] || missing+=("${rel}")
done

if (( ${#missing[@]} > 0 )); then
  echo "ERROR: platform-contract artifact shape check failed for ${CONTRACT_DIR}" >&2
  echo "Missing required files:" >&2
  printf '  - %s\n' "${missing[@]}" >&2
  echo "Update PLATFORM_CONTRACT_REF to a full-shape upstream contract artifact." >&2
  exit 1
fi

echo "OK: platform contract shape validated: ${CONTRACT_DIR}"
