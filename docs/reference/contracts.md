# OurBox Matchbox host contracts

This repo produces an OS image that guarantees a small set of host/runtime
contracts. These contracts are the interface between image build, installer
media composition, and the platform runtime that starts on the device.

## Contract: Release metadata

### File

- `/etc/ourbox/release`

### Format

Line-oriented `KEY=VALUE` pairs (shell-friendly). Example keys:

- `OURBOX_PRODUCT`
- `OURBOX_DEVICE`
- `OURBOX_TARGET`
- `OURBOX_SKU`
- `OURBOX_VARIANT`
- `OURBOX_VERSION`
- `OURBOX_RECIPE_GIT_HASH`
- `OURBOX_SUBSTRATE_REF`
- `OURBOX_SUBSTRATE_DIGEST`
- `OURBOX_SUBSTRATE_SOURCE`
- `OURBOX_SUBSTRATE_REVISION`
- `OURBOX_SUBSTRATE_VERSION`
- `OURBOX_SUBSTRATE_CREATED`
- `OURBOX_SUBSTRATE_ARCH`
- `OURBOX_SUBSTRATE_PROFILE`
- `OURBOX_SUBSTRATE_K3S_VERSION`
- `OURBOX_SUBSTRATE_IMAGES_LOCK_SHA256`
- `OURBOX_INSTALLER_ID`
- `OURBOX_INSTALLER_VERSION`
- `OURBOX_INSTALLER_GIT_HASH`
- `OURBOX_OS_ARTIFACT_SOURCE`
- `OURBOX_OS_ARTIFACT_REF`
- `OURBOX_OS_ARTIFACT_DIGEST`
- `OURBOX_OS_IMAGE_SHA256`
- `OURBOX_INSTALL_DEFAULTS_SOURCE`
- `OURBOX_INSTALL_DEFAULTS_REF`
- `OURBOX_INSTALL_SELECTION_SOURCE`
- `OURBOX_RELEASE_CHANNEL`

Legacy `OURBOX_PLATFORM_CONTRACT_*` keys may still appear on systems built from
older payloads or transitional branches, but they are not the normative
compatibility surface.

### Platform input provenance (normative)

Matchbox images MUST record enough upstream provenance for operators to answer:

- "Which platform baseline did this image ship?"
- "What exact substrate and OS artifact identities does it correspond to?"

Minimum required substrate provenance:

- `OURBOX_SUBSTRATE_REF`
- `OURBOX_SUBSTRATE_DIGEST`
- `OURBOX_SUBSTRATE_SOURCE`
- `OURBOX_SUBSTRATE_REVISION`
- `OURBOX_SUBSTRATE_ARCH`

Additional fields such as `OURBOX_SUBSTRATE_VERSION`,
`OURBOX_SUBSTRATE_CREATED`, `OURBOX_SUBSTRATE_PROFILE`,
`OURBOX_SUBSTRATE_K3S_VERSION`, and
`OURBOX_SUBSTRATE_IMAGES_LOCK_SHA256` should be recorded when available.

If legacy `OURBOX_PLATFORM_CONTRACT_*` fields are present, treat them as trace
only. Do not use them as selection or compatibility gates.

See `docs/reference/platform-contract.md` for the full platform-input model.

### Why it exists

- debugging ("what build is on this device?")
- fleet management ("what should this be running?")
- predictable support ("we can reproduce your image")

## Contract: Storage (DATA NVMe)

### Rule

- The DATA drive is ext4 with filesystem label `OURBOX_DATA`
- It mounts at `/var/lib/ourbox`
- Either physical NVMe may serve as DATA on a given install; the role is
  determined by the label, not by a permanently reserved slot

### Implementation

`/etc/fstab` includes a label-based mount, typically:

```fstab
LABEL=OURBOX_DATA /var/lib/ourbox ext4 defaults,noatime,nofail,x-systemd.device-timeout=10 0 2
```

Key properties:

- uses LABEL rather than a fixed device path, so device enumeration changes do
  not break the mount
- uses `nofail` so the system can boot without the data disk
- uses a short systemd timeout to avoid slow boots

### Intended contents of `/var/lib/ourbox`

This is where higher-level stacks should store persistent state:

- k3s storage and persistent volumes
- application state
- logs, if desired

Exact directory layout is owned by the platform layer, not this repo.

## Contract: SSD hygiene

- `fstrim.timer` is enabled so periodic TRIM runs automatically

Verify:

```bash
systemctl status fstrim.timer --no-pager
```

## Non-contracts (explicitly not guaranteed)

- No guarantee that Wi-Fi is configured on first boot
- `k3s` is part of the OS image as the platform runtime, but application
  manifests live in the consumed upstream platform payload
- The OS includes `ourbox-bootstrap.service`, which brings up `k3s` and applies
  the shipped platform payload
- If `k3s` cannot start because the kernel lacks the memory cgroup controller,
  the remedy is the cmdline flags documented in [`docs/OPS.md`](../OPS.md)
- No guarantee that the DATA disk is formatted automatically; the installer
  expects to manage that role explicitly

## Contract: Installer media contract

Installer media contains the Matchbox runtime installer plus a host-composed
local mission.

- Entrypoint: `/opt/ourbox/tools/ourbox-install`
- Shared installer SSH policy helper:
  `/opt/ourbox/tools/installer-ssh-helper.sh`
- Installer identity defaults: `/opt/ourbox/installer/defaults.env`
- Embedded mission root: `/opt/ourbox/mission`
- Embedded mission manifest: `/opt/ourbox/mission/mission-manifest.json`
- Embedded mission artifacts include:
  - staged Matchbox OS payload bytes
  - staged Matchbox OS metadata
  - staged selected `ourbox-substrate` bundle tarball
  - staged selected `ourbox-substrate` manifest
  - optional staged installed-target SSH public key material when the host
    composer supports that target
- The target installer does not ship
  `/opt/ourbox/tools/installer-selection-resolver.sh`.
- The target installer does not fetch remote install-defaults, browse catalogs,
  resolve tags, log into registries, or pull artifacts with ORAS.
- After flashing, installer-selected payload provenance is appended directly to
  `/etc/ourbox/release` on the installed root filesystem.
- Installer SSH policy is baked at image-build time and realized through the
  upstream installer SSH helper contract.
- Official/public Matchbox media uses `OURBOX_INSTALLER_SSH_MODE=off`.
- SSH-enabled support or lab media is explicit opt-in only and must provide
  build-time auth material.

## Contract: Platform runtime (`k3s`)

- `k3s` binary exists at `/usr/local/bin/k3s`
- `k3s.service` exists and is enabled by bootstrap, or enabled directly
- `ourbox-bootstrap.service` exists and runs at boot
- bootstrap skips reapply only when the stored applied platform state still
  matches the shipped platform payload
- success marker: `/var/lib/ourbox/state/bootstrap.done`
- `k3s` data lives under `/var/lib/ourbox/k3s`

## Contract: Kernel cmdline must enable cgroup memory

If `/sys/fs/cgroup/cgroup.controllers` does not include `memory`, `k3s` will
fail with `failed to find memory cgroup (v2)`.

Fix: add `cgroup_enable=cpuset cgroup_enable=memory cgroup_memory=1` to
`/boot/firmware/cmdline.txt`. See [`docs/OPS.md`](../OPS.md) for the full
procedure.

Long-term intent: bake this into the image during build.

## Related ADRs

- ADR-0002: Storage contract (mount data by label)
- ADR-0003: OS artifact distribution via OCI registry
- ADR-0004: Consume platform inputs from `sw-ourbox-os`
