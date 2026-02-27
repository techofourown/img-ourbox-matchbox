# Installer runtime fetch (Matchbox)

## Defaults
- Config shipped in image: `/opt/ourbox/installer/defaults.env`
- Optional override on boot media: `/boot/firmware/ourbox-installer.env`

Key variables:
- `OS_REPO` (default `ghcr.io/techofourown/ourbox-matchbox-os`)
- `OS_TARGET` (`rpi`)
- `OS_CHANNEL` (`stable`) – default moving tag is `${OS_TARGET}-${OS_CHANNEL}`
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
- Default action: pull `${OS_REPO}:${OS_TARGET}-stable` and install.
- Interactive options on boot:
  - `c` choose channel (stable/beta/nightly/exp-labs/custom)
  - `l` list entries from `${OS_TARGET}-catalog` if present
  - `r` enter custom ref (tag or digest)
- Installer boot waits for `network-online.target` and bootstraps ORAS if missing.

## Catalog TSV
- Tag: `${OS_TARGET}-catalog`
- Columns: `channel tag created version variant target sku git_sha platform_contract_digest k3s_version img_sha256`
- Kept up to date automatically by `tools/publish-os-artifact.sh` when channel tags are pushed.
