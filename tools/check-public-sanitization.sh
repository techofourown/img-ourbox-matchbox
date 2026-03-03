#!/usr/bin/env bash
# Fail if this repo contains internal infrastructure details that must not appear
# in a public repository. Run in CI on every PR and push to main.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

PASS=0
FAIL=0

fail() {
  echo "FAIL: $*" >&2
  FAIL=$((FAIL + 1))
}

warn() {
  echo "WARN: $*"
}

# ---------------------------------------------------------------------------
# 1. Forbidden files — must not exist in the working tree
# ---------------------------------------------------------------------------
FORBIDDEN_FILES=(
  "k8s/centroid-build-image-job.yaml"
  "tools/registry.env"
)

for f in "${FORBIDDEN_FILES[@]}"; do
  if [[ -f "${ROOT}/${f}" ]]; then
    fail "Forbidden file present: ${f} (exposes internal infrastructure details)"
  else
    PASS=$((PASS + 1))
  fi
done

# ---------------------------------------------------------------------------
# 2. Forbidden content patterns — must not appear anywhere in tracked files
# ---------------------------------------------------------------------------
declare -A PATTERNS=(
  ["registry\.benac\.dev"]="internal registry hostname"
  ["/etc/ssl/centroid-ca"]="internal CA cert path"
  ["nodeName:.*centroid"]="internal node name in Kubernetes manifest"
  ["hostPID:.*true"]="privileged host access in Kubernetes manifest"
  ["privileged:.*true"]="privileged container in Kubernetes manifest"
  ["hostPath:"]="host filesystem mount in Kubernetes manifest"
)

# Search only tracked files; exclude this script itself and the .git directory.
THIS_SCRIPT="$(basename "${BASH_SOURCE[0]}")"

for pattern in "${!PATTERNS[@]}"; do
  description="${PATTERNS[${pattern}]}"
  # Use git ls-files so we only scan tracked content (not build outputs, etc.)
  matches="$(git ls-files -z | xargs -0 grep -rlE "${pattern}" 2>/dev/null \
    | grep -v "^tools/${THIS_SCRIPT}$" || true)"
  if [[ -n "${matches}" ]]; then
    fail "Forbidden pattern '${pattern}' (${description}) found in: $(echo "${matches}" | tr '\n' ' ')"
  else
    PASS=$((PASS + 1))
  fi
done

# ---------------------------------------------------------------------------
# 3. Banned words — must not appear anywhere in tracked files
# ---------------------------------------------------------------------------
BANNED_WORDS=(
  "centroid"
)

for word in "${BANNED_WORDS[@]}"; do
  matches="$(git ls-files -z | xargs -0 grep -rilE "\b${word}\b" 2>/dev/null \
    | grep -v "^tools/${THIS_SCRIPT}$" || true)"
  if [[ -n "${matches}" ]]; then
    fail "Banned word '${word}' found in: $(echo "${matches}" | tr '\n' ' ')"
  else
    PASS=$((PASS + 1))
  fi
done

# ---------------------------------------------------------------------------
# 4. Warn if tools/local/ directory exists (should be gitignored, not tracked)
# ---------------------------------------------------------------------------
if git ls-files | grep -q '^tools/local/'; then
  warn "tools/local/ files appear to be tracked by git — they should be gitignored."
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Sanitization check: ${PASS} passed, ${FAIL} failed"

if [[ "${FAIL}" -gt 0 ]]; then
  echo "FAILED: Public repo safety checks did not pass." >&2
  exit 1
fi

echo "OK: No forbidden internal infrastructure details found."
