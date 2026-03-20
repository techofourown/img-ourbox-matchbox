#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BAD_REF_RE='ghcr\.io/techofourown/[^[:space:]]+@sha256:[0-9a-f]{64}'
CONTROL_SURFACE_RE='^(\.github/workflows/|release/|contracts/|schemas/|vendor/[^/]+/adapter\.json$|tools/media-adapter/adapter\.json$|tools/[^/]+\.upstream\.env$)'

candidate_output=""
set +e
candidate_output="$(git -C "${ROOT}" ls-files | grep -E "${CONTROL_SURFACE_RE}")"
candidate_status=$?
set -e
if [[ "${candidate_status}" -gt 1 ]]; then
  printf 'ERROR: failed to enumerate control-plane files for mirrored-upstream-pin lint.\n' >&2
  exit 1
fi

candidate_files=()
if [[ -n "${candidate_output}" ]]; then
  mapfile -t candidate_files < <(printf '%s\n' "${candidate_output}")
fi

if [[ "${#candidate_files[@]}" -eq 0 ]]; then
  printf 'No control-plane files matched the mirrored-upstream-pin lint scope.\n'
  exit 0
fi

offenders=()
while IFS= read -r relpath; do
  [[ -n "${relpath}" ]] || continue
  case "${relpath}" in
    *.md)
      continue
      ;;
  esac

  match_output=""
  set +e
  match_output="$(grep -nE "${BAD_REF_RE}" "${ROOT}/${relpath}")"
  match_status=$?
  set -e
  if [[ "${match_status}" -gt 1 ]]; then
    printf 'ERROR: failed to scan %s for mirrored upstream pins.\n' "${relpath}" >&2
    exit 1
  fi
  if [[ -n "${match_output}" ]]; then
    offenders+=("${match_output}")
  fi
done < <(printf '%s\n' "${candidate_files[@]}")

if [[ "${#offenders[@]}" -eq 0 ]]; then
  printf 'No mirrored TOOO upstream digest pins found in checked-in control-plane surfaces.\n'
  exit 0
fi

printf '%s\n' 'ERROR: mirrored TOOO upstream digest pins are not allowed in checked-in control-plane surfaces.'
printf '%s\n' 'Source-controlled official surfaces must carry intent; generated records carry resolved identity.'
printf '%s\n' ''
printf '%s\n' 'Offending matches:'
printf '%s\n' "${offenders[@]}"
printf '%s\n' ''
printf '%s\n' 'Allowed locations include generated provenance, published artifact records, and test fixtures.'
exit 1
