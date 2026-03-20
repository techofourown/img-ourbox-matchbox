#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMP_ROOT}"' EXIT

assert_required_env_failure() {
  local label="$1"
  local expected="$2"
  shift 2
  local log_file="${TMP_ROOT}/${label}.log"

  if env -u OURBOX_PLATFORM_CONTRACT_REF -u OURBOX_AIRGAP_PLATFORM_REF "$@" >"${log_file}" 2>&1; then
    echo "expected ${label} to fail without explicit upstream ref env" >&2
    cat "${log_file}" >&2
    exit 1
  fi

  grep -Fq "${expected}" "${log_file}" || {
    echo "expected ${label} output to contain: ${expected}" >&2
    cat "${log_file}" >&2
    exit 1
  }
}

assert_required_env_failure \
  fetch-platform-contract \
  "OURBOX_PLATFORM_CONTRACT_REF is required." \
  bash "${ROOT}/tools/fetch-platform-contract.sh"

assert_required_env_failure \
  fetch-airgap-platform \
  "OURBOX_AIRGAP_PLATFORM_REF is required." \
  bash "${ROOT}/tools/fetch-airgap-platform.sh"

printf '[%s] Matchbox upstream input env contract smoke passed\n' "$(date -Is)"
