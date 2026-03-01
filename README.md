# img-ourbox-matchbox

Build repository for **OurBox Matchbox** OS images targeting **Raspberry Pi hardware** (Pi 5 + dual NVMe, Matchbox-class hardware).

This repo produces an NVMe-bootable OS that mounts `/var/lib/ourbox` and boots into an airgapped
single-node k3s runtime via `ourbox-bootstrap`.

## Identifiers used by this repo

- **Model ID**: `TOO-OBX-MBX-01` (physical device class)
- **Default SKU (part number)**: `TOO-OBX-MBX-BASE-001` (exact BOM/software build)

Model identifies the physical hardware class; SKU identifies the exact bill-of-materials and software configuration.

## Docs

- Operator runbook: [`docs/OPS.md`](./docs/OPS.md)
- Contracts reference: [`docs/reference/contracts.md`](./docs/reference/contracts.md)

## Status

**Official nightly builds are live.** OS and installer artifacts are published automatically on
every push to `main` via organization-controlled build infrastructure.

| Channel | OS artifact | Installer artifact |
|---|---|---|
| Nightly | `ghcr.io/techofourown/ourbox-matchbox-os:rpi-nightly` | `ghcr.io/techofourown/ourbox-matchbox-installer:rpi-installer-nightly` |
| Stable | `ghcr.io/techofourown/ourbox-matchbox-os:rpi-stable` | `ghcr.io/techofourown/ourbox-matchbox-installer:rpi-installer-stable` |

Stable is promoted on `v*` tag push. All artifacts are digest-addressable OCI artifacts on GHCR.
See [`docs/ARTIFACT_PROVENANCE.md`](./docs/ARTIFACT_PROVENANCE.md) for official release channels,
provenance metadata, and how to verify artifacts.

## Installing OurBox on a Raspberry Pi

### From official published artifacts (default)

```bash
git clone --recurse-submodules https://github.com/techofourown/img-ourbox-matchbox.git
cd img-ourbox-matchbox
./tools/prepare-installer-media.sh
# move media to Pi, boot, follow prompts, device powers off, remove media, boot NVMe
```

`prepare-installer-media.sh` defaults to pulling the published `rpi-installer-stable` artifact
from GHCR, verifying its checksum, and flashing your selected removable/USB media.

### Local source build (maintainer / offline path)

Requires: Linux desktop, sudo, Podman, ~30 min build time.

```bash
git clone --recurse-submodules https://github.com/techofourown/img-ourbox-matchbox.git
cd img-ourbox-matchbox
./tools/prepare-installer-media.sh --build-local
# move media to Pi, boot, follow prompts, device powers off, remove media, boot NVMe
```

This fetches the pinned upstream airgap bundle, runs pi-gen, and flashes the result.
See [`docs/OPS.md`](./docs/OPS.md) for full prerequisites and troubleshooting.

## Release pipeline

Official artifacts are built and published automatically once the self-hosted builder is running:

- Push to `main` → `official-nightly.yml` → nightly OS + installer artifacts on `rpi-nightly` / `rpi-installer-nightly`
- Push `v*` tag → `official-release.yml` → versioned + stable OS + installer artifacts on `rpi-stable` / `rpi-installer-stable`

Publication targets and upstream input pins are repo-defined in `release/`:

- `release/official-artifacts.env` — official GHCR repos and channel names
- `release/official-inputs.env` — digest-pinned upstream refs (update via PR when `sw-ourbox-os` ships new bundles)
