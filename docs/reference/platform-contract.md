# Platform Contract Consumption (Matchbox)

This document describes how `img-ourbox-matchbox` consumes the OurBox OS **platform contract**
defined by `sw-ourbox-os`.

It is intentionally **Phase 0 / documentation-first**: it explains today's "vendored baseline"
reality and the future OCI-by-digest destination.

If this doc disagrees with reality, update this doc or fix the implementation — do not let drift
persist silently.

---

## Source of truth

The platform contract (baseline manifests + platform components contract) is defined in:

- `sw-ourbox-os` ADR-0009 (platform contract as OCI artifact):
  https://github.com/techofourown/sw-ourbox-os/blob/main/docs/decisions/ADR-0009-package-the-platform-contract-as-an-oci-artifact.md

- `sw-ourbox-os` integration reference:
  https://github.com/techofourown/sw-ourbox-os/blob/main/docs/architecture/artifact-distribution-and-integration.md

This repo is a **consumer**.

---

## Current state (Phase 0): vendored baseline manifests inside the image

Today, Matchbox images embed an airgap platform directory under:

- `/opt/ourbox/airgap/platform/`

In this repo, that content is staged via pi-gen under:

- `pigen/stages/stage-ourbox-matchbox/02-airgap-platform/files/opt/ourbox/airgap/platform/`

This is allowed during Phase 0, but it must be treated as an **upstream platform contract snapshot**
— not as a freehand "platform policy playground."

---

## Required provenance recording

Because Phase 0 vendoring can drift, we require an explicit provenance boundary.

The installed system MUST record platform contract provenance in:

- `/etc/ourbox/release`

Required keys:
- `OURBOX_PLATFORM_CONTRACT_SOURCE`
- `OURBOX_PLATFORM_CONTRACT_REVISION`

Optional keys (when available):
- `OURBOX_PLATFORM_CONTRACT_VERSION`
- `OURBOX_PLATFORM_CONTRACT_DIGEST`

See also: `docs/reference/contracts.md`.

---

## Phase 0 update procedure (vendoring workflow)

When you update the embedded baseline manifests:

1. **Choose an upstream `sw-ourbox-os` revision**
   - Prefer a tagged release when available (e.g., `v0.x.y`)
   - Otherwise record the exact git SHA

2. **Update the vendored baseline content**
   - Copy/update the platform baseline manifests and any required airgap assets in the image staging
     directory (`pigen/stages/stage-ourbox-matchbox/02-airgap-platform/`).
   - Treat this as "importing a contract snapshot," not "tweaking whatever."

3. **Update `/etc/ourbox/release` generation**
   - Ensure the build (substage `00-ourbox-contract`) writes:
     - `OURBOX_PLATFORM_CONTRACT_SOURCE`
     - `OURBOX_PLATFORM_CONTRACT_REVISION`
   - If you imported from a release tag, also write:
     - `OURBOX_PLATFORM_CONTRACT_VERSION`

4. **Document the change**
   - Add a short CHANGELOG entry stating the upstream contract revision/version you imported.

5. **Keep image references disciplined**
   - As we move into Phase 1, baseline manifests SHOULD reference app/container images by digest.
   - Do not introduce "latest" tags in baseline manifests.

---

## Future state (Phase 2): consume platform contract as an OCI artifact by digest

Destination model:

- `sw-ourbox-os` publishes a platform contract OCI artifact
- Image repos consume it by digest:
  - build-time embed (airgap), OR
  - first-boot fetch (network-optional, but must support offline export paths)

When OCI packaging exists, `OURBOX_PLATFORM_CONTRACT_DIGEST` becomes the authoritative identity
marker on device.

This repo should then minimize vendored YAML drift: the image consumes the upstream artifact rather
than carrying a forked copy forever.

---

## Relationship to OS image OCI distribution

This repo may also distribute the flashable OS image (`os.img.xz`) via OCI registry mechanics
(ADR-0003). That is **transport** for the flashable image bytes.

Platform contract identity and provenance are separate and are defined by:
- ADR-0004 (this repo)
- `sw-ourbox-os` ADR-0009 (upstream)

---

## Related docs

- `docs/decisions/ADR-0004-consume-platform-contract-from-sw-ourbox-os.md`
- `docs/reference/contracts.md`
- `docs/OPS.md`
