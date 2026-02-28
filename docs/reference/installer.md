# Installer runtime fetch (Matchbox)

## Defaults
- Config shipped in image: `/opt/ourbox/installer/defaults.env`
- Optional override on boot media: `/boot/firmware/ourbox-installer.env`

Key variables:
- `INSTALL_DEFAULTS_REF` (default `ghcr.io/techofourown/sw-ourbox-os/install-defaults:stable`)
- `INSTALLER_ID` (`matchbox`)
- `OS_REPO` (default `ghcr.io/techofourown/ourbox-matchbox-os`)
- `OS_TARGET` (`rpi`)
- `OS_CHANNEL` (`stable`) – fallback channel if no explicit default ref is provided
- `OS_DEFAULT_REF` (optional digest/tag ref for "press ENTER" default)
- `CHANNEL_STABLE_TAG`, `CHANNEL_BETA_TAG`, `CHANNEL_NIGHTLY_TAG`, `CHANNEL_EXP_LABS_TAG`
- `OS_REF` (full ref, bypasses channel)
- `OS_CATALOG_ENABLED` (`1`) and `OS_CATALOG_TAG` (`${OS_TARGET}-catalog`)
- `OS_ORAS_VERSION` (`1.3.0`)
- `OS_REGISTRY_USERNAME` / `OS_REGISTRY_PASSWORD` (optional for private repos)

## Artifact contract (oras pull)
- Type: `application/vnd.ourbox.matchbox.os-image.v1`
- Required files:
  - `os.img.xz`
  - `os.img.xz.sha256` (first field is the digest; required, install fails if missing/invalid)
  - `os.meta.env` (KEY=VALUE; include version/target/sku/k3s/git sha + platform contract digest)
- Optional: `os.info`, `build.log`

## Runtime UX
- Installer loads baked defaults, then attempts to pull `${INSTALL_DEFAULTS_REF}` and apply `defaults/${INSTALLER_ID}.env`.
- If remote defaults pull fails, installer falls back to baked defaults.
- Boot-media override (`/boot/firmware/ourbox-installer.env`) is applied last and wins.
- Default action order:
  1) `OS_REF` (if set)
  2) `OS_DEFAULT_REF` (if set)
  3) `${OS_REPO}:<tag for OS_CHANNEL>` (stable/beta/nightly/exp-labs mapping)
- Interactive options on boot:
  - `c` choose channel (stable/beta/nightly/exp-labs/custom)
  - `l` list entries from `${OS_TARGET}-catalog` if present
  - `r` enter custom ref (tag or digest)
  - `o` override OS payload repo/tag defaults interactively
- Installer boot waits for `network-online.target` and bootstraps ORAS if missing.

## Catalog TSV
- Tag: `${OS_TARGET}-catalog`
- Columns: `channel tag created version variant target sku git_sha platform_contract_digest k3s_version img_sha256 artifact_digest pinned_ref`
- Kept up to date automatically by `tools/publish-os-artifact.sh` when channel tags are pushed.
