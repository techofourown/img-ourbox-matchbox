#!/usr/bin/env bash
set -euo pipefail

# Shared installer-selection policy lives upstream in sw-ourbox-os.
# Consumers may vendor this file into target-specific installer images, but the
# contract and reference implementation are defined here.

ourbox_selection_log() {
  printf '[%s] %s\n' "$(date -Is)" "$*" >&2
}

ourbox_selection_die() {
  ourbox_selection_log "ERROR: $*"
  exit 1
}

ourbox_selection_need_cmd() {
  command -v "$1" >/dev/null 2>&1 || ourbox_selection_die "missing required command: $1"
}

ourbox_selection_reset_state() {
  OURBOX_INSTALL_DEFAULTS_SOURCE="baked"
  OURBOX_INSTALL_DEFAULTS_PROFILE=""
  OURBOX_INSTALL_SELECTION_SOURCE=""
  OURBOX_RELEASE_CHANNEL=""
  OURBOX_CATALOG_REF=""
  OURBOX_SELECTED_REF=""
  OURBOX_PULL_REF=""
  OURBOX_OS_ARTIFACT_SOURCE="registry"
  OURBOX_OS_ARTIFACT_REF=""
  OURBOX_OS_ARTIFACT_DIGEST=""
}

ourbox_selection_is_clean_single_line_ref() {
  local ref="${1:-}"
  [[ -n "${ref}" ]] || return 1
  [[ "${ref}" != *$'\n'* ]] || return 1
  [[ "${ref}" != *$'\r'* ]] || return 1
  [[ "${ref}" != *$'\t'* ]] || return 1
  [[ "${ref}" != *" "* ]] || return 1
  return 0
}

ourbox_selection_is_digest_pinned_ref() {
  local ref="${1:-}"
  ourbox_selection_is_clean_single_line_ref "${ref}" || return 1
  [[ "${ref}" =~ ^[^[:space:]]+@sha256:[0-9a-f]{64}$ ]] || return 1
  return 0
}

ourbox_selection_channel_tag() {
  local channel="${1:-}"
  local target="${OS_TARGET:-}"
  local tag=""
  case "${channel}" in
    stable) tag="${CHANNEL_STABLE_TAG:-}"; [[ -n "${tag}" ]] || tag="${target}-stable" ;;
    beta) tag="${CHANNEL_BETA_TAG:-}"; [[ -n "${tag}" ]] || tag="${target}-beta" ;;
    nightly) tag="${CHANNEL_NIGHTLY_TAG:-}"; [[ -n "${tag}" ]] || tag="${target}-nightly" ;;
    exp-labs) tag="${CHANNEL_EXP_LABS_TAG:-}"; [[ -n "${tag}" ]] || tag="${target}-exp-labs" ;;
    *) tag="${target}-${channel}" ;;
  esac
  [[ -n "${tag}" ]] || ourbox_selection_die "unable to resolve channel tag for '${channel}'"
  printf '%s\n' "${tag}"
}

ourbox_selection_load_remote_install_defaults() {
  local pull_dir="$1"
  local extract_dir="$2"
  local override_env="${3:-}"
  local baked_os_default_ref="${OS_DEFAULT_REF:-}"
  local expected_installer_id="${INSTALLER_ID:-}"

  OURBOX_INSTALL_DEFAULTS_SOURCE="baked"
  OURBOX_INSTALL_DEFAULTS_PROFILE=""

  [[ -n "${INSTALL_DEFAULTS_REF:-}" ]] || return 0

  ourbox_selection_need_cmd oras
  rm -rf "${pull_dir}" "${extract_dir}"
  mkdir -p "${pull_dir}" "${extract_dir}"

  ourbox_selection_log "Pulling installer defaults: ${INSTALL_DEFAULTS_REF}"
  if ! oras pull "${INSTALL_DEFAULTS_REF}" -o "${pull_dir}" >/dev/null 2>&1; then
    ourbox_selection_log "Install defaults pull failed; using baked defaults."
    return 0
  fi

  local tarball=""
  if [[ -f "${pull_dir}/dist/install-defaults.tar.gz" ]]; then
    tarball="${pull_dir}/dist/install-defaults.tar.gz"
  else
    tarball="$(find "${pull_dir}" -maxdepth 4 -type f -name 'install-defaults.tar.gz' | head -n 1 || true)"
  fi
  [[ -n "${tarball}" && -f "${tarball}" ]] || {
    ourbox_selection_log "Install defaults artifact missing tarball; using baked defaults."
    return 0
  }

  if ! tar -xzf "${tarball}" -C "${extract_dir}" >/dev/null 2>&1; then
    ourbox_selection_log "Install defaults tar extraction failed; using baked defaults."
    return 0
  fi

  [[ -f "${extract_dir}/install-defaults/schema.env" ]] || {
    ourbox_selection_log "Install defaults artifact missing schema.env; using baked defaults."
    return 0
  }
  [[ -f "${extract_dir}/install-defaults/manifest.env" ]] || {
    ourbox_selection_log "Install defaults artifact missing manifest.env; using baked defaults."
    return 0
  }

  local profile="${extract_dir}/install-defaults/defaults/${expected_installer_id}.env"
  if [[ ! -f "${profile}" ]]; then
    ourbox_selection_log "No install-defaults profile for installer '${expected_installer_id}'; using baked defaults."
    return 0
  fi

  # shellcheck disable=SC1090
  source "${profile}"
  if [[ -n "${override_env}" && -f "${override_env}" ]]; then
    # Re-apply local overrides so operators keep final control.
    # shellcheck disable=SC1090
    source "${override_env}"
  fi

  if declare -F normalize_payload_config >/dev/null 2>&1; then
    normalize_payload_config
  fi

  # A baked pinned default ref remains authoritative unless the remote profile
  # explicitly replaces it with another non-empty ref.
  if [[ -n "${baked_os_default_ref}" && -z "${OS_DEFAULT_REF:-}" ]]; then
    OS_DEFAULT_REF="${baked_os_default_ref}"
  fi

  # shellcheck disable=SC2034  # output state consumed by the sourcing installer
  OURBOX_INSTALL_DEFAULTS_SOURCE="remote"
  # shellcheck disable=SC2034  # output state consumed by the sourcing installer
  OURBOX_INSTALL_DEFAULTS_PROFILE="${profile}"
  ourbox_selection_log "Applied install-defaults profile for '${expected_installer_id}'."
}

ourbox_selection_pull_catalog() {
  local dst="$1"
  local ref="${OS_REPO}:${OS_CATALOG_TAG}"

  if [[ "${OS_CATALOG_ENABLED:-1}" != "1" ]]; then
    return 1
  fi

  ourbox_selection_need_cmd oras
  rm -rf "${dst}"
  mkdir -p "${dst}"

  ourbox_selection_log "Pulling catalog: ${ref}"
  if ! oras pull "${ref}" -o "${dst}" >/dev/null 2>&1; then
    return 1
  fi
  [[ -f "${dst}/catalog.tsv" ]] || return 1

  OURBOX_CATALOG_REF="${ref}"
  return 0
}

ourbox_selection_catalog_entries() {
  local catalog_tsv="$1"
  [[ -f "${catalog_tsv}" ]] || return 1

  awk -F'\t' '
    NR == 1 {
      for (i = 1; i <= NF; i++) {
        idx[$i] = i
      }
      if (!idx["channel"] || !idx["tag"] || !idx["created"] || !idx["version"] || !idx["platform_contract_digest"] || !idx["pinned_ref"]) {
        exit 0
      }
      next
    }
    {
      pinned = $(idx["pinned_ref"])
      created = $(idx["created"])
      if (created == "") {
        next
      }
      if (pinned !~ /^[^[:space:]]+@sha256:[0-9a-f]{64}$/) {
        next
      }
      print $(idx["channel"]) "\t" $(idx["tag"]) "\t" created "\t" $(idx["version"]) "\t" $(idx["platform_contract_digest"]) "\t" pinned
    }
  ' "${catalog_tsv}" | sort -t $'\t' -k3,3r -k2,2r
}

ourbox_selection_catalog_newest_ref() {
  local catalog_tsv="$1"
  local channel="$2"
  local row=""

  row="$(ourbox_selection_catalog_entries "${catalog_tsv}" | awk -F'\t' -v ch="${channel}" '$1 == ch { print; exit }' || true)"
  [[ -n "${row}" ]] || return 1
  printf '%s\n' "${row##*$'\t'}"
}

ourbox_selection_determine_default_ref() {
  local catalog_dir="$1"
  local channel_tag_ref=""
  local catalog_tsv=""
  local catalog_ref=""

  OURBOX_INSTALL_SELECTION_SOURCE=""
  OURBOX_RELEASE_CHANNEL=""
  OURBOX_SELECTED_REF=""
  # shellcheck disable=SC2034  # output state consumed by the sourcing installer
  OURBOX_CATALOG_REF=""

  if [[ -n "${OS_REF:-}" ]]; then
    OURBOX_INSTALL_SELECTION_SOURCE="os-ref"
    OURBOX_SELECTED_REF="${OS_REF}"
    return 0
  fi

  if [[ -n "${OS_DEFAULT_REF:-}" ]]; then
    OURBOX_INSTALL_SELECTION_SOURCE="os-default-ref"
    OURBOX_SELECTED_REF="${OS_DEFAULT_REF}"
    return 0
  fi

  channel_tag_ref="${OS_REPO}:$(ourbox_selection_channel_tag "${OS_CHANNEL}")"

  if [[ "${OS_CATALOG_ENABLED:-1}" == "1" ]]; then
    if ourbox_selection_pull_catalog "${catalog_dir}"; then
      catalog_tsv="${catalog_dir}/catalog.tsv"
      catalog_ref="$(ourbox_selection_catalog_newest_ref "${catalog_tsv}" "${OS_CHANNEL}" || true)"
      if ourbox_selection_is_digest_pinned_ref "${catalog_ref}"; then
        OURBOX_INSTALL_SELECTION_SOURCE="catalog"
        OURBOX_RELEASE_CHANNEL="${OS_CHANNEL}"
        OURBOX_SELECTED_REF="${catalog_ref}"
        return 0
      fi
      ourbox_selection_log "Catalog has no valid digest-pinned entry for channel '${OS_CHANNEL}'; falling back to channel tag."
    else
      ourbox_selection_log "Catalog unavailable; falling back to channel tag."
    fi
  fi

  # shellcheck disable=SC2034  # output state consumed by the sourcing installer
  OURBOX_INSTALL_SELECTION_SOURCE="channel-tag"
  # shellcheck disable=SC2034  # output state consumed by the sourcing installer
  OURBOX_RELEASE_CHANNEL="${OS_CHANNEL}"
  OURBOX_SELECTED_REF="${channel_tag_ref}"
}

ourbox_selection_ref_repo_base() {
  local ref="$1"
  local tail="${ref##*/}"

  if [[ "${ref}" == *@* ]]; then
    printf '%s\n' "${ref%%@*}"
    return 0
  fi

  # Registry ports live before the last slash and must be preserved. Only the
  # tag separator in the final path segment should be removed here.
  if [[ "${tail}" == *:* ]]; then
    printf '%s\n' "${ref%:*}"
  else
    printf '%s\n' "${ref}"
  fi
}

ourbox_selection_finalize_registry_ref() {
  local selected_ref="$1"
  local selected_ref_q=""
  local resolved_digest=""
  local repo_base=""

  if ! ourbox_selection_is_clean_single_line_ref "${selected_ref}"; then
    printf -v selected_ref_q '%q' "${selected_ref}"
    ourbox_selection_die "invalid selected OS artifact ref (must be non-empty, single-line, no whitespace): ${selected_ref_q}"
  fi

  ourbox_selection_need_cmd oras

  # shellcheck disable=SC2034  # output state consumed by the sourcing installer
  OURBOX_SELECTED_REF="${selected_ref}"
  OURBOX_PULL_REF="${selected_ref}"
  # shellcheck disable=SC2034  # output state consumed by the sourcing installer
  OURBOX_OS_ARTIFACT_SOURCE="registry"
  # shellcheck disable=SC2034  # output state consumed by the sourcing installer
  OURBOX_OS_ARTIFACT_REF="${selected_ref}"
  OURBOX_OS_ARTIFACT_DIGEST=""

  if ourbox_selection_is_digest_pinned_ref "${selected_ref}"; then
    OURBOX_OS_ARTIFACT_DIGEST="${selected_ref##*@}"
    return 0
  fi

  ourbox_selection_log "Resolving to immutable digest: ${selected_ref}"
  if resolved_digest="$(oras resolve "${selected_ref}" 2>/dev/null)" \
    && [[ "${resolved_digest}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    OURBOX_OS_ARTIFACT_DIGEST="${resolved_digest}"
    repo_base="$(ourbox_selection_ref_repo_base "${selected_ref}")"
    OURBOX_PULL_REF="${repo_base}@${resolved_digest}"
    ourbox_selection_log "Resolved: ${resolved_digest}"
    return 0
  fi

  if [[ "${OURBOX_ALLOW_UNRESOLVED_PULL:-0}" == "1" ]]; then
    ourbox_selection_log "WARNING: oras resolve failed; pulling by tag (OURBOX_ALLOW_UNRESOLVED_PULL=1)"
    ourbox_selection_log "WARNING: artifact identity will not be captured in provenance"
    # shellcheck disable=SC2034  # output state consumed by the sourcing installer
    OURBOX_OS_ARTIFACT_DIGEST="unresolved"
    # shellcheck disable=SC2034  # output state consumed by the sourcing installer
    OURBOX_PULL_REF="${selected_ref}"
    return 0
  fi

  ourbox_selection_die "Cannot establish artifact identity: oras resolve failed for ${selected_ref}
  The installer requires a digest-pinned artifact ref to ensure provenance.
  Options:
    1. Use a digest-pinned ref (catalog or OS_DEFAULT_REF usually provides this)
    2. Check registry connectivity and retry
    3. Set OURBOX_ALLOW_UNRESOLVED_PULL=1 to skip this check (dev/testing only)"
}
