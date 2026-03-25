# img-ourbox-matchbox

Build repository for **OurBox Matchbox** OS images and installer substrate targeting
**Raspberry Pi hardware** (Pi 5 + dual NVMe, Matchbox-class hardware).

This repo produces an NVMe-bootable OS that mounts `/var/lib/ourbox` and boots into an offline
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
- Platform input consumption: [`docs/reference/platform-contract.md`](./docs/reference/platform-contract.md)
- Operator runbook: [`docs/OPS.md`](./docs/OPS.md)
- Contracts reference: [`docs/reference/contracts.md`](./docs/reference/contracts.md)

## Status

**Official nightly builds are live.** OS and installer artifacts are published automatically on
every push to `main` via organization-controlled build infrastructure.

Official channel tags: `rpi-beta`, `rpi-stable`, `rpi-nightly`, `rpi-exp-labs`,
`rpi-installer-beta`, `rpi-installer-stable`, `rpi-installer-nightly`,
`rpi-installer-exp-labs`

- Official candidate: push to `main` via `.github/workflows/official-candidate.yml` → publishes `rpi-beta` / `rpi-installer-beta`
- Integration nightly: daily cron via `.github/workflows/integration-nightly.yml` → publishes `rpi-nightly` / `rpi-installer-nightly`
- Stable promotion: GitHub Release `published` via `.github/workflows/official-promote-stable.yml`
- Exp-labs promotion: GitHub Release `prereleased` via `.github/workflows/official-exp-labs.yml`

All artifacts are digest-addressable OCI artifacts on GHCR.
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
- resolves the chosen substrate and mission payload on the host
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
./tools/fetch-ourbox-substrate.sh
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

Publication targets are repo-defined in `release/`, and upstream input intent is pinned by a
repo-local pointer to the approved upstream snapshot:

- `release/official-artifacts.env` — official GHCR repos and channel names
- `tools/approved-upstream-inputs.upstream.env` — pinned pointer to the approved
  `sw-ourbox-os` input snapshot revision/path

Official Matchbox installer builds publish only the Matchbox installer substrate.
They do not bake OS-selection defaults or target-time application-bundle defaults into
the image. Candidate builds resolve exact upstream refs from the approved
snapshot at workflow start. Scheduled nightly integration builds intentionally
resolve the latest `sw-ourbox-os` `edge` digests at workflow time for the
Matchbox OS image build only.
