# Changelog

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
