#!/bin/sh
# install.sh -- install Android Auto touch + TouchTune in one USB run.
#
# The Android Auto transaction runs first and is finalized (rootfs read-only,
# watchdog re-enabled) before the TouchTune child starts; TouchTune then owns
# the single final SafeReboot. See lib/combined.sh.
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
combined_install
rc=$?
# The last message tells the user when the stick may be pulled.
mzd_popup_final
exit "$rc"
