# OurBox Matchbox OS — Operator Runbook (Zero → Boot)

**Last verified:** 2026-02-27 (re-verify after substrate bundle migration)  
**Verified on:** Pi 5 + dual NVMe (DATA label `OURBOX_DATA`, SYSTEM flashed to other NVMe)  
**Outcome:** k3s + hello workload running, nginx reachable on `127.0.0.1:30080`

This is the only step-by-step doc. If reality and this file disagree, update this file.

---

## Opinionated defaults (repeatable, no guessing)

- Container runtime: **Podman (rootful)**
- Build tooling: **BuildKit installed on host**
- Platform input intent: **approved in `sw-ourbox-os/release/approved-upstream-inputs.json`** and pinned in this repo by `tools/approved-upstream-inputs.upstream.env`; official candidate workflows resolve exact refs at start
- Host tooling pins: **pinned** in `tools/versions.env` (BuildKit/ORAS)
- Disk safety: **exactly two NVMe disks required**
  - DATA: whichever NVMe disk this install assigns the ext4 label `OURBOX_DATA`
  - SYSTEM: the other NVMe disk (will be wiped)

No copy/paste IDs. No “pick your own runtime”. No “latest”.

---

## Build preflight

All build entry points now run `tools/preflight-build-host.sh` automatically before invoking pi-gen (`tools/build-image.sh`, `tools/build-installer-image.sh`, and `tools/ops-e2e.sh`).

Build scripts automatically sanitize stale `(lost|deleted)` loop devices before and after pi-gen runs to prevent export-image failures.

If preflight fails, required action is: **reboot the build host**.

Why this exists: pi-gen `export-image` loop creation can fail in containers when loop state is unhealthy (`(lost)`/`(deleted)` loops and missing loop nodes in container `/dev`). Preflight forces this to fail-fast in seconds instead of after hours of build time.

---

## Desktop → Installer Media → Pi NVMe Install

Desktop command:

```bash
./tools/prepare-installer-media.sh
```

The script is interactive and defaults to pulling a published installer artifact
from registry, verifying checksum, composing a local mission, and then flashing
selected removable/USB media.

This wrapper now delegates to `sw-ourbox-installer --target matchbox`.
The host chooses the OS payload and the arm64 application bundle up front, stages
them into mission media, and the target installer consumes only those embedded
local bytes.

Pi boot steps:

1. Insert installer SD/USB media into the Pi.
2. Boot the Pi from that media.
3. Follow the installer prompts on tty1 (disk safety checks + confirmations + user provisioning).
4. Wait for automatic power-off, remove installer media, then boot from NVMe.

Good looks like verification after NVMe boot remains the same as below in **First boot verification (what “good” looks like)**.

---

## What you need (any Linux, including the Pi)

- Booted Linux system with sudo access
- Internet access for first run (pulls OCI artifacts from GHCR)
- Disk space for build output (recommend at least 60 GB free)
- Raspberry Pi workflow requirement:
  - you must be booted from SD or USB when flashing (root filesystem must not be NVMe)

---

## The happy path (copy/paste works)

1) Clone the repo (with submodules):

```bash
git clone --recurse-submodules https://github.com/techofourown/img-ourbox-matchbox.git
cd img-ourbox-matchbox
```

2. Compose and flash Matchbox mission media:

```bash
./tools/prepare-installer-media.sh
```

That flow will:

* call the unified host-side composer in `sw-ourbox-installer`
* select the Matchbox OS payload on the host
* select the Matchbox application bundle on the host
* embed the staged mission into the published Matchbox installer substrate
* flash the composed mission media to removable USB media
* hand off to the Matchbox target installer for disk planning, identity, and final confirmation

When it finishes, power down, remove SD (or fix boot order), and boot from the NVMe SYSTEM disk.

---

## First boot verification (what “good” looks like)

### 1) Storage mounts

```bash
findmnt /
findmnt /var/lib/ourbox || true
```

Expected:

* `/` is `nvme...p2`
* `/var/lib/ourbox` is the DATA disk (`LABEL=OURBOX_DATA`)

### 2) Bootstrap + k3s

```bash
systemctl status ourbox-bootstrap --no-pager || true
systemctl status k3s --no-pager || true

sudo /usr/local/bin/k3s kubectl get nodes
sudo /usr/local/bin/k3s kubectl get pods -A
```

### 3) Demo service reachable

```bash
curl -sSf http://127.0.0.1:30080 | head
```

### 4) Bootstrap completion marker

```bash
sudo cat /var/lib/ourbox/state/bootstrap.done 2>/dev/null || true
```

---

## Platform input provenance (what baseline did this image ship?)

This image repo is responsible for boot plus bootstrap, but the upstream
platform payload comes from `sw-ourbox-os`.

When debugging a device, the first question is:

> "What exact substrate and platform payload did this image ship?"

Check:

```bash
sudo cat /etc/ourbox/release
```

Look first for the `OURBOX_SUBSTRATE_*` keys:
- `OURBOX_SUBSTRATE_REF`
- `OURBOX_SUBSTRATE_DIGEST`
- `OURBOX_SUBSTRATE_SOURCE`
- `OURBOX_SUBSTRATE_REVISION`
- `OURBOX_SUBSTRATE_ARCH`
- `OURBOX_SUBSTRATE_PROFILE`
- `OURBOX_SUBSTRATE_K3S_VERSION`

Older builds may still carry `OURBOX_PLATFORM_CONTRACT_*` fields. Treat those as
informational trace only, not as compatibility gates.

This is the provenance boundary that keeps the official baseline legible even
before signatures or attestations exist.

---

## OCI distribution of the OS image (transport + installer input)

OS payloads are published as ORAS artifacts (non-runnable) with files:
`os.img.xz`, `os.img.xz.sha256`, `os.meta.env`, optional `os.info`.
`build.log` is not published unless `OS_INCLUDE_BUILD_LOG=1` is set.

Channel tags (moving): `${OURBOX_TARGET}-stable` by default, plus any you set in
`OS_CHANNEL_TAGS`. Immutable tag defaults to the build basename.

Publish:

```bash
# Push latest built payload from deploy/ to OS_REPO (default ghcr.io/techofourown/ourbox-matchbox-os)
./tools/publish-os-artifact.sh deploy
```

This writes:
- `deploy/os-artifact.ref` (immutable tag ref)
- `deploy/os-artifact.pinned.ref` (digest-pinned immutable ref)
- `deploy/os-artifact.digest` (artifact digest only)

Pull/verify:

```bash
rm -rf ./deploy-from-registry
./tools/pull-os-artifact.sh --latest ./deploy-from-registry
xz -t ./deploy-from-registry/os.img.xz
```

Catalog:
- Channel tags are appended to a TSV catalog `${OURBOX_TARGET}-catalog` so installers can list builds
  without downloading full images.

Installer substrate:
- The published Matchbox installer artifact is substrate only.
- It carries the Matchbox runtime installer plus `/opt/ourbox/installer/defaults.env`.
- Mission composition happens later on the host through `sw-ourbox-installer`.
- The target installer does not fetch OS payloads or browse catalogs at runtime.

---

## OCI distribution of installer media (transport + operator flash input)

Installer media artifacts are published as ORAS artifacts (non-runnable) with files:
`installer.img.xz`, `installer.img.xz.sha256`, `installer.meta.env`, optional `installer.info`.
`build-installer.log` is not published unless `INSTALLER_INCLUDE_BUILD_LOG=1` is set.

Channel tags (moving): `${OURBOX_TARGET}-installer-stable` by default, plus any you set in
`INSTALLER_CHANNEL_TAGS`. Immutable tag defaults to the build basename.

Publish:

```bash
# Push latest built installer artifact from deploy/ to INSTALLER_REPO
# (default ghcr.io/techofourown/ourbox-matchbox-installer)
./tools/publish-installer-artifact.sh deploy
```

This writes:
- `deploy/installer-artifact.ref` (immutable tag ref)
- `deploy/installer-artifact.pinned.ref` (digest-pinned immutable ref)
- `deploy/installer-artifact.digest` (artifact digest only)

Pull/verify:

```bash
rm -rf ./deploy-installer-from-registry
./tools/pull-installer-artifact.sh --channel stable --outdir ./deploy-installer-from-registry
xz -t ./deploy-installer-from-registry/installer.img.xz
```

`./tools/prepare-installer-media.sh` uses this published installer substrate as the
base image and then embeds the selected mission on the host.

---

## Troubleshooting

### Podman missing / container commands fail

Re-run bootstrap:

```bash
./tools/bootstrap-host.sh
```

### k3s fails with “failed to find memory cgroup (v2)”

Symptom:

* `systemctl status k3s` shows crash loop
* journal shows: `fatal ... failed to find memory cgroup (v2)`

Fix (on the Pi):

```bash
sudo systemctl stop ourbox-bootstrap.service || true
sudo systemctl stop k3s.service || true
sudo systemctl disable k3s.service || true

sudo cp -a /boot/firmware/cmdline.txt /boot/firmware/cmdline.txt.bak
sudo sed -i '1 s/$/ cgroup_enable=cpuset cgroup_enable=memory cgroup_memory=1/' /boot/firmware/cmdline.txt
cat /boot/firmware/cmdline.txt

sudo reboot
```

Verify after reboot:

```bash
stat -fc %T /sys/fs/cgroup
cat /sys/fs/cgroup/cgroup.controllers
```

You should see `cgroup2fs` and `memory` present in controllers.

Then:

```bash
sudo systemctl start ourbox-bootstrap.service
sudo systemctl status k3s --no-pager
```

### Wi‑Fi blocked by rfkill

```bash
sudo raspi-config
# Localisation Options -> WLAN Country
```

### Registry TLS / unknown CA

Skip registry and flash locally (the end-to-end script does not require registry).
