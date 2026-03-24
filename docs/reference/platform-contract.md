# Platform Contract Consumption (Matchbox)

Matchbox is **only a consumer** of platform software. All manifests, static assets, and platform
images come from `sw-ourbox-os` via pinned OCI artifacts; nothing is authored or fetched ad-hoc in
this repo.

---

## Sources of truth

- `sw-ourbox-os` ADR-0009 (platform contract as OCI artifact)
- `sw-ourbox-os` artifact docs: https://github.com/techofourown/sw-ourbox-os/blob/main/docs/architecture/artifact-distribution-and-integration.md
- Approved upstream snapshot in `sw-ourbox-os/release/approved-upstream-inputs.json`
- Repo-local pointer to that approved snapshot:
  - `tools/approved-upstream-inputs.upstream.env`

This repo does not independently approve or redefine TOOO-produced upstream
digests in source control.

---

## Current state (OCI by digest)

Repo-local Matchbox OS and installer-substrate builds pull two GHCR artifacts
published by `sw-ourbox-os`:

1) **platform-contract** (arch-agnostic)
   - Contents: manifests, landing, todo-bloom assets, contract metadata
   - Pulled via `./tools/fetch-platform-contract.sh`
   - Synced into pi-gen via `./tools/sync-platform-contract-into-pigen.sh`

2) **ourbox-substrate** (arch-specific: arm64/amd64)
   - Contents: `k3s` binary, `k3s-airgap-images-<arch>.tar`, platform image tars, `manifest.env`
   - Pulled via `./tools/fetch-ourbox-substrate.sh` (which also triggers the contract sync)
   - Injected by pi-gen stage `02-ourbox-substrate`

Runtime expectation (in the built image):
- `/opt/ourbox/airgap/k3s/{k3s,k3s-airgap-images-*.tar}`
- `/opt/ourbox/airgap/platform/images/*.tar`
- `/opt/ourbox/airgap/platform/manifests/**`
- `/opt/ourbox/airgap/platform/{landing,todo-bloom}/**`
- `/opt/ourbox/airgap/platform/contract.env` + `contract.digest`

---

## Provenance recording

During build, `ourbox-release` generation records platform contract provenance in
`/etc/ourbox/release`:
- `OURBOX_PLATFORM_CONTRACT_SOURCE`
- `OURBOX_PLATFORM_CONTRACT_REVISION`
- `OURBOX_PLATFORM_CONTRACT_VERSION`
- `OURBOX_PLATFORM_CONTRACT_CREATED`
- `OURBOX_PLATFORM_CONTRACT_DIGEST`

---

## Updating approved inputs

1. Approve the new upstream snapshot in `sw-ourbox-os/release/approved-upstream-inputs.json`.
2. Update `tools/approved-upstream-inputs.upstream.env` to the upstream revision/path
   that contains that approved snapshot.
3. Let the official candidate workflow resolve exact upstream refs at workflow start.
4. For local/manual runs outside the workflow wrappers, provide explicit
   `OURBOX_PLATFORM_CONTRACT_REF` / `OURBOX_SUBSTRATE_REF` values.
5. Run `./tools/fetch-ourbox-substrate.sh` to pull/sync into `pigen/`.
6. Rebuild images; update release notes/changelog with the new digests.

Host-composed installer media is separate:

- `sw-ourbox-installer` chooses the Matchbox OS payload and the Matchbox
  application bundle on the host
- that host tool stages a mission directory and embeds it into the published
  Matchbox installer substrate
- the Matchbox target installer then consumes only those embedded local mission
  bytes

---

## Relationship to OS image distribution

OCI distribution of the OS image (`os.img.xz`) is transport only (see ADR-0003). Platform contract
identity is separate and governed by `sw-ourbox-os`.

---

## Related docs

- `docs/decisions/ADR-0004-consume-platform-contract-from-sw-ourbox-os.md`
- `docs/reference/contracts.md`
- `docs/OPS.md`
