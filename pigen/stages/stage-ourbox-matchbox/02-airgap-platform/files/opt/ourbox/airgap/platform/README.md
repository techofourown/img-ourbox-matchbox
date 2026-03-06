# Platform contract (generated)

This directory is populated at build time from the pinned platform contract OCI artifact.

Source of truth:
- contracts/platform-contract.ref (pinned digest)
- techofourown/sw-ourbox-os (platform-contract publisher)

This synced tree now includes:
- profile inputs and image locks under `profiles/`
- the upstream render tool under `tools/`
- a pre-rendered default bundle under `rendered/defaults/`

Target bootstraps are expected to render from this upstream tree with runtime inputs such as
`BOX_HOST`, then apply the rendered manifests.

Do not hand-edit files here.
