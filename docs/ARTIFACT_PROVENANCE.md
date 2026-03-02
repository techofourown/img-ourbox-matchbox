# Artifact Provenance — OurBox Matchbox

This document is the required audit record for `img-ourbox-matchbox` per the
[Official Artifact Build and Provenance Policy](https://github.com/techofourown/org-techofourown/blob/main/docs/policies/OFFICIAL_ARTIFACT_BUILD_AND_PROVENANCE_POLICY.md)
and
[ADR-0008](https://github.com/techofourown/org-techofourown/blob/main/docs/decisions/ADR-0008-adopt-organization-controlled-build-infrastructure-for-heavy-artifacts.md).

---

## Artifact types produced

| Artifact | Description |
|---|---|
| OS image | Bootable NVMe OS image for Raspberry Pi 5 + dual NVMe (`.img.xz` + SHA-256 checksum + metadata) |
| Installer media | Bootable installer that writes the OS image to NVMe (`.img.xz` + SHA-256 checksum + metadata) |

Both are published as ORAS OCI artifacts (non-runnable) to GHCR.

---

## Official release channels

| Channel tag | Artifact | Trigger |
|---|---|---|
| `rpi-nightly` | OS image | Push to `main` |
| `rpi-installer-nightly` | Installer | Push to `main` |
| `rpi-stable` | OS image | `v*` tag push |
| `rpi-installer-stable` | Installer | `v*` tag push |

Registry namespaces (from `release/official-artifacts.env`):
- OS image: `ghcr.io/techofourown/ourbox-matchbox-os`
- Installer: `ghcr.io/techofourown/ourbox-matchbox-installer`

Each immutable tag is named after the build basename (e.g., `img-ourbox-matchbox-rpi-YYYYMMDD-HHMMSS`).
Moving channel tags (`rpi-nightly`, `rpi-stable`) always point to the latest build in that channel.
A catalog tag (`rpi-catalog`) accumulates one TSV row per published build.

---

## Trusted release contexts

- Push to `main` branch (nightly)
- Signed `v*` tag push (stable release)

These are the only authorized triggers for the official publication lane.
`workflow_dispatch` is intentionally absent from all official publish workflows.

---

## Public build entrypoints

| Operation | Entrypoint |
|---|---|
| End-to-end build + flash | `sudo ./tools/ops-e2e.sh` |
| Build OS image only | `sudo ./tools/build-image.sh` |
| Build installer image | `sudo ./tools/build-installer-image.sh` |
| Publish OS artifact | `./tools/publish-os-artifact.sh deploy` |
| Publish installer artifact | `./tools/publish-installer-artifact.sh deploy` |
| Flash to NVMe | `sudo ./tools/flash-system-nvme.sh` |
| Prepare installer media | `./tools/prepare-installer-media.sh` |

All build logic lives in this repository. Official and compatible builds use the same entrypoints.
Official status derives from the publication identity (TOOO-controlled GHCR namespace), not from
hidden build logic.

---

## Official release workflows

| Workflow | File | Runner | Trigger |
|---|---|---|---|
| Official nightly | `.github/workflows/official-nightly.yml` | `[self-hosted, official-heavy, pi-image]` | Push to `main` (source-filtered) |
| Official release | `.github/workflows/official-release.yml` | `[self-hosted, official-heavy, pi-image]` | `v*` tag push (all changes) |

Both run on organization-controlled build infrastructure in the `official-heavy-artifacts`
runner group. Third-party hosted runners are not used for artifact publication.

### Trigger filtering

`official-nightly.yml` uses `paths-ignore` to skip publication for documentation-only changes.
The following paths do not trigger a nightly build when changed:

```
docs/**
README.md
CLAUDE.md
```

All other paths are treated as potentially artifact-affecting and do trigger the nightly build.
If a source change lands outside these ignored paths, it will trigger publication even if it
does not materially affect the built image.

`official-release.yml` is not filtered — it triggers on explicit `v*` tag push, which is
always an intentional release act.

### Forcing an official republish without source changes

Touch `release/REVALIDATION_TRIGGER` in a PR. That file is not in the `paths-ignore` list,
so merging a change to it will trigger `official-nightly.yml`. Use this when you need an
official artifact after infrastructure maintenance or runner migration, without making a
substantive code change. See `release/REVALIDATION_TRIGGER` for the documented procedure.

### Non-publishing revalidation

`.github/workflows/revalidate-matchbox-build.yml` runs the full build pipeline on the official
builder weekly (Sunday 03:00 UTC) and on `workflow_dispatch`. It does NOT publish official
artifacts. Use it to confirm the release-capable path works after infrastructure changes, per
the ADR-0008 revalidation requirement.

---

## Provenance metadata

Every published artifact carries the following provenance in its OCI annotations:

| Field | Value source |
|---|---|
| `org.opencontainers.image.source` | `https://github.com/techofourown/img-ourbox-matchbox` |
| `org.opencontainers.image.revision` | Git commit SHA (short, 12 chars) |
| `org.opencontainers.image.version` | `OURBOX_VERSION` env (semver or `dev`) |
| `org.opencontainers.image.created` | Build timestamp (UTC, ISO 8601) |
| `techofourown.artifact.kind` | `os-image` or `installer-image` |
| `techofourown.target` | `rpi` |
| `techofourown.variant` | `prod` |
| `techofourown.sku` | `TOO-OBX-MBX-BASE-001` |
| `techofourown.platform-contract.digest` | Digest of `platform-contract` bundle baked in |
| `techofourown.build.workflow` | GitHub workflow name |
| `techofourown.build.run-id` | GitHub run ID |
| `techofourown.build.run-attempt` | GitHub run attempt |

Additional metadata is published as artifact files:

- `os.meta.env` / `installer.meta.env` — full provenance record including K3S version, upstream contract source/revision/version/digest, image SHA-256, and size
- `os.img.xz.sha256` / `installer.img.xz.sha256` — SHA-256 checksum for offline verification
- `os.info` / `installer.info` — pi-gen build info (if present)

Canonical artifact identity for consumption is **by digest** (e.g., `ghcr.io/techofourown/ourbox-matchbox-os@sha256:...`).

---

## Upstream input pinning

The official build consumes pinned OCI artifacts from `sw-ourbox-os` (defined in
`release/official-inputs.env`):

```
PLATFORM_CONTRACT_REF=ghcr.io/techofourown/sw-ourbox-os/platform-contract@sha256:<digest>
AIRGAP_PLATFORM_REF=ghcr.io/techofourown/sw-ourbox-os/airgap-platform@sha256:<digest>
```

These MUST be digest-pinned refs (never floating tags).

To update when `sw-ourbox-os` ships a new bundle:

```bash
# Re-resolve current digests
oras resolve ghcr.io/techofourown/sw-ourbox-os/platform-contract:edge
oras resolve ghcr.io/techofourown/sw-ourbox-os/airgap-platform:edge-arm64

# Update release/official-inputs.env with new digests, open a PR
```

The update must go through a PR so that the pinned refs are reviewed and the nightly build
picks up the new platform bundle.

---

## Cryptographic signatures and attestations

**No cryptographic signatures or attestations are currently used.**

Provenance is established via OCI annotations, digest-pinned upstream refs, and the
`os.meta.env`/`installer.meta.env` files accompanying each artifact. Users should consume
artifacts by digest to ensure they receive exactly what was published.

When signatures or attestations are adopted, they will be documented here and the claim will
only be made for artifacts that actually carry them, per policy rule 8.

---

## Compatible artifacts

Third parties may build compatible artifacts from this public source using the same documented
entrypoints, subject to their own environment configuration. Compatible artifacts built outside
TOOO-controlled publication are not official TOOO artifacts.

---

## References

- [OFFICIAL_ARTIFACT_BUILD_AND_PROVENANCE_POLICY](https://github.com/techofourown/org-techofourown/blob/main/docs/policies/OFFICIAL_ARTIFACT_BUILD_AND_PROVENANCE_POLICY.md)
- [ADR-0008: Organization-Controlled Build Infrastructure](https://github.com/techofourown/org-techofourown/blob/main/docs/decisions/ADR-0008-adopt-organization-controlled-build-infrastructure-for-heavy-artifacts.md)
- [ADR-0003: Distribute OS Artifacts via OCI Registry](./decisions/ADR-0003-distribute-os-artifacts-via-oci-registry.md)
- [ADR-0004: Consume Platform Contract from sw-ourbox-os](./decisions/ADR-0004-consume-platform-contract-from-sw-ourbox-os.md)
- [OPS.md — Operator Runbook](./OPS.md)
- `release/official-artifacts.env` — official publication targets
- `release/official-inputs.env` — digest-pinned upstream refs
