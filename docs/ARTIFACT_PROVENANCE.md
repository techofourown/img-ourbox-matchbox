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

| Channel tag(s) | Artifact | Trigger |
|---|---|---|
| `rpi-beta` / `rpi-installer-beta` | OS image / Installer | Push to `main` using approved upstream input intent resolved at workflow start (currently materialized by transitional `release/official-inputs.env`) (heavy build) |
| `rpi-stable` / `rpi-installer-stable` | OS image / Installer | Promotion after both candidate completion and matching GitHub Release `published` authorization are true; whichever arrives second wakes the retag (no rebuild) |
| `rpi-nightly` / `rpi-installer-nightly` | OS image / Installer | Scheduled integration build using floating upstream `edge` refs (heavy build) |
| `rpi-exp-labs` / `rpi-installer-exp-labs` | OS image / Installer | Promotion after both candidate completion and matching GitHub Release `prereleased` authorization are true; whichever arrives second wakes the retag (no rebuild) |

Registry namespaces (from `release/official-artifacts.env`):
- OS image: `ghcr.io/techofourown/ourbox-matchbox-os`
- Installer: `ghcr.io/techofourown/ourbox-matchbox-installer`

Heavy publish lanes create immutable build tags (`main-<sha12>-rpi`, `nightly-<sha12>-rpi`) and
their installer equivalents. Stable and exp-labs promotions add versioned aliases to an existing
digest instead of rebuilding it.

Moving channel tags (`rpi-beta`, `rpi-stable`, `rpi-nightly`, `rpi-exp-labs`) always point to the
latest artifact in that channel.
A catalog tag (`rpi-catalog`) accumulates one TSV row per published build.

---

## Trusted release contexts

- Push to protected `main` branch (beta candidate build)
- Scheduled nightly integration publish (floating upstream `edge` inputs)
- Candidate completion on protected `main` plus GitHub Release `published` authorization for stable promotion; either event may wake promotion when the other condition is already satisfied
- Candidate completion on protected `main` plus GitHub Release `prereleased` authorization for exp-labs promotion; either event may wake promotion when the other condition is already satisfied

These are the only authorized triggers for the official publication lane.
`workflow_dispatch` is intentionally absent from all official publish/promote workflows.

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
| Official candidate | `.github/workflows/official-candidate.yml` | `[self-hosted, official-heavy, pi-image]` | Push to `main` (source-filtered) |
| Integration nightly | `.github/workflows/integration-nightly.yml` | `[self-hosted, official-heavy, pi-image]` | Daily cron |
| Official promote stable | `.github/workflows/official-promote-stable.yml` | `ubuntu-latest` | Candidate completion or release publication; promotes only when both candidate success and matching GitHub Release `published` authorization are present |
| Official exp-labs promote | `.github/workflows/official-exp-labs.yml` | `ubuntu-latest` | Candidate completion or prerelease publication; promotes only when both candidate success and matching GitHub Release `prereleased` authorization are present |

The heavy build lanes (`official-candidate.yml`, `integration-nightly.yml`) run on
organization-controlled build infrastructure in the `official-heavy-artifacts` runner group.
Promotion workflows run on `ubuntu-latest` because they retag an existing digest rather than
rebuilding it.

### Trigger filtering

`official-candidate.yml` uses `paths-ignore` to skip publication for documentation-only changes.
The following paths do not trigger a candidate build when changed:

```
docs/**
README.md
CLAUDE.md
```

All other paths are treated as potentially artifact-affecting and do trigger the candidate build.
If a source change lands outside these ignored paths, it will trigger publication even if it
does not materially affect the built image.

`integration-nightly.yml` is schedule-driven and intentionally ignores repo path filters.
The dual-condition promotion workflows are also unfiltered because they do not rebuild: they
only retag an already-published immutable digest after both candidate provenance and the explicit
GitHub Release authorization are present for that source commit.

### Forcing an official republish without source changes

Touch `release/REVALIDATION_TRIGGER` in a PR. That file is not in the `paths-ignore` list,
so merging a change to it will trigger `official-candidate.yml`. Use this when you need an
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
| `org.opencontainers.image.version` | `OURBOX_VERSION` env (`main-<sha12>` / `nightly-<sha12>` / local `dev`) |
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
- `os.meta.json` / `installer.meta.json` — JSON form of the same flat metadata map for machine-readable consumption
- `os.img.xz.sha256` / `installer.img.xz.sha256` — SHA-256 checksum for offline verification
- `os.info` / `installer.info` — pi-gen build info (if present)

Canonical artifact identity for consumption is **by digest** (e.g., `ghcr.io/techofourown/ourbox-matchbox-os@sha256:...`).

Promotion workflows do not rewrite the artifact payload or its embedded metadata. Stable and
exp-labs semantics live in the promoted tags and catalog rows; the underlying artifact keeps the
channel-neutral build identity from the heavy publish lane.

Candidate workflows now emit `candidate-provenance.json` as the authoritative workflow handoff.
Stable and exp-labs promotion consumes that provenance bundle only, reconstructs `meta.env` /
`meta.json` outputs from it, and does not pull source artifact metadata sidecars during promotion.
Promotion also writes `os-artifact.promote.json` and `installer-artifact.promote.json` as the
workflow provenance record for the retag operation.

---

## Upstream input resolution

The official candidate build still consumes exact OCI artifact identities from
`sw-ourbox-os`, but the authoritative approval surface is the upstream approved
snapshot in `sw-ourbox-os/release/approved-upstream-inputs.json`, not a
repo-local checked-in copy of those digests.

Current transitional materialization:

```
PLATFORM_CONTRACT_REF=ghcr.io/techofourown/sw-ourbox-os/platform-contract@sha256:<digest>
AIRGAP_PLATFORM_REF=ghcr.io/techofourown/sw-ourbox-os/airgap-platform@sha256:<digest>
```

`release/official-inputs.env` currently materializes that approved snapshot for
compatibility with the existing candidate workflow. It is a transitional
generated surface, MUST NOT be hand-edited as policy, and MUST NOT be treated
as the normative official model for TOOO-to-TOOO upstream approval.

The scheduled nightly integration build intentionally overrides the approved
snapshot at workflow time by resolving the latest upstream `edge` digests
before building.

---

## Cryptographic signatures and attestations

**No cryptographic signatures or attestations are currently used.**

Provenance is established via OCI annotations, generated candidate / publish
records, the exact upstream refs used by the workflow, and the
`os.meta.env`/`installer.meta.env` files accompanying each artifact. Users
should consume artifacts by digest to ensure they receive exactly what was
published.

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
- `release/official-inputs.env` — transitional generated materialization of the approved upstream snapshot
