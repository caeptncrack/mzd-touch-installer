# Changelog

## 1.0.1 — 2026-11-01

- **Android Auto 1.5 towards the phone, as from the factory.** `libpatch.conf`
  is shipped with one line changed, `use_protocol_v1_6 = false` (the upstream
  default), and oem-aa-mod's `aap_service` shim, which only acts at 1.6, is no
  longer installed. With 1.6 a phone on a wireless Android Auto adapter skips
  the Bluetooth pairing request Mazda Connect waits for; oem-aa-mod bridges
  that only for adapters whose name it knows. Touch, mute pauses the phone and
  the head-up display guidance (turn arrow, distance, street name) stay; lane
  guidance needs 1.6.
- **Update in place.** An installation by 1.0.0 (Android Auto 1.6) or by an
  early build that copied oem-aa-mod's XML files is recognized ("older version
  installed") and the start dialog offers **Update**: the service
  configuration and the XMLs are rebuilt from the backup the first
  installation took on the car, the `aap_service` shim is moved aside, the new
  `libpatch.conf` is installed and the result is checked like a new
  installation; a failure rolls back to the original files. The installation
  marker records `previous_installer`. **Remove both** also works on an old
  installation directly.
- The stick builder pins the shipped `libpatch.conf`
  (`b874a9cf85916799032ae5b874d88a2f714d733a31a3e6cdeba785c6e25d827a`) and
  `aa-mod/SOURCE.txt` states the change.
- Tests: the default test stick uses 1.5; new cases for the update from 1.0.0
  and from early builds, faults during the update, removal of an old
  installation, and (in a git checkout) the real 1.0.0 stick rebuilt from its
  tag and updated by the new one.

## 1.0.0 — 2026-11-01

First public release.

- One USB stick installs or removes Android Auto touch (oem-aa-mod 0.10.0)
  and touch while driving (TouchTune 1.2.1) in one run, with a start dialog
  that shows the current state.
- Every button of the start dialog first opens a confirmation that says what
  will happen and when to pull the stick (**Start** / **Back**). Right after
  it a "working, do not pull the stick" message appears, and every run that
  ends without a restart says "You can pull the stick now". (`jci-dialog` has
  no pressed state, so the next screen is the visible answer to a tap.)
- Removal restores the backup taken on the car; no Mazda files are needed or
  shipped.
- The Android Auto XML of the car is patched instead of replaced: only
  oem-aa-mod's touch screen entry, `MEDIA_PAUSE` and the navigation
  subscription for the head-up display are added; `<display>` and `<video>`
  stay as shipped, so Android Auto keeps the factory video settings
  (oem-aa-mod's replacement file changes `par`, `fps`,
  `decoder_additional_depth` and adds `real_density`). The change is checked
  by taking it out again and comparing with the original byte for byte.
- Backups are chosen without relying on the clock (Mazda Connect starts at
  1970 after every boot): the backup named by the installation in place, else
  one of the running firmware; two backups in the same second get a suffix.
- Accepts 74.00.324 and 74.00.324A of every region. A unit that differs from
  the car-tested EU 74.00.324A build is reported, and the user is asked
  before anything changes.
- When one part cannot be installed (another installer changed Android Auto,
  or Common.js is not the known file), the other part is offered alone.
- Shareable diagnosis file without Mazda file contents.
- The release ZIP extracts with Windows' own "Extract All": TouchTune's
  launcher (a 253-character file name) is carried as `lib/touchtune-launcher`
  and gets its official name on the stick in the car, before TouchTune checks
  its payload.
- Cross-platform stick builder (`tools/build_stick.py`) with pinned upstream
  hashes; host test suite (`tests/run-tests.sh`). Writing over a used stick
  (`--target`) keeps `mzd-usb.log`, `diag-*.txt`, `touchtune/touchtune.log`
  and the `backup-aa-touch-*` folders.
