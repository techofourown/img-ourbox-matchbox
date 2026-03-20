# img-ourbox-matchbox

Build repository for **OurBox Matchbox** OS images and installer substrate targeting
**Raspberry Pi hardware** (Pi 5 + dual NVMe, Matchbox-class hardware).

This repo produces an NVMe-bootable OS that mounts `/var/lib/ourbox` and boots into an airgapped
single-node k3s runtime via `ourbox-bootstrap`.

Installer and maintainer flash flows now use the same storage-role logic:

- you explicitly choose which NVMe becomes `SYSTEM`
- the other NVMe becomes `DATA` for that install
- a former `DATA` disk can be repurposed as `SYSTEM` with explicit destructive confirmation
- preserved `DATA` contents no longer suppress bootstrap permanently; bootstrap re-runs automatically when the shipped contract changes

## Identifiers used by this repo

- **Model ID**: `TOO-OBX-MBX-01` (physical device class)
- **Default SKU (part number)**: `TOO-OBX-MBX-BASE-001` (exact BOM/software build)

Model identifies the physical hardware class; SKU identifies the exact bill-of-materials and software configuration.

## Docs

- Upstream platform producer: [`sw-ourbox-os`](https://github.com/techofourown/sw-ourbox-os)
- Platform contract consumption: [`docs/reference/platform-contract.md`](./docs/reference/platform-contract.md)
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
from GHCR, but that published artifact is now only the Matchbox installer substrate.
The wrapper delegates to `sw-ourbox-installer`, which:

- selects the Matchbox target
- resolves the chosen OS payload on the host
- resolves the chosen arm64 application bundle on the host
- stages a local mission directory
- embeds that mission into the published Matchbox installer substrate
- flashes the composed mission media to your selected removable/USB device

The Matchbox target installer itself consumes only the embedded local mission bytes.
It does not perform target-time catalog browsing, install-defaults fetches,
registry logins, or ORAS pulls.

### Repo-local maintainer build path

This repo still owns the Matchbox target substrate:

```bash
git clone --recurse-submodules https://github.com/techofourown/img-ourbox-matchbox.git
cd img-ourbox-matchbox
./tools/fetch-airgap-platform.sh
sudo -E ./tools/build-image.sh
sudo -E ./tools/build-installer-image.sh
```

Those commands rebuild the Matchbox OS payload and the published Matchbox installer
substrate locally. Host-side mission composition and flashing still belong to
`sw-ourbox-installer`.

See [`docs/OPS.md`](./docs/OPS.md) for prerequisites and troubleshooting.

## Release pipeline

Official artifacts are built and published automatically once the self-hosted builder is running:

- Push to `main` → `official-candidate.yml` → promotable `beta` OS + installer artifacts on `rpi-beta` / `rpi-installer-beta`
- Daily cron → `integration-nightly.yml` → integration-preview artifacts on `rpi-nightly` / `rpi-installer-nightly`
- GitHub Release `published` → `official-promote-stable.yml` → promote the existing candidate digest into `rpi-stable` / `rpi-installer-stable`
- GitHub Release `prereleased` → `official-exp-labs.yml` → promote the existing candidate digest into `rpi-exp-labs` / `rpi-installer-exp-labs`

Publication targets are repo-defined in `release/`. Exact upstream identities
come from the upstream-approved input policy and are currently materialized here
only for compatibility:

- `release/official-artifacts.env` — official GHCR repos and channel names
- `release/official-inputs.env` — transitional generated materialization of the
  approved upstream snapshot

Official Matchbox installer builds publish only the Matchbox installer substrate.
They do not bake OS-selection defaults or target-time application-bundle defaults into
the image. Candidate builds currently consume the generated transitional
`release/official-inputs.env`; scheduled nightly integration builds resolve the
latest `sw-ourbox-os` `edge` digests at workflow time for the Matchbox OS image
build only.
