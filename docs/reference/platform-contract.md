# Platform Input Consumption (Matchbox)

Matchbox consumes two upstream platform inputs published by `sw-ourbox-os`:

1. `platform-contract`
2. `ourbox-substrate`

They play different roles:

- `platform-contract` is the arch-agnostic runtime platform payload. It carries
  platform manifests, static assets, and the helper scripts Matchbox bootstrap
  executes on-device.
- `ourbox-substrate` is the arch-specific transport bundle. It carries `k3s`,
  the normalized `k3s-images-<arch>.tar` payload, platform image tars, and
  `manifest.env`.

Matchbox does not define platform content locally. It stages these upstream
artifacts into the image and then runs the shipped platform tooling at runtime.

## Sources of truth

- `sw-ourbox-os` artifact docs:
  `docs/architecture/artifact-distribution-and-integration.md`
- `sw-ourbox-os` downstream surface docs:
  `docs/reference/downstream-consumer-surfaces.md`
- approved upstream snapshot in
  `sw-ourbox-os/release/approved-upstream-inputs.json`
- repo-local pointer to that approved snapshot:
  `tools/approved-upstream-inputs.upstream.env`

This repo does not independently approve TOOO-produced upstream identities in
its own source control.

## Current consumption model

Repo-local Matchbox OS and installer-substrate builds pull both upstream
artifacts by pinned ref:

1. `platform-contract` (arch-agnostic)
   - fetched by `./tools/fetch-platform-contract.sh`
   - validated by `./tools/validate-platform-contract-shape.sh`
   - synced into pi-gen by `./tools/sync-platform-contract-into-pigen.sh`

2. `ourbox-substrate` (arch-specific)
   - fetched by `./tools/fetch-ourbox-substrate.sh`
   - normalized runtime payload name:
     `k3s/k3s-images-<arch>.tar`
   - injected by pi-gen stage `02-ourbox-substrate`

Runtime layout in the built image:

- `/opt/ourbox/substrate/k3s/{k3s,k3s-images-*.tar}`
- `/opt/ourbox/substrate/platform/images/*.tar`
- `/opt/ourbox/substrate/platform/manifests/**`
- `/opt/ourbox/substrate/platform/{landing,todo-bloom}/**`
- `/opt/ourbox/substrate/platform/tools/{contract-identity.sh,render-contract.py,verify-runtime.sh}`

## Runtime rule

Runtime and installer behavior must be driven by:

- exact selected artifact identities
- local bundle-shape validation
- required runtime capabilities exposed by the shipped platform tooling

They must not be driven by duplicated platform-contract metadata such as copied
digest or version fields.

## Provenance rule

Primary build and publish provenance for Matchbox now lives in the
`OURBOX_SUBSTRATE_*` fields recorded in artifact metadata and installed-system
release files.

Legacy `OURBOX_PLATFORM_CONTRACT_*` fields may still appear while the remaining
cleanup lands, but they are informational trace only. They are not compatibility
gates.

## Updating approved inputs

1. Approve the new upstream snapshot in
   `sw-ourbox-os/release/approved-upstream-inputs.json`.
2. Update `tools/approved-upstream-inputs.upstream.env` to the upstream
   revision/path carrying that approved snapshot.
3. Let the official candidate workflow resolve exact upstream refs at workflow
   start.
4. For local/manual runs outside the workflow wrappers, provide explicit
   `OURBOX_PLATFORM_CONTRACT_REF` and `OURBOX_SUBSTRATE_REF` values.
5. Run `./tools/fetch-ourbox-substrate.sh` to pull and sync the approved inputs
   into `pigen/`.
6. Rebuild images and update release notes with the new artifact identities.

Host-composed installer media is separate:

- `sw-ourbox-installer` chooses the Matchbox OS payload on the host
- `sw-ourbox-installer` stages the selected substrate bundle and mission bytes
  on the host
- the Matchbox target installer consumes only those embedded local mission bytes

## Relationship to OS image distribution

OCI distribution of the OS image (`os.img.xz`) is transport only. The runtime
platform payload is still sourced from `sw-ourbox-os`, but mission and runtime
compatibility are anchored to exact selected artifacts and local validation, not
to copied platform-contract metadata.

## Related docs

- `docs/decisions/ADR-0004-consume-platform-contract-from-sw-ourbox-os.md`
- `docs/reference/contracts.md`
- `docs/OPS.md`
