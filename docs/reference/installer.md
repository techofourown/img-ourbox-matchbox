# Matchbox installer runtime

Matchbox no longer performs target-time payload selection.

The published Matchbox installer artifact is substrate only. The actual install
media is composed later on the host by `sw-ourbox-installer`, which embeds a
fully selected local mission into that substrate before flashing removable
media.

## Runtime inputs

- Installer identity defaults: `/opt/ourbox/installer/defaults.env`
- Embedded mission root: `/opt/ourbox/mission`
- Embedded mission manifest: `/opt/ourbox/mission/mission-manifest.json`

`defaults.env` is rendered at installer image build time. It now carries only:

- `INSTALLER_ID`
- `INSTALLER_VERSION`
- `INSTALLER_GIT_HASH`
- `OURBOX_INSTALLER_SSH_TEARDOWN_ON_COMPLETE`

The mission manifest and the staged mission artifacts under `/opt/ourbox/mission`
are the authoritative source for:

- which Matchbox OS payload will be installed
- which selected `ourbox-substrate` bundle and staged mission bytes will be
  applied into the installed rootfs

There is no runtime boot-media override for payload selection.

## Runtime behavior

- Shared installer SSH policy is sourced from `/opt/ourbox/tools/installer-ssh-helper.sh`, the
  upstream reference helper and contract defined in `sw-ourbox-os`.
- Installer logs its operator-visible flow to `/run/ourbox-installer.log` in addition to `tty1`,
  so support media can inspect the same transcript over SSH.
- Installer validates the embedded mission locally before any destructive work:
  - mission manifest shape and target id
  - staged OS payload bytes and checksum
  - staged OS metadata shape
  - staged selected-substrate tarball shape and checksum
  - staged selected-substrate manifest shape, pinned ref, digest, and arch
- Matchbox now follows a four-step installer flow:
  1. load and verify the local mission
  2. review the SYSTEM/DATA storage plan
  3. set first-boot identity
  4. review a final summary and type `INSTALL`
- Installer shows both NVMe disks in a numbered menu and requires an explicit SYSTEM-disk
  confirmation before continuing; the other NVMe becomes DATA for that install.
- If the chosen SYSTEM disk currently carries `LABEL=OURBOX_DATA`, installer warns that the label
  will be cleared as part of the later SYSTEM wipe.
- If the chosen DATA disk already contains OurBox state, installer offers `RESET-BOOTSTRAP`,
  `ERASE-DATA`, or `KEEP-DATA` during planning and applies the chosen action only after the final
  `INSTALL` confirmation.
- `KEEP-DATA` preserves existing DATA contents; bootstrap re-runs automatically on next boot only
  when the shipped platform state changed.
- Matchbox no longer requires the operator to type the raw SYSTEM disk path or `FLASH`;
  destructive work starts only after the final `INSTALL` confirmation step.
- After flashing, the installer writes `userconf.txt`, overlays the staged application bundle into
  the installed rootfs, appends provenance to `/etc/ourbox/release`, and powers off.
- The target installer does not read `/boot/firmware/ourbox-installer.env` for payload-selection
  or installer-policy overrides.

## Explicitly removed from Matchbox runtime

The Matchbox installer no longer ships or performs any of the following:

- `/opt/ourbox/tools/installer-selection-resolver.sh`
- target-time remote `install-defaults`
- target-time OS catalog browsing
- target-time application-bundle catalog browsing
- target-time registry login
- target-time `oras resolve` or `oras pull`
- boot-media payload-selection overrides via `/boot/firmware/ourbox-installer.env`

## Installer SSH policy
- Shared installer SSH semantics come from the upstream `sw-ourbox-os` installer SSH contract and
  the vendored helper at `/opt/ourbox/tools/installer-ssh-helper.sh`.
- Matchbox keeps installer SSH policy at image-build time. The target installer does not accept a
  runtime override file for `OURBOX_INSTALLER_SSH_*` knobs.
- Official/public Matchbox media currently ships with `OURBOX_INSTALLER_SSH_MODE=off`, meaning the
  shared contract exposes no usable installer SSH login path.
- SSH-enabled Matchbox support or lab media is explicit opt-in only. `key` mode requires explicit
  `OURBOX_INSTALLER_SSH_AUTHORIZED_KEYS`, `password` mode requires explicit
  `OURBOX_INSTALLER_SSH_PASSWORD_HASH`, and `both` requires at least one usable auth input.
- Matchbox does not currently support local runtime password generation for installer SSH.
  `OURBOX_INSTALLER_SSH_GENERATE_PASSWORD_IF_EMPTY` stays `0`.

## Official builds
- Official Matchbox workflows now publish the Matchbox OS artifact and the Matchbox installer
  substrate independently.
- Official/public Matchbox installer artifacts do not bake OS-selection defaults or remote
  install-defaults behavior into the runtime image.
- Official/public installers also set the full installer SSH posture explicitly in workflow code and
  currently use `OURBOX_INSTALLER_SSH_MODE=off`.
- Push-to-`main` official candidate builds resolve exact upstream refs from the
  approved snapshot pinned by `tools/approved-upstream-inputs.upstream.env`
  and publish the `beta` lane.
- Stable builds are a promotion of that already-published candidate digest once both candidate success and a matching published GitHub Release are present; they are not rebuilt on release.
- Scheduled nightly integration builds resolve the latest `sw-ourbox-os` `edge` platform bundle digests at workflow time and publish the `nightly` lane.
- GitHub prereleases authorize promotion of the same candidate digest into `exp-labs`, and either the candidate or the prerelease event may wake that promotion after the other condition already exists.
- Promotion is driven by `candidate-provenance.json`; it does not use artifact-carried `.env` sidecars as promotion control-plane inputs.

Host-composed Matchbox mission media is built later by `sw-ourbox-installer`, which:

- chooses the target
- resolves the exact Matchbox OS artifact on the host
- resolves the exact selected substrate and mission payload on the host
- stages the mission manifest and mission artifacts
- embeds that mission into the published Matchbox installer substrate
