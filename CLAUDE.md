# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

Build system for **OurBox Matchbox OS images** targeting Raspberry Pi 5 with dual NVMe storage. Produces an NVMe-bootable OS that mounts persistent data and boots into an airgapped single-node k3s runtime. Built on top of pi-gen (git submodule at `vendor/pi-gen`, arm64 branch).

## Key Commands

### Full end-to-end build + flash (interactive, destructive)
```bash
sudo ./tools/ops-e2e.sh
```

### Individual steps (what ops-e2e.sh calls in order)
```bash
sudo ./tools/bootstrap-host.sh         # Install Podman, BuildKit, system deps (idempotent)
./tools/fetch-airgap-platform.sh       # Pull pinned airgap bundle (k3s + platform images) via ORAS
sudo ./tools/build-image.sh            # Run pi-gen, collect artifact into deploy/
sudo ./tools/flash-system-nvme.sh      # Wipe + flash SYSTEM NVMe disk
sudo ./tools/preboot-userconf.sh       # Write first-boot username/password
```

### Registry operations
```bash
./tools/publish-os-artifact.sh         # Push image as OCI artifact to registry
./tools/pull-os-artifact.sh            # Pull + extract from registry
./tools/mirror-required-images.sh      # Mirror container images to local registry
```

### Shell linting
```bash
shellcheck tools/*.sh
```

There is no formal test suite. Verification is manual: build, flash, boot, inspect.

## Architecture

### Build Pipeline (ops-e2e.sh)
1. **Bootstrap host** — install Podman + BuildKit + deps
2. **Fetch airgap artifacts** — pull pinned `airgap-platform` OCI artifact (k3s binary, k3s airgap images, platform images, manifest.env) + pinned `platform-contract` → `artifacts/airgap/`, `artifacts/platform-contract/`
3. **Build OS image** — pi-gen runs stages 0–2 (upstream) + `stage-ourbox-matchbox` (custom) → `deploy/*.img.xz`
4. **Flash SYSTEM disk** — wipe + dd to the non-DATA NVMe (exactly 2 NVMe disks required)
5. **Write userconf** — first-boot credentials to boot partition

### Custom pi-gen Stage (`pigen/stages/stage-ourbox-matchbox/`)
Each substage runs inside the pi-gen chroot:
- `00-ourbox-contract` — writes `/etc/ourbox/release` (product, device, SKU, variant, version, git hash)
- `01-storage-contract` — adds `LABEL=OURBOX_DATA` mount to `/etc/fstab` at `/var/lib/ourbox`
- `02-airgap-platform` — injects k3s binary + airgap tars into the rootfs
- `03-kernel-cgroups` — adds memory cgroup v2 flags to kernel cmdline

### Shared Shell Libraries
- `tools/lib.sh` — `log()`, `die()`, `need_cmd()`, `resolve_label()`, `cli_base()`
- `tools/registry.sh` — `pick_container_cli()`, `imgref()`, `mirror_image()`, `canonicalize_image_ref()`, `ensure_buildkitd()`
- `tools/versions.env` — host tool pins (BuildKit/ORAS). Platform pins live in `sw-ourbox-os` and are consumed via OCI.
- `tools/registry.env` — registry address and namespace (override via `registry.env.local`)

### Storage Contract
- Exactly 2 NVMe disks: one is SYSTEM (gets wiped), one is DATA (labeled `OURBOX_DATA`, ext4, mounted at `/var/lib/ourbox`)
- Label-based mounts survive NVMe device enumeration changes
- DATA disk is never wiped by flash scripts; operator prompted if prior state exists

### Container CLI Selection
Scripts auto-detect the container runtime via `pick_container_cli()`: Podman (preferred) → Docker → nerdctl. Override with `DOCKER=` env var. All run rootful (sudo when not root).

## Official Build Posture

Official OS and installer artifacts are produced by organization-controlled build infrastructure
per [ADR-0008](https://github.com/techofourown/org-techofourown/blob/main/docs/decisions/ADR-0008-adopt-organization-controlled-build-infrastructure-for-heavy-artifacts.md)
and the [Official Artifact Build and Provenance Policy](https://github.com/techofourown/org-techofourown/blob/main/docs/policies/OFFICIAL_ARTIFACT_BUILD_AND_PROVENANCE_POLICY.md).

- Official workflows (`official-nightly.yml`, `official-release.yml`) run on `[self-hosted, official-heavy, pi-image]` runners in the `official-heavy-artifacts` org runner group
- Official artifacts are digest-addressable OCI artifacts; see `release/official-artifacts.env` for repos and channel tags
- Upstream platform bundles are digest-pinned in `release/official-inputs.env` — update via PR when `sw-ourbox-os` ships new bundles
- See `docs/ARTIFACT_PROVENANCE.md` for the required audit record (artifact types, release channels, provenance metadata, signature status)

### Workflow safety check

`tools/check-workflow-safety.sh` (run in CI via `ci.yml`) enforces two trust boundary rules:

1. No workflow using a self-hosted runner may be triggered by `pull_request` or `pull_request_target` — prevents untrusted PR code from executing on privileged builders
2. No official publish workflow (those calling `tools/*/publish.sh`) may expose `workflow_dispatch` — official publication must only flow from push-to-main or tag push

## Conventions

- All shell scripts: `#!/usr/bin/env bash` + `set -euo pipefail`
- Commit messages: Conventional Commits (`feat:`, `fix:`, `chore:`, `docs:`) — semantic-release auto-versions on merge to `main`
- Version pinning in `tools/versions.env` — change deliberately, re-verify e2e, update docs
- pi-gen config in `pigen/config/ourbox.conf` — build identity, artifact naming, stage list
- ADRs in `docs/decisions/` — document significant architectural choices
- `docs/OPS.md` is the operator runbook and authority for build/flash/boot procedures
- Never commit build outputs (`deploy/`, `*.img`, `*.img.xz`) — `.gitignore` enforces this
