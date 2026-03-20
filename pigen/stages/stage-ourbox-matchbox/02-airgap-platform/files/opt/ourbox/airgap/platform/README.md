# Platform contract (generated)

This directory is populated at build time from the resolved platform contract
OCI artifact selected by the official workflow.

Source of truth:
- `sw-ourbox-os/release/approved-upstream-inputs.json` (authoritative approved
  input intent)
- generated build-time resolution records such as the current transitional
  `release/official-inputs.env`
- techofourown/sw-ourbox-os (platform-contract publisher)

This synced tree now includes:
- profile inputs and image locks under `profiles/`
- the upstream render tool under `tools/`
- a pre-rendered default bundle under `rendered/defaults/`

Target bootstraps are expected to render from this upstream tree with runtime inputs such as
`BOX_HOST`, then apply the rendered manifests.

Do not hand-edit files here.
