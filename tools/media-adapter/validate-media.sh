#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${MATCHBOX_ADAPTER_ROOT:=${SCRIPT_DIR}}"
: "${MATCHBOX_REPO_ROOT:=$(cd "${SCRIPT_DIR}/../.." && pwd)}"
ROOT="${MATCHBOX_REPO_ROOT}"
# shellcheck disable=SC1091
source "${ROOT}/tools/lib.sh"

ADAPTER_JSON="${MATCHBOX_ADAPTER_ROOT}/adapter.json"
STRICT_METADATA_PARSER="${MATCHBOX_ADAPTER_ROOT}/strict-kv-metadata.py"
if [[ ! -f "${STRICT_METADATA_PARSER}" ]]; then
  STRICT_METADATA_PARSER="${ROOT}/tools/strict-kv-metadata.py"
fi
MISSION_DIR=""
OS_PAYLOAD=""
OS_META_ENV=""

usage() {
  cat <<EOF
Usage: $0 --mission-dir DIR --os-payload PATH --os-meta-env PATH

Validates the Matchbox mission directory contract before compose.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mission-dir)
      [[ $# -ge 2 ]] || die "--mission-dir requires a value"
      MISSION_DIR="$2"
      shift 2
      ;;
    --os-payload)
      [[ $# -ge 2 ]] || die "--os-payload requires a value"
      OS_PAYLOAD="$2"
      shift 2
      ;;
    --os-meta-env)
      [[ $# -ge 2 ]] || die "--os-meta-env requires a value"
      OS_META_ENV="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      die "unknown argument: $1"
      ;;
  esac
done

[[ -n "${MISSION_DIR}" ]] || die "--mission-dir is required"
[[ -n "${OS_PAYLOAD}" ]] || die "--os-payload is required"
[[ -n "${OS_META_ENV}" ]] || die "--os-meta-env is required"
[[ -d "${MISSION_DIR}" ]] || die "mission dir not found: ${MISSION_DIR}"
[[ -f "${MISSION_DIR}/mission-manifest.json" ]] || die "mission-manifest.json missing from ${MISSION_DIR}"
[[ -f "${OS_PAYLOAD}" ]] || die "os payload not found: ${OS_PAYLOAD}"
[[ -f "${OS_META_ENV}" ]] || die "os metadata not found: ${OS_META_ENV}"
[[ -f "${STRICT_METADATA_PARSER}" ]] || die "strict metadata parser not found: ${STRICT_METADATA_PARSER}"

python3 - <<'PY' "${ADAPTER_JSON}" "${MISSION_DIR}/mission-manifest.json" "${OS_PAYLOAD}" "${OS_META_ENV}" "${STRICT_METADATA_PARSER}"
import hashlib
import json
import pathlib
import re
import subprocess
import sys
import tarfile

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    adapter = json.load(handle)
with open(sys.argv[2], "r", encoding="utf-8") as handle:
    manifest = json.load(handle)

mission_dir = pathlib.Path(sys.argv[2]).resolve().parent
expected_payload = pathlib.Path(sys.argv[3]).resolve()
expected_meta = pathlib.Path(sys.argv[4]).resolve()
strict_metadata_parser = pathlib.Path(sys.argv[5]).resolve()

expected_type = adapter["expected_os_artifact_type"]
expected_arch = adapter["expected_substrate_arch"]
sha256_re = re.compile(r"^sha256:[0-9a-f]{64}$")
pinned_ref_re = re.compile(r"^[^\s]+@sha256:[0-9a-f]{64}$")
plain_sha256_re = re.compile(r"^[0-9a-f]{64}$")
key_name_re = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
ssh_fingerprint_re = re.compile(r"^SHA256:[A-Za-z0-9+/=]+$")


def ensure_relpath_within_mission(label: str, relpath: str) -> pathlib.Path:
    candidate = (mission_dir / relpath).resolve()
    try:
        candidate.relative_to(mission_dir)
    except ValueError as exc:
        raise SystemExit(f"{label} must stay within the mission directory") from exc
    return candidate


def require_staged_file(label: str, relpath: str) -> pathlib.Path:
    candidate = ensure_relpath_within_mission(label, relpath)
    if not candidate.is_file():
        raise SystemExit(f"{label} must point to a staged file")
    return candidate


def require_ref_digest_match(label: str, artifact_ref: str, artifact_digest: str) -> None:
    ref_digest = artifact_ref.rsplit("@", 1)[1]
    if ref_digest != artifact_digest:
        raise SystemExit(f"{label}.artifact_ref digest must match {label}.artifact_digest")


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_sha256_sidecar(label: str, payload_relpath: str, payload_path: pathlib.Path) -> None:
    checksum_path = ensure_relpath_within_mission(f"{label}.sha256", f"{payload_relpath}.sha256")
    if not checksum_path.is_file():
        raise SystemExit(f"{label} requires a matching .sha256 sidecar")

    expected = ""
    with checksum_path.open("r", encoding="utf-8") as handle:
        for raw_line in handle:
            fields = raw_line.strip().split()
            if fields:
                expected = fields[0].lower()
                break

    if not plain_sha256_re.fullmatch(expected):
        raise SystemExit(f"{label}.sha256 must start with a 64-character sha256 hex digest")

    actual = sha256_file(payload_path)
    if actual != expected:
        raise SystemExit(f"{label}.sha256 does not match {label}")


def validate_authorized_key_file(label: str, path: pathlib.Path) -> None:
    lines = [line.strip() for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
    if len(lines) != 1:
        raise SystemExit(f"{label} must contain exactly one non-empty SSH public key line")
    if not lines[0].startswith("ssh-ed25519 "):
        raise SystemExit(f"{label} must contain an ssh-ed25519 public key")


def normalize_tar_member_name(name: str) -> str:
    member_path = pathlib.PurePosixPath(name)
    if member_path.is_absolute():
        raise SystemExit("mission selected_substrate.payload_relpath must not contain absolute paths")
    if ".." in member_path.parts:
        raise SystemExit("mission selected_substrate.payload_relpath must not escape the extracted bundle root")
    parts = [part for part in member_path.parts if part not in ("", ".")]
    return pathlib.PurePosixPath(*parts).as_posix() if parts else ""


def validate_substrate_bundle(payload_path: pathlib.Path, manifest_path: pathlib.Path) -> None:
    try:
        with tarfile.open(payload_path, "r:gz") as archive:
            file_members: dict[str, tarfile.TarInfo] = {}
            has_platform_image_tar = False
            for member in archive.getmembers():
                normalized_name = normalize_tar_member_name(member.name)
                if member.issym() or member.islnk():
                    raise SystemExit("mission selected_substrate.payload_relpath must not contain symlinks or hard links")
                if not normalized_name or member.isdir():
                    continue
                file_members[normalized_name] = member
                if normalized_name.startswith("platform/images/") and normalized_name.endswith(".tar"):
                    has_platform_image_tar = True

            required_files = {
                "manifest.env": "mission selected_substrate.payload_relpath bundle missing manifest.env",
                "k3s/k3s": "mission selected_substrate.payload_relpath bundle missing k3s binary",
                f"k3s/k3s-images-{expected_arch}.tar": f"mission selected_substrate.payload_relpath bundle missing k3s images tar for {expected_arch}",
                "platform/images.lock.json": "mission selected_substrate.payload_relpath bundle missing platform/images.lock.json",
                "platform/profile.env": "mission selected_substrate.payload_relpath bundle missing platform/profile.env",
            }
            for required_name, error_message in required_files.items():
                if required_name not in file_members:
                    raise SystemExit(error_message)
            if not has_platform_image_tar:
                raise SystemExit("mission selected_substrate.payload_relpath bundle missing platform image tar payloads")

            manifest_member = file_members["manifest.env"]
            extracted_manifest = archive.extractfile(manifest_member)
            if extracted_manifest is None:
                raise SystemExit("mission selected_substrate.payload_relpath bundle manifest.env is unreadable")
            if extracted_manifest.read() != manifest_path.read_bytes():
                raise SystemExit("mission selected_substrate.manifest_relpath must match the tarball manifest.env content")

            parse_result = subprocess.run(
                [
                    sys.executable,
                    str(strict_metadata_parser),
                    str(manifest_path),
                    "--allow",
                    "OURBOX_SUBSTRATE_SCHEMA",
                    "--allow",
                    "OURBOX_SUBSTRATE_KIND",
                    "--allow",
                    "OURBOX_SUBSTRATE_SOURCE",
                    "--allow",
                    "OURBOX_SUBSTRATE_REVISION",
                    "--allow",
                    "OURBOX_SUBSTRATE_VERSION",
                    "--allow",
                    "OURBOX_SUBSTRATE_CREATED",
                    "--allow",
                    "OURBOX_PLATFORM_CONTRACT_REF",
                    "--allow",
                    "OURBOX_SUBSTRATE_ARCH",
                    "--allow",
                    "K3S_VERSION",
                    "--allow",
                    "OURBOX_PLATFORM_PROFILE",
                    "--allow",
                    "OURBOX_PLATFORM_IMAGES_LOCK_PATH",
                    "--allow",
                    "OURBOX_PLATFORM_IMAGES_LOCK_SHA256",
                    "--require",
                    "OURBOX_SUBSTRATE_SOURCE",
                    "--require",
                    "OURBOX_SUBSTRATE_REVISION",
                    "--require",
                    "OURBOX_SUBSTRATE_VERSION",
                    "--require",
                    "OURBOX_SUBSTRATE_CREATED",
                    "--require",
                    "OURBOX_SUBSTRATE_ARCH",
                    "--require",
                    "K3S_VERSION",
                    "--require",
                    "OURBOX_PLATFORM_PROFILE",
                    "--require",
                    "OURBOX_PLATFORM_IMAGES_LOCK_PATH",
                    "--require",
                    "OURBOX_PLATFORM_IMAGES_LOCK_SHA256",
                    "--print",
                    "OURBOX_SUBSTRATE_SOURCE",
                    "--print",
                    "OURBOX_SUBSTRATE_REVISION",
                    "--print",
                    "OURBOX_SUBSTRATE_VERSION",
                    "--print",
                    "OURBOX_SUBSTRATE_CREATED",
                    "--print",
                    "OURBOX_SUBSTRATE_ARCH",
                    "--print",
                    "K3S_VERSION",
                    "--print",
                    "OURBOX_PLATFORM_PROFILE",
                    "--print",
                    "OURBOX_PLATFORM_IMAGES_LOCK_PATH",
                    "--print",
                    "OURBOX_PLATFORM_IMAGES_LOCK_SHA256",
                ],
                capture_output=True,
                check=False,
                text=True,
            )
            if parse_result.returncode != 0:
                raise SystemExit(
                    "mission selected_substrate.manifest_relpath is invalid:\n"
                    + parse_result.stderr.strip()
                )
            fields = parse_result.stdout.splitlines()
            if len(fields) != 9:
                raise SystemExit("mission selected_substrate.manifest_relpath parse returned an unexpected field count")
            manifest_substrate_arch = fields[4]
            manifest_images_lock_path = fields[7]
            manifest_images_lock_sha = fields[8]

            if manifest_substrate_arch != expected_arch:
                raise SystemExit(
                    f"mission selected_substrate.manifest_relpath arch mismatch: expected {expected_arch}, got {manifest_substrate_arch}"
                )
            if manifest_images_lock_path != "platform/images.lock.json":
                raise SystemExit(
                    "mission selected_substrate.manifest_relpath must declare OURBOX_PLATFORM_IMAGES_LOCK_PATH=platform/images.lock.json"
                )
            if not plain_sha256_re.fullmatch(manifest_images_lock_sha):
                raise SystemExit("mission selected_substrate.manifest_relpath carries an invalid OURBOX_PLATFORM_IMAGES_LOCK_SHA256")
    except tarfile.TarError as exc:
        raise SystemExit(f"mission selected_substrate.payload_relpath is not a valid gzip tarball: {exc}") from exc


if manifest.get("kind") != "ourbox-mission":
    raise SystemExit("mission-manifest.json must declare kind=ourbox-mission")
requested = manifest.get("requested")
if not isinstance(requested, dict) or not requested:
    raise SystemExit("mission requested must be present")
resolved = manifest.get("resolved")
if not isinstance(resolved, dict) or not resolved:
    raise SystemExit("mission resolved must be present")

target = manifest.get("target") or {}
if target.get("id") != adapter["target_id"]:
    raise SystemExit("mission target id does not match the adapter target")
if target.get("media_kind") != "installer-usb":
    raise SystemExit("mission target media_kind must be installer-usb")

adapter_block = manifest.get("adapter") or {}
if adapter_block.get("adapter_json_relpath") != "vendor/matchbox/adapter.json":
    raise SystemExit("mission adapter.adapter_json_relpath must be vendor/matchbox/adapter.json")

mission_media = manifest.get("mission_media") or {}
if mission_media.get("compose_strategy") != "matchbox-fat-image-with-host-selected-os-and-substrate":
    raise SystemExit("mission compose strategy must be matchbox-fat-image-with-host-selected-os-and-substrate")

substrate = resolved.get("substrate") or {}
if substrate.get("strategy") != "published-installer-substrate":
    raise SystemExit("mission substrate.strategy must be published-installer-substrate")
if substrate.get("compose_entrypoint") != "tools/media-adapter/compose-media.sh":
    raise SystemExit("mission substrate.compose_entrypoint must point to the Matchbox compose entrypoint")
artifact_ref = str(substrate.get("artifact_ref", "")).strip()
artifact_digest = str(substrate.get("artifact_digest", "")).strip()
if not pinned_ref_re.fullmatch(artifact_ref):
    raise SystemExit("mission substrate.artifact_ref must be digest-pinned")
if not sha256_re.fullmatch(artifact_digest):
    raise SystemExit("mission substrate.artifact_digest must be sha256:...")
require_ref_digest_match("substrate", artifact_ref, artifact_digest)

selected_os = resolved.get("os") or {}
os_artifact_ref = str(selected_os.get("artifact_ref", "")).strip()
os_artifact_digest = str(selected_os.get("artifact_digest", "")).strip()
os_artifact_type = str(selected_os.get("artifact_type", "")).strip()
if not pinned_ref_re.fullmatch(os_artifact_ref):
    raise SystemExit("mission selected_os.artifact_ref must be digest-pinned")
if not sha256_re.fullmatch(os_artifact_digest):
    raise SystemExit("mission selected_os.artifact_digest must be sha256:...")
if os_artifact_type != expected_type:
    raise SystemExit(
        f"mission selected_os.artifact_type must be {expected_type}, found {os_artifact_type!r}"
    )
require_ref_digest_match("selected_os", os_artifact_ref, os_artifact_digest)

os_payload = selected_os.get("payload") or {}
os_payload_relpath = str(os_payload.get("relpath", "")).strip()
os_payload_sha = str(os_payload.get("sha256", "")).strip()
os_payload_size = os_payload.get("size_bytes")
if not os_payload_relpath:
    raise SystemExit("mission selected_os.payload.relpath is required")
if not plain_sha256_re.fullmatch(os_payload_sha):
    raise SystemExit("mission selected_os.payload.sha256 must be 64 lowercase hex chars")
if not isinstance(os_payload_size, int) or os_payload_size < 0:
    raise SystemExit("mission selected_os.payload.size_bytes must be a non-negative integer")
staged_os_payload = require_staged_file("selected_os.payload.relpath", os_payload_relpath)
if staged_os_payload.resolve() != expected_payload:
    raise SystemExit("mission selected_os.payload.relpath does not match the provided --os-payload file")
if sha256_file(staged_os_payload) != os_payload_sha:
    raise SystemExit("mission selected_os.payload.sha256 does not match the staged OS payload")
if staged_os_payload.stat().st_size != os_payload_size:
    raise SystemExit("mission selected_os.payload.size_bytes does not match the staged OS payload")
validate_sha256_sidecar("selected_os.payload.relpath", os_payload_relpath, staged_os_payload)

os_meta_relpath = str(selected_os.get("metadata_relpath", "")).strip()
staged_os_meta = require_staged_file("selected_os.metadata_relpath", os_meta_relpath)
if staged_os_meta.resolve() != expected_meta:
    raise SystemExit("mission selected_os.metadata_relpath does not match the provided --os-meta-env file")

parse_os_meta = subprocess.run(
    [
        sys.executable,
        str(strict_metadata_parser),
        str(staged_os_meta),
        "--allow",
        "OS_IMAGE_BASENAME",
        "--allow",
        "OS_IMAGE_SHA256",
        "--allow",
        "OS_IMAGE_SIZE_BYTES",
        "--allow",
        "OS_ARTIFACT_TYPE",
        "--allow",
        "OURBOX_TARGET",
        "--allow",
        "OURBOX_VARIANT",
        "--allow",
        "OURBOX_VERSION",
        "--allow",
        "OURBOX_SKU",
        "--allow",
        "BUILD_TS",
        "--allow",
        "GIT_SHA",
        "--allow",
        "K3S_VERSION",
        "--allow",
        "OURBOX_SUBSTRATE_REF",
        "--allow",
        "OURBOX_SUBSTRATE_DIGEST",
        "--allow",
        "OURBOX_SUBSTRATE_SOURCE",
        "--allow",
        "OURBOX_SUBSTRATE_REVISION",
        "--allow",
        "OURBOX_SUBSTRATE_VERSION",
        "--allow",
        "OURBOX_SUBSTRATE_CREATED",
        "--allow",
        "OURBOX_SUBSTRATE_ARCH",
        "--allow",
        "OURBOX_SUBSTRATE_PROFILE",
        "--allow",
        "OURBOX_SUBSTRATE_K3S_VERSION",
        "--allow",
        "OURBOX_SUBSTRATE_IMAGES_LOCK_SHA256",
        "--require",
        "OS_ARTIFACT_TYPE",
        "--print",
        "OS_ARTIFACT_TYPE",
    ],
    capture_output=True,
    check=False,
    text=True,
)
if parse_os_meta.returncode != 0:
    raise SystemExit("selected_os.metadata_relpath is invalid:\n" + parse_os_meta.stderr.strip())
os_meta_fields = parse_os_meta.stdout.splitlines()
if len(os_meta_fields) != 1:
    raise SystemExit("selected_os.metadata_relpath parse returned an unexpected field count")
if os_meta_fields[0] != expected_type:
    raise SystemExit("selected_os.metadata_relpath OS_ARTIFACT_TYPE does not match the adapter expectation")

selected_substrate = resolved.get("selected_substrate") or {}
substrate_artifact_ref = str(selected_substrate.get("artifact_ref", "")).strip()
substrate_artifact_digest = str(selected_substrate.get("artifact_digest", "")).strip()
substrate_arch = str(selected_substrate.get("arch", "")).strip()
if not pinned_ref_re.fullmatch(substrate_artifact_ref):
    raise SystemExit("mission selected_substrate.artifact_ref must be digest-pinned")
if not sha256_re.fullmatch(substrate_artifact_digest):
    raise SystemExit("mission selected_substrate.artifact_digest must be sha256:...")
if substrate_arch != expected_arch:
    raise SystemExit(f"mission selected_substrate.arch must be {expected_arch}")
require_ref_digest_match("selected_substrate", substrate_artifact_ref, substrate_artifact_digest)

substrate_payload_relpath = str(selected_substrate.get("payload_relpath", "")).strip()
substrate_manifest_relpath = str(selected_substrate.get("manifest_relpath", "")).strip()
staged_substrate_payload = require_staged_file("selected_substrate.payload_relpath", substrate_payload_relpath)
staged_substrate_manifest = require_staged_file("selected_substrate.manifest_relpath", substrate_manifest_relpath)
validate_sha256_sidecar("selected_substrate.payload_relpath", substrate_payload_relpath, staged_substrate_payload)
validate_substrate_bundle(staged_substrate_payload, staged_substrate_manifest)

selected_applications = resolved.get("applications")
supported_selection_modes = {"catalog-defaults", "all-apps", "custom"}
if not isinstance(selected_applications, dict) or not selected_applications:
    raise SystemExit("mission selected_applications must be present")
else:
    catalog_id = str(selected_applications.get("catalog_id", "")).strip()
    catalog_name = str(selected_applications.get("catalog_name", "")).strip()
    selection_mode = str(selected_applications.get("selection_mode", "")).strip()
    catalog_relpath = selected_applications.get("catalog_relpath")
    images_lock_relpath = selected_applications.get("images_lock_relpath")
    selection_relpath = selected_applications.get("selection_relpath")
    selected_app_ids = selected_applications.get("selected_app_ids")
    if not catalog_id:
        raise SystemExit("mission selected_applications.catalog_id must be set")
    if not catalog_name:
        raise SystemExit("mission selected_applications.catalog_name must be set")
    if selection_mode not in supported_selection_modes:
        raise SystemExit(
            "mission selected_applications.selection_mode must be one of catalog-defaults, all-apps, custom"
        )
    if not catalog_relpath:
        raise SystemExit("mission selected_applications.catalog_relpath must be set")
    if not images_lock_relpath:
        raise SystemExit("mission selected_applications.images_lock_relpath must be set")
    if not selection_relpath:
        raise SystemExit("mission selected_applications.selection_relpath must be set")
    if not isinstance(selected_app_ids, list) or not selected_app_ids:
        raise SystemExit("mission selected_applications.selected_app_ids must be a non-empty list")

    normalized_app_ids = []
    seen_ids = set()
    for raw_app_id in selected_app_ids:
        app_id = str(raw_app_id).strip()
        if not app_id:
            raise SystemExit("mission selected_applications.selected_app_ids contains an empty app id")
        if app_id in seen_ids:
            raise SystemExit(f"mission selected_applications.selected_app_ids duplicates app id {app_id}")
        seen_ids.add(app_id)
        normalized_app_ids.append(app_id)

    catalog_path = require_staged_file("mission selected_applications.catalog_relpath", catalog_relpath)
    images_lock_path = require_staged_file("mission selected_applications.images_lock_relpath", images_lock_relpath)
    selection_path = require_staged_file("mission selected_applications.selection_relpath", selection_relpath)

    with catalog_path.open("r", encoding="utf-8") as handle:
        catalog_data = json.load(handle)
    if catalog_data.get("schema") != 1:
        raise SystemExit("mission application catalog must declare schema=1")
    if catalog_data.get("kind") != "ourbox-application-catalog":
        raise SystemExit("mission application catalog kind must be 'ourbox-application-catalog'")
    if str(catalog_data.get("catalog_id", "")) != catalog_id:
        raise SystemExit("mission application catalog catalog_id must match selected_applications.catalog_id")
    if str(catalog_data.get("catalog_name", "")) != catalog_name:
        raise SystemExit("mission application catalog catalog_name must match selected_applications.catalog_name")
    catalog_apps = catalog_data.get("apps")
    if not isinstance(catalog_apps, list) or not catalog_apps:
        raise SystemExit("mission application catalog must declare a non-empty apps list")
    catalog_app_ids = set()
    for app in catalog_apps:
        app_id = str(app.get("id", "")).strip()
        if not app_id:
            raise SystemExit("mission application catalog contains an app without an id")
        catalog_app_ids.add(app_id)
    unknown_app_ids = [app_id for app_id in normalized_app_ids if app_id not in catalog_app_ids]
    if unknown_app_ids:
        raise SystemExit(
            "mission selected_applications.selected_app_ids must be a subset of mission application catalog apps"
        )

    with images_lock_path.open("r", encoding="utf-8") as handle:
        images_lock_data = json.load(handle)
    if images_lock_data.get("schema") != 1:
        raise SystemExit("mission application images lock must declare schema=1")
    images = images_lock_data.get("images")
    if not isinstance(images, list) or not images:
        raise SystemExit("mission application images lock must declare a non-empty images list")
    seen_image_names = set()
    for image in images:
        image_name = str(image.get("name", "")).strip()
        image_ref = str(image.get("ref", "")).strip()
        if not image_name:
            raise SystemExit("mission application images lock contains an image without a name")
        if image_name in seen_image_names:
            raise SystemExit(f"mission application images lock duplicates image name {image_name}")
        if not image_ref:
            raise SystemExit(f"mission application images lock entry {image_name} is missing a ref")
        seen_image_names.add(image_name)

    with selection_path.open("r", encoding="utf-8") as handle:
        selection_data = json.load(handle)
    if selection_data.get("schema") != 1:
        raise SystemExit("mission selected applications file must declare schema=1")
    if selection_data.get("kind") != "ourbox-selected-applications":
        raise SystemExit("mission selected applications file kind must be 'ourbox-selected-applications'")
    if str(selection_data.get("catalog_id", "")) != catalog_id:
        raise SystemExit("mission selected applications file catalog_id must match selected_applications.catalog_id")
    if str(selection_data.get("selection_mode", "")) != selection_mode:
        raise SystemExit("mission selected applications file selection_mode must match selected_applications.selection_mode")

    selection_ids = selection_data.get("selected_app_ids")
    if not isinstance(selection_ids, list) or not selection_ids:
        raise SystemExit("mission selected applications file must declare a non-empty selected_app_ids list")

    normalized_selection_ids = []
    seen_selection_ids = set()
    for raw_app_id in selection_ids:
        app_id = str(raw_app_id).strip()
        if not app_id:
            raise SystemExit("mission selected applications file contains an empty app id")
        if app_id in seen_selection_ids:
            raise SystemExit(f"mission selected applications file duplicates app id {app_id}")
        seen_selection_ids.add(app_id)
        normalized_selection_ids.append(app_id)

    if normalized_selection_ids != normalized_app_ids:
        raise SystemExit("mission selected applications file does not match selected_applications.selected_app_ids")

installed_target_ssh = resolved.get("installed_target_ssh")
if installed_target_ssh is not None:
    mode = str(installed_target_ssh.get("mode", "")).strip()
    if mode != "host-generated-authorized-key":
        raise SystemExit("installed_target_ssh.mode must be host-generated-authorized-key when present")
    key_name = str(installed_target_ssh.get("key_name", "")).strip()
    if not key_name_re.fullmatch(key_name):
        raise SystemExit("installed_target_ssh.key_name is invalid")
    key_type = str(installed_target_ssh.get("key_type", "")).strip()
    if key_type != "ssh-ed25519":
        raise SystemExit("installed_target_ssh.key_type must be ssh-ed25519")
    fingerprint = str(installed_target_ssh.get("public_key_fingerprint", "")).strip()
    if not ssh_fingerprint_re.fullmatch(fingerprint):
        raise SystemExit("installed_target_ssh.public_key_fingerprint is invalid")
    authorized_key_relpath = str(installed_target_ssh.get("authorized_key_relpath", "")).strip()
    authorized_key_path = require_staged_file("installed_target_ssh.authorized_key_relpath", authorized_key_relpath)
    validate_authorized_key_file("installed_target_ssh.authorized_key_relpath", authorized_key_path)

staged_files = manifest.get("staged_files")
if not isinstance(staged_files, list) or not staged_files:
    raise SystemExit("mission staged_files must be a non-empty list")
seen_relpaths: set[str] = set()
for item in staged_files:
    relpath = str(item.get("relpath", "")).strip()
    sha256 = str(item.get("sha256", "")).strip()
    size_bytes = item.get("size_bytes")
    if not relpath:
        raise SystemExit("mission staged_files entries must declare relpath")
    if relpath in seen_relpaths:
        raise SystemExit(f"mission staged_files contains duplicate relpath: {relpath}")
    candidate = require_staged_file("staged_files.relpath", relpath)
    if not plain_sha256_re.fullmatch(sha256):
        raise SystemExit(f"mission staged_files entry {relpath!r} carries an invalid sha256")
    if not isinstance(size_bytes, int) or size_bytes < 0:
        raise SystemExit(f"mission staged_files entry {relpath!r} carries an invalid size_bytes")
    if sha256_file(candidate) != sha256:
        raise SystemExit(f"mission staged_files entry {relpath!r} sha256 does not match the staged file")
    if candidate.stat().st_size != size_bytes:
        raise SystemExit(f"mission staged_files entry {relpath!r} size_bytes does not match the staged file")
    seen_relpaths.add(relpath)
PY

log "Matchbox mission media contract validated: ${MISSION_DIR}"
