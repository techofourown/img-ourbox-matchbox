#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

make_contract_base() {
  local contract_dir="$1"

  mkdir -p \
    "${contract_dir}/tools" \
    "${contract_dir}/profiles/demo-apps" \
    "${contract_dir}/manifests" \
    "${contract_dir}/rendered/defaults/demo-apps"

  : > "${contract_dir}/contract.env"
  : > "${contract_dir}/rendered/defaults/demo-apps/selected-app-surface.json"
  : > "${contract_dir}/tools/check-target-prereqs.sh"
  : > "${contract_dir}/tools/contract-identity.sh"
  : > "${contract_dir}/tools/render-contract.py"
  : > "${contract_dir}/tools/verify-runtime.sh"
  : > "${contract_dir}/profiles/demo-apps/profile.env"
  : > "${contract_dir}/profiles/demo-apps/images.lock.json"
}

UNNUMBERED_DIR="${TMP}/contract-unnumbered"
make_contract_base "${UNNUMBERED_DIR}"
: > "${UNNUMBERED_DIR}/manifests/landing-deployment.yaml"
: > "${UNNUMBERED_DIR}/manifests/dufs-deployment.yaml"
: > "${UNNUMBERED_DIR}/manifests/flatnotes-deployment.yaml"
: > "${UNNUMBERED_DIR}/manifests/demo-apps-ingress.yaml"

bash "${ROOT}/tools/validate-platform-contract-shape.sh" "${UNNUMBERED_DIR}"

NUMBERED_DIR="${TMP}/contract-numbered"
make_contract_base "${NUMBERED_DIR}"
: > "${NUMBERED_DIR}/manifests/20-landing-deployment.yaml"
: > "${NUMBERED_DIR}/manifests/31-dufs-deployment.yaml"
: > "${NUMBERED_DIR}/manifests/41-flatnotes-deployment.yaml"
: > "${NUMBERED_DIR}/manifests/50-demo-apps-ingress.yaml"

bash "${ROOT}/tools/validate-platform-contract-shape.sh" "${NUMBERED_DIR}"

printf '[%s] Matchbox validate-platform-contract-shape smoke passed\n' "$(date -Is)"
