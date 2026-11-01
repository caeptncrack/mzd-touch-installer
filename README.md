# MZD Touch Installer

**Android Auto touch + touch while driving for Mazda Connect 74.00.324 / 74.00.324A, installed and removed with one USB stick.**

[Deutsch](README.de.md)

| | |
|---|---|
| Tested in a car | Mazda Connect **74.00.324A** (EU, `cmu150_EU`) |
| Should work on | every region of 74.00.324 / 74.00.324A (for example North America). The installer tells you when your unit differs from the tested build and asks before it changes anything. Reports are welcome. |
| Needs | a USB stick (FAT32) and nothing else: no computer in the car, no original Mazda files |

This project packages two community projects; their files are included **unmodified**:

| Part | Project | Author | License |
|---|---|---|---|
| Touch in Android Auto | [oem-aa-mod](https://github.com/VitaliyKurokhtin/oem-aa-mod) 0.10.0 | [VitaliyKurokhtin](https://github.com/VitaliyKurokhtin) | AGPL-3.0 |
| Touch while driving (Mazda Connect menus) | [TouchTune](https://github.com/Miatafy/TouchTune) 1.2.1 | [Miatafy](https://github.com/Miatafy) | GPL-3.0 |

All credit for what these two do goes to their authors. Please star and support the originals. This repository adds:

- one stick and one dialog for both parts (install, remove, diagnosis)
- oem-aa-mod's touch entries are added to **your car's own** Android Auto XML files instead of replacing them, so the video settings Android Auto gets (and with them the picture scaling) stay as shipped; see [The Android Auto XML](#the-android-auto-xml)
- a backup of your original files **on the car** before the first change; removal restores exactly those files, so no Mazda file has to come from the internet or from the stick
- safety around every write: verified payload, staged files, XML validation, atomic rename, read-back, automatic rollback, and a single Mazda SafeReboot at the end
- a shareable diagnosis file for bug reports

## What you get

**Android Auto touch** (oem-aa-mod, its release configuration as published):

- touch input in Android Auto on the Mazda Connect screen
- turn-by-turn guidance from Android Auto on the head-up display, where fitted
- mute pauses the phone's media and unmute resumes it
- Mazda Connect no longer starts Android Auto media by itself (start playback from Android Auto or the phone)
- Android Auto protocol 1.6 towards the phone (needed for the head-up display guidance)
- the Android Auto picture keeps the car's own video settings (see below)

See the [oem-aa-mod README](https://github.com/VitaliyKurokhtin/oem-aa-mod) for details of each option.

**Touch while driving** (TouchTune): the Mazda Connect touch screen keeps working while the car is moving (by default Mazda locks it once the car moves).

> **Safety and law.** Touching a screen while driving distracts you. Use it only when it is safe and allowed where you drive (in Germany, for example, § 23 (1a) StVO restricts operating devices while driving). You stay responsible. A passenger is the best user of this feature.

## Use

1. **Download.** Open the [latest release](../../releases/latest) and download **`mzd-touch-installer-<version>.zip`** under *Assets*. Not "Source code": that is the program text for developers. Nothing has to be installed or built on your computer.
2. **Prepare the stick.** Use an empty USB stick of up to 32 GB, formatted as **FAT32** (Windows: right-click the stick → *Format…* → *FAT32*).
   - **Windows:** right-click the ZIP → *Extract All…* → *Browse…* → choose the stick → *Extract*. Or extract it anywhere, open the folder, select everything inside (Ctrl+A) and drag it onto the stick. Eject the stick before you pull it.
   - **macOS:** double-click the ZIP, open the new folder, select everything inside (Cmd+A) and drag it onto the stick. Then open *Terminal* and run `dot_clean -m /Volumes/<STICK>` (Finder adds hidden `._` files that can stop the car from starting the stick). Eject the stick.
   - **Check:** when you open the stick you see `run.sh`, `README.txt`, `STICK.ID` and the folders `aa-mod`, `lib`, `payload` and `touchtune` directly, not inside another folder. Nothing else is on the stick.
3. **In the car.** Engine running is safest (the unit must not lose power while it writes). Wait until Mazda Connect has fully started. Plug the stick into a USB port in the centre console. After a few seconds a dialog shows the current state:

   | State | Buttons |
   |---|---|
   | nothing installed | **Install** · Diagnosis · Cancel |
   | both installed | **Remove both** · Diagnosis · Cancel |
   | one of them installed | **Install** · Remove · Cancel |

4. Choose **Install**. A confirmation opens and says in a few lines what will happen; tap **Start** (**Back** returns to the start dialog). Every button of the start dialog asks like this first.
5. While it works the screen says *Do not pull the stick*. Pull the stick only when the screen tells you to: *Remove the USB* before the restart, or *You can pull the stick now* when a run ends without one. Mazda Connect restarts by itself (or asks *Restart now*).
6. After the restart: connect Android Auto and tap on the screen.

If your unit is not the tested EU build, the installer says so ("differs from the build this installer was tested on") and asks before it continues. **Cancel** changes nothing.

## Remove

Plug the same stick in again, choose **Remove both** and confirm with **Start**. Android Auto touch is restored from the backup taken on your car, byte for byte; TouchTune restores its own backup. Mazda Connect restarts at the end. You do not need any original Mazda files.

After an official Mazda software update the changes are gone, but the shims in `/data_persist` stay. Run the stick again: it notices the update, takes a new backup and installs again.

## The Android Auto XML

oem-aa-mod ships its own copies of `/etc/aap_system_attributes.xml` and `aap_system_attributes_UCP.xml`. Besides the touch entries they also move a few video values into the block that `aap_service` sends to the phone (`par`, `fps`, `decoder_additional_depth`) and add `real_density`. In the factory file these values sit where `aap_service` does not read them, so with the replacement file the phone gets different video parameters, and Android Auto can be scaled differently than from the factory.

This installer therefore keeps your car's own two files and adds only what oem-aa-mod adds for its features:

- a `<touch_screen>` entry at the start of `<input_devices>` (`use_internally` true in the main file, false in `_UCP`, as in oem-aa-mod)
- the key `AAP_KEYCODE_MEDIA_PAUSE` (mute pauses the phone)
- navigation `subscribe TRUE` plus `<cluster_type>ENUM</cluster_type>` (head-up display guidance)

Every other line stays byte for byte as shipped, including `<display>` and `<video>`. The installer checks this before it writes: taking the added lines out again must give your original file exactly. If your file does not have the expected layout, Android Auto touch is not installed and TouchTune is offered alone. On the tested EU build the result equals oem-aa-mod's file apart from the video block. oem-aa-mod's two XML files stay on the stick, verified but not installed.

## What the installer checks before it changes anything

- every file on the stick against `PAYLOAD.SHA256` (a damaged or modified stick is refused)
- the firmware version (74.00.324 or 74.00.324A, any region; anything else is refused and a diagnosis file is written)
- that the target components exist and whether they equal the tested build (if not, you are asked)
- that no other installer modified Android Auto (`.orig` files, other `LD_PRELOAD` lines). If one did, this installer does not touch that part and offers to install the other part alone
- that the Common.js file TouchTune patches is the known one (TouchTune checks this itself as well). If it is not, the stick offers Android Auto touch alone

Write path, for each file: backup on the car (written once, verified) → staged copy next to the target → XML validation → atomic rename → read-back. Any failure rolls back to the recorded state; the watchdog and the read-only root file system are restored; then Mazda's own SafeReboot is requested (never a raw reboot). TouchTune runs as its own unmodified process with a clean environment, only after the Android Auto part has finished.

## Files the stick writes

| File | Content |
|---|---|
| `mzd-usb.log` | log of every run |
| `diag-*.txt` | written by **Diagnosis**: versions, file hashes, state of both parts. No Mazda file contents and no personal data, so you can attach it to an issue |
| `touchtune/touchtune.log` | TouchTune's own log |
| `backup-aa-touch-*/` | a copy of the original Android Auto files of **your** car (the main backup stays on the car). Keep it; do not upload it |

## Troubleshooting

- **No dialog appears.** Check: FAT32, files at the top level (see the check in step 2), no other files on the stick, no other USB device plugged in, on macOS the `._` files removed. Try the other USB port. Wait up to a minute after Mazda Connect has started.
- **Windows says a file name is too long while extracting.** Extract straight onto the stick (step 2) or into a short folder such as `C:\stick`. One file name on the stick is 184 characters long, which deep folders such as some OneDrive paths cannot hold.
- **"Unsupported firmware".** Only 74.00.324 and 74.00.324A are supported. A `diag-*.txt` file is on the stick.
- **"Another installer already modified Android Auto".** Remove that modification with the installer that made it, then run this stick again.
- **"The files on the stick are damaged".** Copy the ZIP contents to the stick again (or use another stick).
- **Something else.** Open an issue and attach `mzd-usb.log`, the newest `diag-*.txt` and `touchtune/touchtune.log`. Do **not** attach the `backup-aa-touch-*` folders.

Advanced: an `ACTION.txt` file at the top level of the stick selects an action without the start dialog: `install`, `uninstall`, `diagnose`, `status` (log only) or `touchtune` (TouchTune's own menu). Changes are still confirmed on the screen. Delete the file to get the dialog back.

## Build the stick yourself

Not needed for normal use: the release ZIP is the finished stick. Building it yourself requires Python 3.8 or newer and nothing else.

```bash
python3 tools/build_stick.py build --download
```

This downloads the two pinned upstream releases from GitHub, checks every file against a pinned SHA-256, builds `dist/stick/` and `dist/mzd-touch-installer-<version>.zip`, and verifies the result the same way the car does. With `--target E:\` (Windows) or `--target /Volumes/STICK` it also writes the stick; the target must be empty or already carry this installer (its logs, diagnoses and `backup-aa-touch-*` folders are kept). Already downloaded files can be passed with `--aa-mod-zip`, `--touchtune-zip`, `--aa-mod-license` and `--aa-mod-notice`.

Pinned upstream files:

| File | SHA-256 |
|---|---|
| [oem-aa-mod-0.10.0.zip](https://github.com/VitaliyKurokhtin/oem-aa-mod/releases/tag/0.10.0) | `ba7a0c285269a87e8a199e38517de05da749a67df7ca016abb6d15e65112dc6a` |
| [TouchTune-1.2.1.zip](https://github.com/Miatafy/TouchTune/releases/tag/v1.2.1) | `3397a541aacebb1c0a4476c12eeb3479a643990ba67521745c7de47ad072dc68` |

## Tests

```bash
sh tests/run-tests.sh
```

The suite runs on any POSIX shell (Git Bash, Linux, macOS, BusyBox ash in Docker) against a fake Mazda Connect file tree: install, removal, repair, partial states, all injected write faults and their rollback, the dialogs, other regions with unknown binaries, byte-exact removal, and the diagnosis privacy rules. With the upstream ZIPs in `downloads/` it also runs the real stick, and with `MZD_TEST_REAL_ROOTFS=<dump of a 74.00.324A root file system>` the real TouchTune patches and restores the real Common.js.

## Repository layout

```
stick/            files that go on the stick
  run.sh          entry point: checks the stick, shows the dialog
  lib/            mzd-safety.sh (write safety), aa-touch.sh (oem-aa-mod), combined.sh (both parts)
  payload/        install.sh, uninstall.sh, diagnose.sh
tools/build_stick.py
tests/run-tests.sh
```

## License and credits

- The scripts in this repository: **GPL-3.0-or-later** ([LICENSE](LICENSE)). Notices and third-party licenses: [NOTICE.md](NOTICE.md).
- oem-aa-mod by VitaliyKurokhtin: AGPL-3.0. The release files are included unmodified; source: <https://github.com/VitaliyKurokhtin/oem-aa-mod/tree/0.10.0>.
- TouchTune by Miatafy: GPL-3.0, based on MZD-AIO by Trevelopment. Included unmodified; source: <https://github.com/Miatafy/TouchTune>.

Not affiliated with or endorsed by Mazda Motor Corporation, the authors of oem-aa-mod or TouchTune, or Google. Android Auto is a trademark of Google LLC. Modifying the head unit may affect your warranty. This software comes with no warranty; use it at your own risk. "Remove both" is always available.
