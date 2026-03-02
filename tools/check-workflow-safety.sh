#!/usr/bin/env bash
# Enforce trust boundaries on GitHub Actions workflow files.
#
# Rules:
#   1. No workflow that runs on a self-hosted runner may be triggered by
#      pull_request or pull_request_target (untrusted code on privileged builder).
#   2. No official publish workflow may expose a broad workflow_dispatch trigger
#      (official publication must only flow from push-to-main or tag push).
#   3. Official publish workflows triggered by branch push must declare a path
#      filter (paths-ignore or paths) to avoid rebuilding on docs-only changes.
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
# Rule 3: official publish workflows on branch push must declare a path filter
# ---------------------------------------------------------------------------
while IFS= read -r wf; do
  name="$(basename "${wf}")"

  # Is this an official publish workflow?
  if ! grep -qE 'publish-(os|installer)-artifact-official\.sh' "${wf}"; then
    continue
  fi

  # Does it trigger on push to a branch?
  if ! grep -qE '^\s+branches:' "${wf}"; then
    continue
  fi

  # Must declare paths-ignore or paths to avoid rebuilding on docs-only changes.
  if grep -qE '^\s+paths-ignore:' "${wf}" || grep -qE '^\s+paths:' "${wf}"; then
    PASS=$((PASS + 1))
  else
    fail "${name}: official publish workflow triggers on branch push without a path filter — add paths-ignore to skip documentation-only changes"
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
