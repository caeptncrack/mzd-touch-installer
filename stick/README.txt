MZD Touch Installer - Android Auto touch + touch while driving
for Mazda Connect 74.00.324 / 74.00.324A (tested in a car on EU 74.00.324A)

Project page, full instructions and source:
  @PROJECT_URL@

This stick installs or removes, in one run:
  1. Android Auto touch      - oem-aa-mod 0.10.0 by VitaliyKurokhtin
                               https://github.com/VitaliyKurokhtin/oem-aa-mod
  2. Touch while driving     - TouchTune 1.2.1 by Miatafy
                               https://github.com/Miatafy/TouchTune
Both are included unmodified (folders aa-mod/ and touchtune/). The Android
Auto XML of your car is not replaced: only oem-aa-mod's touch, media-pause
and navigation entries are added, the video settings stay as shipped.

USE
  1. Stick: FAT32 (up to 32 GB), nothing else on it. Copy ALL files of the
     release ZIP to the top level of the stick (not into a folder): you see
     run.sh, README.txt and the folders aa-mod, lib, payload, touchtune.
  2. Car in ACC or engine running, Mazda Connect fully started.
  3. Plug the stick into a USB port of the centre console. After a few
     seconds a dialog shows the current state and offers:
       nothing installed     -> Install / Diagnosis / Cancel
       both installed        -> Remove both / Diagnosis / Cancel
       one of them installed -> Install / Remove / Cancel
  4. Every button first opens a short confirmation that says what will
     happen: tap Start (Back returns to the start dialog).
  5. Then do not pull the stick and do not press anything until the
     screen tells you to: "Remove the USB" before the restart, or
     "You can pull the stick now" when a run ends without one.

  Before the first change the installer backs up the original files ON THE
  CAR (/data_persist/mzd-aa-touch/backups/ and /data/touchtune/backups/).
  "Remove" restores exactly those files. No Mazda file is on this stick.

FILES THE STICK WRITES
  mzd-usb.log      log of every run (attach it to a bug report)
  diag-*.txt       written by "Diagnosis": versions, hashes and state only;
                   no copies of Mazda files, no personal data

ADVANCED (optional): ACTION.txt in the top level of the stick
  install | uninstall | diagnose   same as the dialog buttons (still asks)
  touchtune                        TouchTune's own menu (TouchTune alone)
  status                           write the state to mzd-usb.log only
  Delete ACTION.txt to get the normal dialog back.

macOS: Finder adds hidden "._" files that can stop the car from starting
the stick. Run "dot_clean -m /Volumes/<STICK>" in Terminal before ejecting.

SAFETY
  Touch while driving can distract. Use it only when it is safe and legal
  where you drive; the driver stays responsible. Not affiliated with or
  endorsed by Mazda. Use at your own risk; you can always run "Remove".
