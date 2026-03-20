#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BAD_REF_RE='ghcr\.io/techofourown/[^[:space:]]+@sha256:[0-9a-f]{64}'
CONTROL_SURFACE_RE='^(\.github/workflows/|release/|contracts/|schemas/|vendor/[^/]+/adapter\.json$|tools/media-adapter/adapter\.json$|tools/[^/]+\.upstream\.env$)'

mapfile -t candidate_files < <(git -C "${ROOT}" ls-files | rg "${CONTROL_SURFACE_RE}" || true)

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

  if match_output="$(rg -n "${BAD_REF_RE}" "${ROOT}/${relpath}" || true)" && [[ -n "${match_output}" ]]; then
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
