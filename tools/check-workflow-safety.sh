#!/usr/bin/env bash
# Enforce trust boundaries on GitHub Actions workflow files.
#
# Rules:
#   1. No workflow that runs on a self-hosted runner may be triggered by
#      pull_request or pull_request_target (untrusted code on privileged builder).
#   2. No official publish workflow may expose a broad workflow_dispatch trigger
#      (official publication must only flow from push-to-main or tag push).
#
# Run in CI on every PR and push to main.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW_DIR="${ROOT}/.github/workflows"

PASS=0
FAIL=0

fail() {
  echo "FAIL: $*" >&2
  FAIL=$((FAIL + 1))
}

if [[ ! -d "${WORKFLOW_DIR}" ]]; then
  echo "No .github/workflows/ directory found — nothing to check."
  exit 0
fi

# ---------------------------------------------------------------------------
# Rule 1: self-hosted workflows must not trigger on pull_request / pull_request_target
# ---------------------------------------------------------------------------
while IFS= read -r wf; do
  name="$(basename "${wf}")"

  # Does this workflow use a self-hosted runner?
  if ! grep -qE 'runs-on:.*self-hosted' "${wf}"; then
    continue
  fi

  # If so, it must not have pull_request or pull_request_target triggers.
  if grep -qE '^\s+pull_request(_target)?:?' "${wf}"; then
    fail "${name}: uses self-hosted runner AND triggers on pull_request/pull_request_target — privileged builder must not execute untrusted PR code"
  else
    PASS=$((PASS + 1))
  fi
done < <(find "${WORKFLOW_DIR}" -maxdepth 1 -name '*.yml' -o -name '*.yaml')

# ---------------------------------------------------------------------------
# Rule 2: official publish workflows must not expose workflow_dispatch
# ---------------------------------------------------------------------------
while IFS= read -r wf; do
  name="$(basename "${wf}")"

  # Is this an official publish workflow? Detect by use of *-official.sh scripts.
  if ! grep -qE 'publish-(os|installer)-artifact-official\.sh' "${wf}"; then
    continue
  fi

  if grep -qE '^  workflow_dispatch:' "${wf}"; then
    fail "${name}: official publish workflow exposes workflow_dispatch — official publication must only trigger from push-to-main or tag push"
  else
    PASS=$((PASS + 1))
  fi
done < <(find "${WORKFLOW_DIR}" -maxdepth 1 -name '*.yml' -o -name '*.yaml')

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Workflow safety check: ${PASS} passed, ${FAIL} failed"

if [[ "${FAIL}" -gt 0 ]]; then
  echo "FAILED: Workflow trust boundary violations found." >&2
  exit 1
fi

echo "OK: Workflow trust boundaries are clean."
