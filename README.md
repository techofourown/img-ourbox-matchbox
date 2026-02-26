# img-ourbox-matchbox

Build repository for **OurBox Matchbox** OS images targeting **Raspberry Pi hardware** (Pi 5 + dual NVMe, Matchbox-class hardware).

This repo produces an NVMe-bootable OS that mounts `/var/lib/ourbox` and boots into an airgapped
single-node k3s runtime via `ourbox-bootstrap`.

## Identifiers used by this repo

- **Model ID**: `TOO-OBX-MBX-01` (physical device class)
- **Default SKU (part number)**: `TOO-OBX-MBX-BASE-001` (exact BOM/software build)

Model identifies the physical hardware class; SKU identifies the exact bill-of-materials and software configuration.

## Docs

- Operator runbook: [`docs/OPS.md`](./docs/OPS.md)
- Contracts reference: [`docs/reference/contracts.md`](./docs/reference/contracts.md)

## Happy path (desktop → installer media → Pi NVMe install)

```bash
cd ~
git clone --recurse-submodules https://github.com/techofourown/img-ourbox-matchbox.git
cd img-ourbox-matchbox
./tools/prepare-installer-media.sh
# move media to Pi, boot, follow prompts, device powers off, remove media, boot NVMe
```

The script now requires interactive media selection during runtime. It will list
removable/USB disks, show mount details, and ask you to choose a target.

Fallback (direct build+flash on the device):

```bash
./tools/ops-e2e.sh
```
