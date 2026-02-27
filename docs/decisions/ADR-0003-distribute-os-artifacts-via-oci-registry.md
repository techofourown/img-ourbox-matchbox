# ADR-0003: Distribute OS images as OCI artifacts via a container registry

## Status
Accepted

## Context

OS image builds produce large artifacts (`*.img.xz`) that must be transferred to other machines for:

- flashing devices
- reproducing or recovering builds
- sharing a known-good image with another operator

Ad-hoc file transfer (SCP/USB) works but is inconsistent and hard to standardize.

We already operate a container registry and have standard tooling to pull blobs efficiently.

## Decision

We will distribute OS images as **OCI artifacts (non-runnable)** pushed with **ORAS**, not as
container layers. Each artifact carries files directly:

- `os.img.xz`
- `os.img.xz.sha256`
- `os.meta.env` (KEY=VALUE metadata)
- optional `os.info`, `build.log`

Artifact type: `application/vnd.ourbox.matchbox.os-image.v1`

Implemented by:

- `tools/publish-os-artifact.sh` (oras push, supports immutable + channel tags, updates catalog)
- `tools/pull-os-artifact.sh` (oras pull, sha verification)

## Rationale

- Registries solve “large artifact distribution” well (storage + content addressing + caching).
- Every operator already has a container CLI.
- The artifact reference becomes a stable identifier.

## Consequences

### Positive
- Standard transport path for OS artifacts
- Easier repeatability (“pull this ref and flash it”)
- Works without a container runtime on the consumer (installer uses ORAS directly)

### Negative
- Requires registry access + trust (TLS/CA)
- Requires ORAS on hosts/installer (we bootstrap it)

### Mitigation
- Keep SCP/USB as a documented fallback
- Keep metadata alongside the image (`os.info`, `build.log`)
- Maintain a lightweight catalog (`${target}-catalog`) as a TSV ORAS artifact so installers can list
  available versions without downloading full images.

---

## Notes (2026-02-26)

This ADR is about **transporting flashable OS image bytes** (`os.img.xz`) using OCI registry
mechanics. It is compatible with the org-wide OCI posture, but it is intentionally narrower:

- It does **not** decide how apps are distributed (org ADR-0007).
- It does **not** define the OurBox OS **platform contract** (baseline manifests / platform
  components contract). Platform contract provenance and consumption are handled by ADR-0004 and the
  upstream `sw-ourbox-os` documentation.

---

## References

- Org ADR-0007 (OCI substrate for apps + platform components):
  https://github.com/techofourown/org-techofourown/blob/main/docs/decisions/ADR-0007-adopt-oci-artifacts-for-app-distribution.md
- `sw-ourbox-os` ADR-0009 (platform contract as OCI artifact):
  https://github.com/techofourown/sw-ourbox-os/blob/main/docs/decisions/ADR-0009-package-the-platform-contract-as-an-oci-artifact.md
- `sw-ourbox-os` integration reference (artifact distribution + integration contract):
  https://github.com/techofourown/sw-ourbox-os/blob/main/docs/architecture/artifact-distribution-and-integration.md
- ADR-0004 (this repo): Consume platform contract from `sw-ourbox-os`
