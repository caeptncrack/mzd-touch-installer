# Notices and attributions

## This repository

MZD Touch Installer
Copyright (C) 2026 caeptncrack

The scripts in this repository (`stick/`, `tools/`, `tests/`) are free
software: you can redistribute them and/or modify them under the terms of
the GNU General Public License as published by the Free Software Foundation,
either version 3 of the License, or (at your option) any later version.
See [LICENSE](LICENSE).

## Included third-party software (on the built stick, unmodified)

### oem-aa-mod 0.10.0 — folder `aa-mod/` on the stick

* Author:  VitaliyKurokhtin
* Project: <https://github.com/VitaliyKurokhtin/oem-aa-mod>
* Release: <https://github.com/VitaliyKurokhtin/oem-aa-mod/releases/tag/0.10.0>
* Source of this release: <https://github.com/VitaliyKurokhtin/oem-aa-mod/tree/0.10.0>
* License: GNU Affero General Public License v3.0; the upstream `LICENSE`
  and `NOTICE.md` of tag 0.10.0 are copied next to the files on the stick.
  oem-aa-mod itself credits headunit by Trevelopment / Bryan Adams et al.
  (AGPL-3.0).

The three `libpatch-*.so` files, `libpatch.conf` and both
`aap_system_attributes*.xml` files are taken byte for byte from
`oem-aa-mod-0.10.0.zip` (SHA-256
`ba7a0c285269a87e8a199e38517de05da749a67df7ca016abb6d15e65112dc6a`).
This repository does not contain them; `tools/build_stick.py` downloads
them from the upstream release. The shims and `libpatch.conf` are installed
as they are. The two XML files are verified on the stick but not installed:
the installer adds their touch, media-pause and navigation entries to the
car's own XML files and leaves the rest of those files unchanged (see
README, "The Android Auto XML").

### TouchTune 1.2.1 — folder `touchtune/` on the stick

* Author:  Miatafy
* Project: <https://github.com/Miatafy/TouchTune>
* Release: <https://github.com/Miatafy/TouchTune/releases/tag/v1.2.1>
* License: GNU General Public License v3.0. TouchTune builds on MZD-AIO-TI by
  Trevor G Martin, Copyright (C) 2017 Trevelopment
  (<https://github.com/Trevelopment/MZD-AIO>, GPL-3.0-or-later). Its
  `LICENSE`, `NOTICE` and `SOURCE.txt` stay in `touchtune/`.

All 13 release files are copied byte for byte from `TouchTune-1.2.1.zip`
(SHA-256 `3397a541aacebb1c0a4476c12eeb3479a643990ba67521745c7de47ad072dc68`)
and checked against TouchTune's own manifest. TouchTune is only ever started
as its own process; its scripts are not changed or sourced.

## Not included

No Mazda software, firmware file or configuration file is part of this
repository or of the built stick. The installer backs up the files it changes
on the car itself and restores them from there.

## Trademarks

Mazda and Mazda Connect are trademarks of Mazda Motor Corporation. Android
Auto is a trademark of Google LLC. This project is not affiliated with or
endorsed by Mazda, Google, or the authors of oem-aa-mod or TouchTune.
