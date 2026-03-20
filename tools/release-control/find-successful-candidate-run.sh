#!/usr/bin/env bash
# Resolve the latest successful candidate workflow run for a source commit.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tools/release-control/lib.sh"

need_cmd gh
need_cmd python3

WORKFLOW_NAME="${1:?Usage: find-successful-candidate-run.sh <workflow-name> <source-commit>}"
SOURCE_COMMIT="${2:?Usage: find-successful-candidate-run.sh <workflow-name> <source-commit>}"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"
NO_MATCH_EXIT=3
PENDING_MATCH_EXIT=4
FAILED_MATCH_EXIT=5

json="$(gh run list --repo "${REPO}" --workflow "${WORKFLOW_NAME}" --branch main --event push \
  --json databaseId,headSha,status,conclusion,createdAt -L "${RUN_LIST_LIMIT:-100}")" \
  || die "Unable to list workflow runs for ${WORKFLOW_NAME}"

result="$(
  python3 -c 'import json,sys
source_commit = sys.argv[1]
runs = json.load(sys.stdin)
matching_runs = [
    run for run in runs
    if run.get("headSha") == source_commit
]
successful_runs = [
    run for run in matching_runs
    if run.get("status") == "completed"
    and run.get("conclusion") == "success"
]
successful_runs.sort(key=lambda run: run.get("createdAt") or "", reverse=True)
if successful_runs:
    print(f"success\t{successful_runs[0]['databaseId']}")
    raise SystemExit(0)
pending_runs = [
    run for run in matching_runs
    if run.get("status") != "completed"
]
if pending_runs:
    print("pending\t")
    raise SystemExit(0)
failed_runs = [
    run for run in matching_runs
    if run.get("status") == "completed"
    and run.get("conclusion") not in ("success", "")
]
if failed_runs:
    print("failed\t")
    raise SystemExit(0)
print("none\t")' \
    "${SOURCE_COMMIT}" <<<"${json}"
)"

state="${result%%$'\t'*}"
value="${result#*$'\t'}"

case "${state}" in
  success)
    printf '%s\n' "${value}"
    exit 0
    ;;
  pending)
    exit "${PENDING_MATCH_EXIT}"
    ;;
  failed)
    exit "${FAILED_MATCH_EXIT}"
    ;;
  none)
    exit "${NO_MATCH_EXIT}"
    ;;
  *)
    die "Unexpected candidate run state: ${state}"
    ;;
esac
