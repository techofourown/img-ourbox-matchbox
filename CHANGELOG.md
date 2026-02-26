# [0.4.0](https://github.com/techofourown/img-ourbox-matchbox/compare/v0.3.6...v0.4.0) (2026-02-15)


### Features

* **platform:** add apps, Traefik ingress, and mDNS with safe networking ([2f1e8d1](https://github.com/techofourown/img-ourbox-matchbox/commit/2f1e8d19d4895832e968081e7c9127878fb74b24))
* **status:** add boot-time status reporter and matchbox CLI ([687568e](https://github.com/techofourown/img-ourbox-matchbox/commit/687568e627c368b0bcea44aae5705c77f9b8ec44))

# [0.4.0](https://github.com/techofourown/img-ourbox-matchbox/compare/v0.3.6...v0.4.0) (2026-02-15)


### Features

* **platform:** add apps, Traefik ingress, and mDNS with safe networking ([2f1e8d1](https://github.com/techofourown/img-ourbox-matchbox/commit/2f1e8d19d4895832e968081e7c9127878fb74b24))

## [0.3.6](https://github.com/techofourown/img-ourbox-matchbox/compare/v0.3.5...v0.3.6) (2026-02-13)


### Bug Fixes

* **installer:** wait for exactly 2 NVMe disks before proceeding ([8c1ae5e](https://github.com/techofourown/img-ourbox-matchbox/commit/8c1ae5e4e2a559c0d53773c40e592ff0a43dc1d8))

## [0.3.5](https://github.com/techofourown/img-ourbox-matchbox/compare/v0.3.4...v0.3.5) (2026-02-13)


### Bug Fixes

* **installer:** skip first-boot wizard and improve boot reliability ([4cfeda2](https://github.com/techofourown/img-ourbox-matchbox/commit/4cfeda268b117f004ed02f4edbe8e2f79491dca4))

## [0.3.4](https://github.com/techofourown/img-ourbox-matchbox/compare/v0.3.3...v0.3.4) (2026-02-12)


### Bug Fixes

* **installer:** make artifact naming deterministic and glob patterns robust ([a6a919b](https://github.com/techofourown/img-ourbox-matchbox/commit/a6a919b6d7e9ca46547769c2693489249b0aabd3))

## [0.3.3](https://github.com/techofourown/img-ourbox-matchbox/compare/v0.3.2...v0.3.3) (2026-02-12)


### Bug Fixes

* **installer:** seed rootfs from previous stage via copy_previous ([2b05889](https://github.com/techofourown/img-ourbox-matchbox/commit/2b05889249fe368358c8d60e09fe4c74cc1207af))

## [0.3.2](https://github.com/techofourown/img-ourbox-matchbox/compare/v0.3.1...v0.3.2) (2026-02-12)


### Bug Fixes

* **installer:** ensure ROOTFS_DIR exists before copying files ([0b873a9](https://github.com/techofourown/img-ourbox-matchbox/commit/0b873a9960a1e9096ff1b5a8fd7f177895998441))

## [0.3.1](https://github.com/techofourown/img-ourbox-matchbox/compare/v0.3.0...v0.3.1) (2026-02-12)


### Bug Fixes

* **submodule:** revert to upstream RPi-Distro/pi-gen ([dd05c88](https://github.com/techofourown/img-ourbox-matchbox/commit/dd05c886094f38172edd2de527ab1311d58b1192))

# [0.3.0](https://github.com/techofourown/img-ourbox-matchbox/compare/v0.2.2...v0.3.0) (2026-02-12)


### Features

* **fetch:** offer interactive cleanup of existing artifacts ([b990606](https://github.com/techofourown/img-ourbox-matchbox/commit/b99060638759517ba8a26fc03b6544a332e54ee2))

## [0.2.2](https://github.com/techofourown/img-ourbox-matchbox/compare/v0.2.1...v0.2.2) (2026-02-12)


### Bug Fixes

* **fetch:** fail fast when artifacts already exist instead of failing during curl ([2d4558f](https://github.com/techofourown/img-ourbox-matchbox/commit/2d4558f53f23d16e54ae46f79d7d514dc809b23c))

## [0.2.1](https://github.com/techofourown/img-ourbox-matchbox/compare/v0.2.0...v0.2.1) (2026-02-12)


### Bug Fixes

* **build:** sanitize loop devices to prevent pi-gen export-image failures ([21ebd9d](https://github.com/techofourown/img-ourbox-matchbox/commit/21ebd9d92ddea4f341abe132ece6cb465865c193))

# [0.2.0](https://github.com/techofourown/img-ourbox-matchbox/compare/v0.1.5...v0.2.0) (2026-02-11)


### Features

* **installer-media:** require interactive USB target selection ([01fe9fc](https://github.com/techofourown/img-ourbox-matchbox/commit/01fe9fc9b3bc31bd5b8a0ab8af975279f9baff0b))

## [0.1.5](https://github.com/techofourown/img-ourbox-matchbox/compare/v0.1.4...v0.1.5) (2026-02-11)


### Bug Fixes

* **ops-e2e:** stop rejecting OS images containing installer substring ([886086c](https://github.com/techofourown/img-ourbox-matchbox/commit/886086c21648638ac2b06f372c9617efa1406f2b))

## [0.1.4](https://github.com/techofourown/img-ourbox-matchbox/compare/v0.1.3...v0.1.4) (2026-01-31)


### Bug Fixes

* fail fast when NVMe in use ([4733b0c](https://github.com/techofourown/img-ourbox-matchbox/commit/4733b0c75d906ec8b723699f93273a2a2c4c693a))

## [0.1.3](https://github.com/techofourown/img-ourbox-mini-rpi/compare/v0.1.2...v0.1.3) (2026-01-29)


### Bug Fixes

* gate DATA state before flashing ([c51293c](https://github.com/techofourown/img-ourbox-mini-rpi/commit/c51293ccead5728788b9a763361ecdb51d287d46))

## [0.1.2](https://github.com/techofourown/img-ourbox-mini-rpi/compare/v0.1.1...v0.1.2) (2026-01-28)


### Bug Fixes

* ensure deploy dir writable ([9eeb90e](https://github.com/techofourown/img-ourbox-mini-rpi/commit/9eeb90e0ecb74d0bc20aee60e7acabd366397586))

## [0.1.1](https://github.com/techofourown/img-ourbox-mini-rpi/compare/v0.1.0...v0.1.1) (2026-01-28)


### Bug Fixes

* load nginx tar name from manifest ([90fd933](https://github.com/techofourown/img-ourbox-mini-rpi/commit/90fd9337a031ca047eb7e1de2a1abf8b8aafd64f))

# [0.1.0](https://github.com/techofourown/img-ourbox-mini-rpi/compare/v0.0.0...v0.1.0) (2026-01-26)


### Features

* add operational tooling and kernel cgroups support ([3fc5fc4](https://github.com/techofourown/img-ourbox-mini-rpi/commit/3fc5fc402daa9de4640620b2e1c1183e2e4d47e8))
