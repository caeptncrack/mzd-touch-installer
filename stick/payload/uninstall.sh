#!/bin/sh
# uninstall.sh -- remove Android Auto touch + TouchTune in one USB run.
#
# Android Auto touch is removed first from the backup taken on this car
# (restart suppressed), then TouchTune --restore runs as a child process with a
# clean environment and uses its own /data/touchtune/backups; TouchTune then
# owns the single final SafeReboot. No Mazda file from the stick is needed.
#
# Copyright (C) 2026 caeptncrack
# SPDX-License-Identifier: GPL-3.0-or-later

BASE=${1:-$(cd "$(dirname "$0")/.." && pwd)}
MZD_STICK="$BASE"
export MZD_STICK
. "$BASE/lib/mzd-safety.sh" || exit 1
. "$BASE/lib/aa-touch.sh" || exit 2
. "$BASE/lib/combined.sh" || exit 3
mzd_install_traps
combined_revert
rc=$?
# The last message tells the user when the stick may be pulled.
mzd_popup_final
exit "$rc"
