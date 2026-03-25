#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

CONTRACT_DIR="${TMP}/platform-contract"
TOOLS_DIR="${CONTRACT_DIR}/tools"
PROFILE_DIR="${CONTRACT_DIR}/profiles/demo-apps"
MANIFEST_DIR="${CONTRACT_DIR}/manifests"
RENDERED_DIR="${CONTRACT_DIR}/rendered/defaults/demo-apps"

mkdir -p "${TOOLS_DIR}" "${PROFILE_DIR}" "${MANIFEST_DIR}" "${RENDERED_DIR}"
touch "${RENDERED_DIR}/selected-app-surface.json"

cat > "${TOOLS_DIR}/check-target-prereqs.sh" <<'EOF_CHECK_TARGET_PREREQS'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF_CHECK_TARGET_PREREQS

cat > "${TOOLS_DIR}/contract-identity.sh" <<'EOF_GOOD_IDENTITY'
#!/usr/bin/env bash
set -euo pipefail
cat <<'EOF_OUTPUT'
OURBOX_PLATFORM_PROFILE=demo-apps
OURBOX_PLATFORM_PROFILE_KIND=demo-apps
OURBOX_PLATFORM_ROUTE_MODEL=ingress
BOX_HOST=smoke.ourbox.local
TLS_MODE=lan-http
INGRESS_CLASS=traefik
STORAGE_CLASS=local-path
OURBOX_APPLICATION_CATALOG_ID=fixture-catalog
OURBOX_APPLICATION_SELECTION_MODE=custom
OURBOX_SELECTED_APPLICATION_IDS=landing,dufs
OURBOX_APPLICATION_CATALOG_SHA256=sha256:1111111111111111111111111111111111111111111111111111111111111111
OURBOX_APPLICATION_IMAGES_LOCK_SHA256=sha256:2222222222222222222222222222222222222222222222222222222222222222
EOF_OUTPUT
EOF_GOOD_IDENTITY

cat > "${TOOLS_DIR}/render-contract.py" <<'EOF_GOOD_RENDER'
#!/usr/bin/env python3
import sys

if "--help" in sys.argv:
    print(
        "usage: render-contract.py [--contract-root] [--output-dir] "
        "[--selected-apps-file] [--application-catalog] [--images-lock-file]"
    )
    raise SystemExit(0)

raise SystemExit("unexpected invocation")
EOF_GOOD_RENDER

cat > "${TOOLS_DIR}/verify-runtime.sh" <<'EOF_VERIFY_RUNTIME'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF_VERIFY_RUNTIME

cat > "${PROFILE_DIR}/profile.env" <<'EOF_PROFILE'
OURBOX_PLATFORM_PROFILE=demo-apps
EOF_PROFILE

cat > "${CONTRACT_DIR}/catalog.json" <<'EOF_CATALOG'
{
  "schema": 1,
  "kind": "ourbox-application-catalog",
  "catalog_id": "fixture-catalog",
  "catalog_name": "Fixture Catalog",
  "default_app_ids": [
    "landing",
    "dufs"
  ],
  "apps": [
    {
      "id": "landing",
      "display_name": "Landing",
      "image_names": [
        "landing"
      ]
    },
    {
      "id": "dufs",
      "display_name": "Dufs",
      "image_names": [
        "dufs"
      ]
    }
  ]
}
EOF_CATALOG

cat > "${CONTRACT_DIR}/selected-apps.json" <<'EOF_SELECTED_APPS'
{
  "schema": 1,
  "kind": "ourbox-selected-applications",
  "catalog_id": "fixture-catalog",
  "selection_mode": "custom",
  "selected_app_ids": [
    "landing",
    "dufs"
  ]
}
EOF_SELECTED_APPS

cat > "${CONTRACT_DIR}/images.lock.json" <<'EOF_RENDERED_IMAGES_LOCK'
{
  "schema": 1,
  "images": [
    {
      "name": "landing",
      "ref": "ghcr.io/example/landing@sha256:1111111111111111111111111111111111111111111111111111111111111111"
    },
    {
      "name": "dufs",
      "ref": "ghcr.io/example/dufs@sha256:2222222222222222222222222222222222222222222222222222222222222222"
    }
  ]
}
EOF_RENDERED_IMAGES_LOCK

chmod +x "${TOOLS_DIR}/check-target-prereqs.sh" "${TOOLS_DIR}/contract-identity.sh" "${TOOLS_DIR}/verify-runtime.sh"

for manifest in \
  20-landing-deployment.yaml \
  dufs-deployment.yaml \
  flatnotes-deployment.yaml \
  50-demo-apps-ingress.yaml; do
  printf '# fixture manifest: %s\n' "${manifest}" > "${MANIFEST_DIR}/${manifest}"
done

bash "${ROOT}/tools/validate-platform-contract-shape.sh" "${CONTRACT_DIR}"

cat > "${TOOLS_DIR}/render-contract.py" <<'EOF_BAD_RENDER'
#!/usr/bin/env python3
import sys

if "--help" in sys.argv:
    print("usage: render-contract.py [--contract-root] [--output-dir] [--selected-apps-file] [--images-lock-file]")
    raise SystemExit(0)

raise SystemExit("unexpected invocation")
EOF_BAD_RENDER

set +e
bash "${ROOT}/tools/validate-platform-contract-shape.sh" "${CONTRACT_DIR}" >"${TMP}/bad-render.log" 2>&1
status=$?
set -e

[[ "${status}" -ne 0 ]] || {
  echo "validator should reject render-contract.py without application catalog support" >&2
  exit 1
}
grep -F -- "--application-catalog" "${TMP}/bad-render.log" >/dev/null || {
  cat "${TMP}/bad-render.log" >&2
  exit 1
}

cat > "${TOOLS_DIR}/render-contract.py" <<'EOF_GOOD_RENDER'
#!/usr/bin/env python3
import sys

if "--help" in sys.argv:
    print(
        "usage: render-contract.py [--contract-root] [--output-dir] "
        "[--selected-apps-file] [--application-catalog] [--images-lock-file]"
    )
    raise SystemExit(0)

raise SystemExit("unexpected invocation")
EOF_GOOD_RENDER

cat > "${TOOLS_DIR}/contract-identity.sh" <<'EOF_BAD_IDENTITY'
#!/usr/bin/env bash
set -euo pipefail
cat <<'EOF_OUTPUT'
OURBOX_PLATFORM_PROFILE=demo-apps
OURBOX_PLATFORM_PROFILE_KIND=demo-apps
OURBOX_PLATFORM_ROUTE_MODEL=ingress
BOX_HOST=smoke.ourbox.local
TLS_MODE=lan-http
INGRESS_CLASS=traefik
STORAGE_CLASS=local-path
OURBOX_APPLICATION_CATALOG_ID=
OURBOX_APPLICATION_SELECTION_MODE=
OURBOX_SELECTED_APPLICATION_IDS=
OURBOX_APPLICATION_CATALOG_SHA256=
OURBOX_APPLICATION_IMAGES_LOCK_SHA256=
EOF_OUTPUT
EOF_BAD_IDENTITY
chmod +x "${TOOLS_DIR}/contract-identity.sh"

set +e
bash "${ROOT}/tools/validate-platform-contract-shape.sh" "${CONTRACT_DIR}" >"${TMP}/bad-identity.log" 2>&1
status=$?
set -e

[[ "${status}" -ne 0 ]] || {
  echo "validator should reject contract-identity.sh without application image metadata output" >&2
  exit 1
}
grep -F "OURBOX_APPLICATION_CATALOG_ID" "${TMP}/bad-identity.log" >/dev/null || {
  cat "${TMP}/bad-identity.log" >&2
  exit 1
}

printf '[%s] Matchbox validate-platform-contract-shape smoke passed\n' "$(date -Is)"
