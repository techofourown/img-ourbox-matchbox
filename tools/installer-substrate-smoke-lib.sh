#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tools/lib.sh"

required_key_in_file() {
  local file="$1"
  local key="$2"

  grep -Eq "^${key}=" "${file}" || die "installer runtime defaults missing ${key}"
}

forbidden_key_in_file() {
  local file="$1"
  local key="$2"
  local status=0

  grep -Eq "^${key}=" "${file}" && status=0 || status=$?

  case "${status}" in
    0)
      die "installer runtime defaults must not define ${key}"
      ;;
    1)
      return 0
      ;;
    *)
      die "failed to scan installer runtime defaults for ${key}"
      ;;
  esac
}
