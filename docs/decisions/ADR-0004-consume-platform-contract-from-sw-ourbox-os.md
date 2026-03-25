# ADR-0004: Consume the OurBox OS Platform Contract from `sw-ourbox-os`

> Status note (2026-03): Matchbox now consumes both `platform-contract` and
> `ourbox-substrate` as pinned OCI inputs from `sw-ourbox-os`. Compatibility is
> enforced by exact selected artifact identities plus local bundle and
> capability checks, not by contract-digest matching.


## Context

This repository (`img-ourbox-matchbox`) produces a **flashable OS image** for the Matchbox hardware.
It is responsible for:

- bootability + base OS configuration
- disk/storage contract enforcement
- first-boot bootstrap services (k3s bring-up, applying baseline manifests, etc.)
- offline friendliness

Historically, image repos often become the accidental "home" of the platform baseline (the manifests
and components that make the box feel like an appliance). That creates drift and makes it easy for
the platform baseline to change without a clear upstream provenance boundary.

At the org level, TOOO adopted OCI artifacts + digests as the canonical distribution substrate for
apps and platform components (org ADR-0007). In `sw-ourbox-os`, we allocated that posture into an
explicit **platform contract artifact** concept (ADR-0009 + integration doc).

This image repo must align with that model:

> `sw-ourbox-os` defines the platform contract. Image repos consume it.

This preserves "one lane, explicit trust" while keeping the official baseline legible and hard to
quietly alter.

## Decision

### 1) Source of truth

The OurBox OS **platform contract** consumed by Matchbox images SHALL be sourced from
`sw-ourbox-os`, not defined ad-hoc in this repo.

Canonical upstream docs:
- `sw-ourbox-os` ADR-0009 (platform contract as OCI artifact)
- `sw-ourbox-os` artifact distribution + integration reference

### 2) Phase 0 allowance (vendored baseline is permitted, but must be traceable)

Until the platform contract is packaged and consumed as an OCI artifact by digest, this repo MAY
vendor a copy of the baseline manifests (e.g., as part of staged substrate/platform content).

However:
- Vendored baseline content MUST be traceable to a specific `sw-ourbox-os` revision (and ideally a version).
- Baseline changes MUST be treated as upstream contract updates, not "random tweaks in the image repo."

### 3) Provenance is mandatory

The installed system MUST record enough upstream provenance in
`/etc/ourbox/release` so operators can answer what platform baseline is running
locally.

Required current provenance centers on exact selected artifact identity and
substrate provenance. Obsolete copied platform-contract metadata fields are not
part of the current provenance contract.

### 4) Current runtime posture

This repo now consumes pinned upstream artifacts during build. Matchbox runtime
then validates shipped files and helper capabilities locally. The intended
compatibility rule is exact selected bytes plus local shape and capability
checks, not copied contract-digest parity.

## Rationale

- Keeps the platform baseline "officialness" anchored in one producer repo.
- Prevents silent baseline drift across multiple image repos.
- Makes support and debugging possible: "show me the platform contract revision/digest."
- Preserves hackability: users can replace the contract, but the provenance boundary stays legible.

## Consequences

### Positive
- Clear producer/consumer boundary: `sw-ourbox-os` produces the contract, image repos consume it.
- Image repos become more mechanical: hardware enablement + bootstrap, not "platform policy."
- Helps later trust hardening (signatures / release manifests) land cleanly.

### Negative
- Requires discipline when vendoring baseline content during Phase 0.
- Adds additional release metadata fields to maintain.

### Mitigation
- Add a dedicated reference doc describing the Phase 0 vendoring workflow and future OCI-by-digest
  consumption (`docs/reference/platform-contract.md`).
- Keep the required provenance keys small and stable.

## References

- Org ADR-0007:
  https://github.com/techofourown/org-techofourown/blob/main/docs/decisions/ADR-0007-adopt-oci-artifacts-for-app-distribution.md
- `sw-ourbox-os` ADR-0009:
  https://github.com/techofourown/sw-ourbox-os/blob/main/docs/decisions/ADR-0009-package-the-platform-contract-as-an-oci-artifact.md
- `sw-ourbox-os` integration reference:
  https://github.com/techofourown/sw-ourbox-os/blob/main/docs/architecture/artifact-distribution-and-integration.md
- Reference: `docs/reference/platform-contract.md` (this repo)
