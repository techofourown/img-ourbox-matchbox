# Installer OCI migration (Feb 2026)

## What changed in img-ourbox-matchbox
- Installer no longer bakes an OS payload; it pulls an ORAS artifact at boot (default `${OS_REPO}:${OS_TARGET}-stable`).
- New runtime config: `/opt/ourbox/installer/defaults.env` (shipped) and optional override `/boot/firmware/ourbox-installer.env`.
- Installer fetch flow:
  - bootstraps ORAS v1.3.0 if missing (arm64)
  - optional registry login (OS_REGISTRY_USERNAME/PASSWORD)
  - optional catalog list (`${OS_TARGET}-catalog` TSV) for picking builds
  - fetches artifact files: `os.img.xz`, `os.img.xz.sha256`, `os.meta.env`
- Systemd service now waits for `network-online.target`.
- Build scripts no longer require a local payload to build the installer.
- `tools/publish-os-artifact.sh` now pushes ORAS artifacts (non-container) with:
  - artifact type `application/vnd.ourbox.matchbox.os-image.v1`
  - immutable tag (basename by default)
  - moving channel tags (default `${OURBOX_TARGET}-stable`)
  - catalog auto-update (`${OURBOX_TARGET}-catalog`) with metadata row
- `tools/pull-os-artifact.sh` uses ORAS and verifies sha256 if present.

## Expected artifact layout (ORAS payload)
- `os.img.xz`
- `os.img.xz.sha256` (first field is sha256)
- `os.meta.env` (KEY=VALUE; include version/target/sku/contract/k3s/git sha)
- optional: `os.info`, `build.log`
Artifact type: `application/vnd.ourbox.matchbox.os-image.v1`.

## Actions for sw-ourbox-os / release pipeline
1) Publish OS images with ORAS using the new script:
   - `OS_REPO=ghcr.io/techofourown/ourbox-matchbox-os ./tools/publish-os-artifact.sh deploy`
   - set `OS_CHANNEL_TAGS` (e.g., `rpi-stable rpi-beta rpi-nightly`) per release cadence.
   - immutable tag defaults to build basename; override via `OS_IMMUTABLE_TAG` if desired.
2) Ensure `os.meta.env` carries at least:
   - `OURBOX_TARGET`, `OURBOX_VARIANT`, `OURBOX_VERSION`, `OURBOX_SKU`
   - `GIT_SHA`, `BUILD_TS`
   - `OURBOX_PLATFORM_CONTRACT_DIGEST` (plus SOURCE/REVISION/VERSION/CREATED if known)
   - `K3S_VERSION`
   (the publish script populates these automatically today from local files + versions.env)
3) Keep catalog fresh:
   - The publish script appends/updates `${OS_TARGET}-catalog` automatically for each channel tag.
   - If you publish outside the script, push `catalog.tsv` with the same columns
     `channel tag created version variant target sku git_sha platform_contract_digest k3s_version img_sha256`.
4) For private registries, set `OS_REGISTRY_USERNAME/OS_REGISTRY_PASSWORD` in CI so publish/pull work.

## How to override installer at runtime
- Drop `/boot/firmware/ourbox-installer.env` on the installer media, e.g.:
  ```bash
  OS_REPO=ghcr.io/your-fork/ourbox-matchbox-os
  OS_TARGET=rpi
  OS_CHANNEL=beta        # or OS_REF=repo@sha256:...
  OS_CATALOG_ENABLED=1
  OS_REGISTRY_USERNAME=...
  OS_REGISTRY_PASSWORD=...
  ```
- On boot, press `l` to list catalog entries or `r` to paste a custom ref.

## Compatibility / rollback
- Old flow (payload baked into installer) is removed. Builds no longer look in `/ourbox/deploy` during installer image creation.
- Existing flash images are unaffected; only the installer behavior changes.
