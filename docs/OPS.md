# OurBox Matchbox OS — Operator Runbook (Zero → Boot)

**Last verified:** 2026-01-26  
**Verified on:** Pi 5 + dual NVMe (DATA label `OURBOX_DATA`, SYSTEM flashed to other NVMe)  
**Outcome:** k3s + hello workload running, nginx reachable on `127.0.0.1:30080`

This is the only step-by-step doc. If reality and this file disagree, update this file.

---

## Opinionated defaults (repeatable, no guessing)

- Container runtime: **Podman (rootful)**
- Build tooling: **BuildKit installed on host**
- Versions: **pinned** in `tools/versions.env` (including K3s)
- Disk safety: **exactly two NVMe disks required**
  - DATA: ext4 filesystem label `OURBOX_DATA` (must never be wiped)
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

The script is interactive and will list removable/USB disks, show mount state,
and require you to choose a target disk during the session.

Pi boot steps:

1. Insert installer SD/USB media into the Pi.
2. Boot the Pi from that media.
3. Follow the installer prompts on tty1 (disk safety checks + confirmations + user provisioning).
4. Wait for automatic power-off, remove installer media, then boot from NVMe.

Good looks like verification after NVMe boot remains the same as below in **First boot verification (what “good” looks like)**.

---

## What you need (any Linux, including the Pi)

- Booted Linux system with sudo access
- Internet access for first run (downloads k3s + container image)
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

2. Run the end-to-end operator script:

```bash
./tools/ops-e2e.sh
```

That script will:

* install Podman + BuildKit + required host tools (idempotent)
* enforce pinned versions from `tools/versions.env` (no “latest”)
* fetch the airgap artifacts (including the pinned platform contract)
* build the OS image
* scan for NVMe disks and refuse to proceed unless there are exactly two
* protect the DATA disk (label `OURBOX_DATA`) and pick the other NVMe as SYSTEM
* if DATA already has OurBox state, force you to choose: RESET-BOOTSTRAP / ERASE-DATA / KEEP-DATA before flashing SYSTEM
* require multiple explicit confirmations before wiping SYSTEM
* wipe SYSTEM disk signatures (works even if already partitioned), then flash the OS image to the raw NVMe disk
* prompt you for username and password (writes `userconf.txt` to the boot partition)

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

## Platform contract provenance (what baseline did this image ship?)

This image repo is responsible for "boot + bootstrap," but the *platform contract* (baseline
manifests / platform components contract) is sourced from `sw-ourbox-os`.

When debugging a device, the first question is:

> "What platform contract revision/digest am I running?"

Check:

```bash
sudo cat /etc/ourbox/release
```

Look for the `OURBOX_PLATFORM_CONTRACT_*` keys:
- `OURBOX_PLATFORM_CONTRACT_SOURCE`
- `OURBOX_PLATFORM_CONTRACT_REVISION`
- (when available) `OURBOX_PLATFORM_CONTRACT_VERSION`
- (when available) `OURBOX_PLATFORM_CONTRACT_DIGEST`

This is the provenance boundary that keeps "official baseline" legible even before we enforce
signatures.

---

## OCI distribution of the OS image (optional, transport only)

Publishing the flashable OS image into a registry is optional (per ADR-0003). This is *transport*
for the OS image bytes — it is not the source of truth for the platform contract.

If you publish/pull via OCI, prefer digest identity for repeatability (tags are convenience).

To publish:

```bash
./tools/publish-os-artifact.sh deploy
```

That writes the image reference into `deploy/os-artifact.ref`.

To pull it back out (round-trip validation):

```bash
rm -rf ./deploy-from-registry
./tools/pull-os-artifact.sh --latest ./deploy-from-registry
xz -t ./deploy-from-registry/os.img.xz
```

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
