#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tools/installer-substrate-smoke-lib.sh"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMP_ROOT}"' EXIT

GOOD_DEFAULTS="${TMP_ROOT}/good-defaults.env"
BAD_FORBIDDEN="${TMP_ROOT}/bad-forbidden.env"
BAD_REQUIRED="${TMP_ROOT}/bad-required.env"

cat > "${GOOD_DEFAULTS}" <<'EOF'
INSTALLER_ID=matchbox
INSTALLER_VERSION=main-abcdef123456
INSTALLER_GIT_HASH=abcdef123456
OURBOX_INSTALLER_SSH_TEARDOWN_ON_COMPLETE=0
EOF

required_key_in_file "${GOOD_DEFAULTS}" "INSTALLER_ID"
required_key_in_file "${GOOD_DEFAULTS}" "INSTALLER_VERSION"
required_key_in_file "${GOOD_DEFAULTS}" "INSTALLER_GIT_HASH"
required_key_in_file "${GOOD_DEFAULTS}" "OURBOX_INSTALLER_SSH_TEARDOWN_ON_COMPLETE"

for key in \
  OS_REPO \
  OS_CHANNEL \
  OS_DEFAULT_REF \
  OS_REF \
  INSTALL_DEFAULTS_REF \
  AIRGAP_PLATFORM_REF \
  AIRGAP_PLATFORM_DEFAULT_REF \
  AIRGAP_PLATFORM_CHANNEL \
  AIRGAP_PLATFORM_CATALOG_TAG
do
  forbidden_key_in_file "${GOOD_DEFAULTS}" "${key}"
done

cp "${GOOD_DEFAULTS}" "${BAD_FORBIDDEN}"
printf 'OS_REPO=ghcr.io/example/forbidden\n' >> "${BAD_FORBIDDEN}"
if bash -euo pipefail -c '
  source "$1"
  forbidden_key_in_file "$2" OS_REPO
' _ "${ROOT}/tools/installer-substrate-smoke-lib.sh" "${BAD_FORBIDDEN}" >"${TMP_ROOT}/bad-forbidden.log" 2>&1; then
  echo "expected forbidden key check to fail when OS_REPO is present" >&2
  exit 1
fi

grep -Fq "installer runtime defaults must not define OS_REPO" "${TMP_ROOT}/bad-forbidden.log" || {
  echo "expected forbidden key failure log for OS_REPO" >&2
  cat "${TMP_ROOT}/bad-forbidden.log" >&2
  exit 1
}

cp "${GOOD_DEFAULTS}" "${BAD_REQUIRED}"
grep -Ev '^INSTALLER_VERSION=' "${BAD_REQUIRED}" > "${BAD_REQUIRED}.tmp"
mv "${BAD_REQUIRED}.tmp" "${BAD_REQUIRED}"
if bash -euo pipefail -c '
  source "$1"
  required_key_in_file "$2" INSTALLER_VERSION
' _ "${ROOT}/tools/installer-substrate-smoke-lib.sh" "${BAD_REQUIRED}" >"${TMP_ROOT}/bad-required.log" 2>&1; then
  echo "expected required key check to fail when INSTALLER_VERSION is absent" >&2
  exit 1
fi

grep -Fq "installer runtime defaults missing INSTALLER_VERSION" "${TMP_ROOT}/bad-required.log" || {
  echo "expected missing required key failure log for INSTALLER_VERSION" >&2
  cat "${TMP_ROOT}/bad-required.log" >&2
  exit 1
}

printf '[%s] Matchbox installer substrate smoke helper regression passed\n' "$(date -Is)"
