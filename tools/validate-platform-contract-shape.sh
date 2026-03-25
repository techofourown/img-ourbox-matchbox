#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTRACT_DIR="${1:-${ROOT}/artifacts/platform-contract/extracted/platform-contract}"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ -d "${CONTRACT_DIR}" ]] || die "platform contract directory not found: ${CONTRACT_DIR}"
command -v python3 >/dev/null 2>&1 || die "python3 is required to validate platform contract capabilities"

# The current runtime seam expects render/verify tools, demo-app profile data,
# and a full rendered workload manifest set. Older upstream artifacts lacked
# those manifests entirely. Current upstream bundles use unnumbered app
# deployment filenames while retaining numbered control-plane filenames, so
# accept either unnumbered or NN-prefixed variants for workload manifests.
required_paths=(
  "tools/check-target-prereqs.sh"
  "tools/contract-identity.sh"
  "tools/render-contract.py"
  "tools/verify-runtime.sh"
  "profiles/demo-apps/profile.env"
  "rendered/defaults/demo-apps/selected-app-surface.json"
)

root_application_metadata_paths=(
  "catalog.json"
  "selected-apps.json"
  "images.lock.json"
)

required_manifest_basenames=(
  "landing-deployment.yaml"
  "dufs-deployment.yaml"
  "flatnotes-deployment.yaml"
  "demo-apps-ingress.yaml"
)

has_required_manifest() {
  local basename="$1"

  [[ -e "${CONTRACT_DIR}/manifests/${basename}" ]] && return 0
  compgen -G "${CONTRACT_DIR}/manifests/[0-9][0-9]-${basename}" >/dev/null && return 0
  return 1
}

missing=()
for rel in "${required_paths[@]}"; do
  [[ -e "${CONTRACT_DIR}/${rel}" ]] || missing+=("${rel}")
done

for basename in "${required_manifest_basenames[@]}"; do
  has_required_manifest "${basename}" || missing+=("manifests/{NN-}${basename}")
done

if (( ${#missing[@]} > 0 )); then
  echo "ERROR: platform-contract artifact shape check failed for ${CONTRACT_DIR}" >&2
  echo "Missing required files:" >&2
  printf '  - %s\n' "${missing[@]}" >&2
  echo "Update PLATFORM_CONTRACT_REF to a full-shape upstream contract artifact." >&2
  exit 1
fi

present_root_application_metadata=()
for rel in "${root_application_metadata_paths[@]}"; do
  [[ -e "${CONTRACT_DIR}/${rel}" ]] && present_root_application_metadata+=("${rel}")
done

if (( ${#present_root_application_metadata[@]} > 0 && ${#present_root_application_metadata[@]} != ${#root_application_metadata_paths[@]} )); then
  echo "ERROR: platform-contract application metadata check failed for ${CONTRACT_DIR}" >&2
  echo "When any root-level application metadata is present, all of these files are required:" >&2
  printf '  - %s\n' "${root_application_metadata_paths[@]}" >&2
  exit 1
fi

if (( ${#present_root_application_metadata[@]} == ${#root_application_metadata_paths[@]} )); then
  python3 - <<'PY' "${CONTRACT_DIR}/catalog.json" "${CONTRACT_DIR}/selected-apps.json" "${CONTRACT_DIR}/images.lock.json"
import json
import pathlib
import sys

catalog_path = pathlib.Path(sys.argv[1])
selected_apps_path = pathlib.Path(sys.argv[2])
images_lock_path = pathlib.Path(sys.argv[3])
supported_selection_modes = {"catalog-defaults", "all-apps", "custom"}

with catalog_path.open("r", encoding="utf-8") as handle:
    catalog = json.load(handle)
with selected_apps_path.open("r", encoding="utf-8") as handle:
    selected = json.load(handle)
with images_lock_path.open("r", encoding="utf-8") as handle:
    images_lock = json.load(handle)

if catalog.get("schema") != 1:
    raise SystemExit(f"{catalog_path} must declare schema=1")
if catalog.get("kind") != "ourbox-application-catalog":
    raise SystemExit(f"{catalog_path} must declare kind=ourbox-application-catalog")
catalog_id = str(catalog.get("catalog_id", "")).strip()
if not catalog_id:
    raise SystemExit(f"{catalog_path} must declare catalog_id")
apps = catalog.get("apps")
if not isinstance(apps, list) or not apps:
    raise SystemExit(f"{catalog_path} must declare a non-empty apps list")
app_ids = set()
for app in apps:
    app_id = str(app.get("id", "")).strip()
    if not app_id:
        raise SystemExit(f"{catalog_path} contains an app without an id")
    if app_id in app_ids:
        raise SystemExit(f"{catalog_path} duplicates app id {app_id}")
    app_ids.add(app_id)

if selected.get("schema") != 1:
    raise SystemExit(f"{selected_apps_path} must declare schema=1")
if selected.get("kind") != "ourbox-selected-applications":
    raise SystemExit(f"{selected_apps_path} must declare kind=ourbox-selected-applications")
if str(selected.get("catalog_id", "")).strip() != catalog_id:
    raise SystemExit(f"{selected_apps_path} catalog_id must match {catalog_path}")
selection_mode = str(selected.get("selection_mode", "")).strip()
if selection_mode not in supported_selection_modes:
    raise SystemExit(
        f"{selected_apps_path} selection_mode must be one of catalog-defaults, all-apps, custom"
    )
selected_ids = selected.get("selected_app_ids")
if not isinstance(selected_ids, list) or not selected_ids:
    raise SystemExit(f"{selected_apps_path} must declare a non-empty selected_app_ids list")
seen_ids = set()
for raw_app_id in selected_ids:
    app_id = str(raw_app_id).strip()
    if not app_id:
        raise SystemExit(f"{selected_apps_path} contains an empty app id")
    if app_id in seen_ids:
        raise SystemExit(f"{selected_apps_path} duplicates app id {app_id}")
    if app_id not in app_ids:
        raise SystemExit(f"{selected_apps_path} references unknown app id {app_id}")
    seen_ids.add(app_id)

images = images_lock.get("images")
if not isinstance(images, list) or not images:
    raise SystemExit(f"{images_lock_path} must declare a non-empty images list")
for image in images:
    name = str(image.get("name", "")).strip()
    ref = str(image.get("ref", "")).strip()
    if not name:
        raise SystemExit(f"{images_lock_path} contains an image without a name")
    if not ref:
        raise SystemExit(f"{images_lock_path} contains an image without a ref")
PY
fi

render_help="$(
  python3 "${CONTRACT_DIR}/tools/render-contract.py" --help 2>&1
)" || die "platform-contract render-contract.py is not runnable: ${CONTRACT_DIR}/tools/render-contract.py"

required_render_options=(
  "--selected-apps-file"
  "--application-catalog"
  "--images-lock-file"
)
missing_render_options=()
for option in "${required_render_options[@]}"; do
  if ! grep -Fq -- "${option}" <<<"${render_help}"; then
    missing_render_options+=("${option}")
  fi
done

if (( ${#missing_render_options[@]} > 0 )); then
  echo "ERROR: platform-contract runtime capability check failed for ${CONTRACT_DIR}" >&2
  echo "render-contract.py is missing required host-selected application options:" >&2
  printf '  - %s\n' "${missing_render_options[@]}" >&2
  echo "Update PLATFORM_CONTRACT_REF to a platform-contract artifact that supports host-selected application metadata." >&2
  exit 1
fi

identity_output="$(
  "${CONTRACT_DIR}/tools/contract-identity.sh" \
    --contract-dir "${CONTRACT_DIR}" \
    --profile demo-apps \
    --box-host smoke.ourbox.local \
    --tls-mode lan-http \
    --ingress-class traefik \
    --storage-class local-path
)" || die "platform-contract contract-identity.sh is not runnable for demo-apps"

required_identity_keys=(
  "OURBOX_APPLICATION_CATALOG_ID="
  "OURBOX_APPLICATION_SELECTION_MODE="
  "OURBOX_SELECTED_APPLICATION_IDS="
  "OURBOX_APPLICATION_CATALOG_SHA256="
  "OURBOX_APPLICATION_IMAGES_LOCK_SHA256="
)
missing_identity_keys=()
for key in "${required_identity_keys[@]}"; do
  if ! grep -Fq -- "${key}" <<<"${identity_output}"; then
    missing_identity_keys+=("${key%=}")
  fi
done

if (( ${#missing_identity_keys[@]} > 0 )); then
  echo "ERROR: platform-contract identity capability check failed for ${CONTRACT_DIR}" >&2
  echo "contract-identity.sh is missing required application metadata outputs:" >&2
  printf '  - %s\n' "${missing_identity_keys[@]}" >&2
  echo "Update PLATFORM_CONTRACT_REF to a platform-contract artifact that supports host-selected application metadata." >&2
  exit 1
fi

identity_value() {
  local key="$1"
  awk -F= -v wanted="${key}" '
    $1 == wanted {
      print substr($0, index($0, "=") + 1)
      exit
    }
  ' <<<"${identity_output}"
}

empty_identity_keys=()
if [[ -f "${CONTRACT_DIR}/selected-apps.json" ]]; then
  for key in \
    "OURBOX_APPLICATION_CATALOG_ID" \
    "OURBOX_APPLICATION_SELECTION_MODE" \
    "OURBOX_SELECTED_APPLICATION_IDS"; do
    if [[ -z "$(identity_value "${key}")" ]]; then
      empty_identity_keys+=("${key}")
    fi
  done
fi

if [[ -f "${CONTRACT_DIR}/catalog.json" ]] && [[ -z "$(identity_value "OURBOX_APPLICATION_CATALOG_SHA256")" ]]; then
  empty_identity_keys+=("OURBOX_APPLICATION_CATALOG_SHA256")
fi

if [[ -f "${CONTRACT_DIR}/images.lock.json" ]] && [[ -z "$(identity_value "OURBOX_APPLICATION_IMAGES_LOCK_SHA256")" ]]; then
  empty_identity_keys+=("OURBOX_APPLICATION_IMAGES_LOCK_SHA256")
fi

if (( ${#empty_identity_keys[@]} > 0 )); then
  echo "ERROR: platform-contract identity capability check failed for ${CONTRACT_DIR}" >&2
  echo "contract-identity.sh leaves required application metadata outputs empty:" >&2
  printf '  - %s\n' "${empty_identity_keys[@]}" >&2
  echo "Update PLATFORM_CONTRACT_REF to a platform-contract artifact that supports host-selected application metadata." >&2
  exit 1
fi

echo "OK: platform contract shape validated: ${CONTRACT_DIR}"
