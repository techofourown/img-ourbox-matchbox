#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tools/release-control/lib.sh"

PROMOTION_CONTEXT="${1:?Usage: resolve-promotion-context.sh <context> <candidate-workflow-name> <github-output-path>}"
CANDIDATE_WORKFLOW_NAME="${2:?Usage: resolve-promotion-context.sh <context> <candidate-workflow-name> <github-output-path>}"
GITHUB_OUTPUT_PATH="${3:?Usage: resolve-promotion-context.sh <context> <candidate-workflow-name> <github-output-path>}"

need_cmd git

write_output() {
  printf '%s=%s\n' "$1" "$2" >> "${GITHUB_OUTPUT_PATH}"
}

resolve_release_candidate_run() {
  local source_commit="$1"
  local release_tag="$2"
  local timeout_seconds="${CANDIDATE_LOOKUP_TIMEOUT_SECONDS:-90}"
  local poll_seconds="${CANDIDATE_LOOKUP_POLL_SECONDS:-5}"
  local start_time now elapsed status candidate_run_id
  local no_run_timeout_exit=6

  start_time="$(date +%s)"
  while true; do
    set +e
    candidate_run_id="$("${ROOT}/tools/release-control/find-successful-candidate-run.sh" "${CANDIDATE_WORKFLOW_NAME}" "${source_commit}")"
    status=$?
    set -e

    if [[ "${status}" -eq 0 ]]; then
      printf '%s\n' "${candidate_run_id}"
      return 0
    fi

    case "${status}" in
      4)
        printf '[%s] %s\n' \
          "$(date -Is)" \
          "Matching ${CANDIDATE_WORKFLOW_NAME} candidate run is still in progress for release ${release_tag} (${source_commit}); deferring promotion to the workflow_run handoff" >&2
        return 4
        ;;
      5)
        printf '[%s] ERROR: %s\n' \
          "$(date -Is)" \
          "No successful ${CANDIDATE_WORKFLOW_NAME} candidate run found for release ${release_tag} (${source_commit}); matching candidate runs completed unsuccessfully" >&2
        return 5
        ;;
      3)
        now="$(date +%s)"
        elapsed=$(( now - start_time ))
        if (( elapsed >= timeout_seconds )); then
          printf '[%s] ERROR: %s\n' \
            "$(date -Is)" \
            "No ${CANDIDATE_WORKFLOW_NAME} candidate run found for release ${release_tag} (${source_commit}) within ${timeout_seconds}s; refusing silent promotion skip" >&2
          return "${no_run_timeout_exit}"
        fi
        printf '[%s] %s\n' \
          "$(date -Is)" \
          "No ${CANDIDATE_WORKFLOW_NAME} candidate run found yet for release ${release_tag} (${source_commit}); waiting ${poll_seconds}s for candidate workflow registration" >&2
        sleep "${poll_seconds}"
        ;;
      *)
        return "${status}"
        ;;
    esac
  done
}

resolve_source_commit() {
  local release_ref="$1"
  local commit subject

  commit="$(git -C "${ROOT}" rev-parse "${release_ref}^{commit}" 2>/dev/null)" \
    || die "Unable to resolve commit for release ref ${release_ref}"
  subject="$(git -C "${ROOT}" log -1 --format=%s "${commit}" 2>/dev/null || true)"

  if [[ "${subject}" == chore\(release\):* ]]; then
    git -C "${ROOT}" rev-parse "${commit}^" 2>/dev/null \
      || die "Unable to resolve source commit behind release commit ${commit}"
  else
    printf '%s\n' "${commit}"
  fi
}

release_type_allowed() {
  local is_draft="$1" is_prerelease="$2"

  case "${PROMOTION_CONTEXT}" in
    stable|versioned)
      [[ "${is_draft}" == "false" && "${is_prerelease}" == "false" ]]
      ;;
    exp-labs)
      [[ "${is_draft}" == "false" && "${is_prerelease}" == "true" ]]
      ;;
    *)
      die "Unknown promotion context: ${PROMOTION_CONTEXT} (expected: stable|exp-labs|versioned)"
      ;;
  esac
}

if [[ "${GITHUB_EVENT_NAME:-}" == "workflow_run" ]]; then
  source_commit="${WORKFLOW_RUN_HEAD_SHA:-}"
  candidate_run_id="${WORKFLOW_RUN_ID:-}"
  [[ -n "${source_commit}" ]] || die "WORKFLOW_RUN_HEAD_SHA must be set for workflow_run events"
  [[ -n "${candidate_run_id}" ]] || die "WORKFLOW_RUN_ID must be set for workflow_run events"

  if release_tag="$("${ROOT}/tools/release-control/resolve-promotable-release.sh" "${PROMOTION_CONTEXT}" "${source_commit}")"; then
    :
  else
    status=$?
    if [[ "${status}" -eq 3 ]]; then
      write_output skip true
      write_output source_commit "${source_commit}"
      write_output candidate_run_id "${candidate_run_id}"
      write_output release_tag ""
      exit 0
    fi
    exit "${status}"
  fi
elif [[ "${GITHUB_EVENT_NAME:-}" == "release" ]]; then
  release_tag="${RELEASE_TAG:-}"
  [[ -n "${release_tag}" ]] || die "RELEASE_TAG must be set for release events"

  if ! release_type_allowed "${RELEASE_IS_DRAFT:-false}" "${RELEASE_IS_PRERELEASE:-false}"; then
    write_output skip true
    write_output source_commit ""
    write_output candidate_run_id ""
    write_output release_tag "${release_tag}"
    exit 0
  fi

  source_commit="$(resolve_source_commit "refs/tags/${release_tag}")"
  set +e
  candidate_run_id="$(resolve_release_candidate_run "${source_commit}" "${release_tag}")"
  status=$?
  set -e
  if [[ "${status}" -eq 0 ]]; then
    :
  elif [[ "${status}" -eq 4 ]]; then
    write_output skip true
    write_output source_commit "${source_commit}"
    write_output candidate_run_id ""
    write_output release_tag "${release_tag}"
    exit 0
  elif [[ "${status}" -eq 5 || "${status}" -eq 6 ]]; then
    exit "${status}"
  fi
  exit "${status}"
else
  die "Unsupported GITHUB_EVENT_NAME=${GITHUB_EVENT_NAME:-}"
fi

write_output skip false
write_output source_commit "${source_commit}"
write_output candidate_run_id "${candidate_run_id}"
write_output release_tag "${release_tag}"
