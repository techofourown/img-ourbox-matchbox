# Platform contract (generated)

This directory is populated at build time from the pinned platform contract OCI artifact.

Source of truth:
- `sw-ourbox-os/release/approved-upstream-inputs.json` (approved upstream input intent)
- `tools/approved-upstream-inputs.upstream.env` (repo-local pointer to that snapshot)
- workflow-time resolved pinned platform-contract ref recorded in build provenance
- techofourown/sw-ourbox-os (platform-contract publisher)

This synced tree now includes:
- profile inputs and image locks under `profiles/`
- the upstream render tool under `tools/`
- a pre-rendered default bundle under `rendered/defaults/`

Target bootstraps are expected to render from this upstream tree with runtime inputs such as
`BOX_HOST`, then apply the rendered manifests.

Do not hand-edit files here.
