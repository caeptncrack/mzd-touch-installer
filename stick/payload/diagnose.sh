#!/bin/sh
# diagnose.sh -- write a shareable status report to the USB stick (read-only).
#
# Changes nothing on Mazda Connect. The report contains versions, hashes and
# the state of both parts; it copies no Mazda files and reads only the two
# NVRAM keys TouchTune uses, so it can be attached to a bug report.
#
# Copyright (C) 2026 caeptncrack
# SPDX-License-Identifier: GPL-3.0-or-later

BASE=${1:-$(cd "$(dirname "$0")/.." && pwd)}
MODE=${2:-}
MZD_STICK="$BASE"
export MZD_STICK
. "$BASE/lib/mzd-safety.sh" || exit 1
. "$BASE/lib/aa-touch.sh" || exit 2
. "$BASE/lib/combined.sh" || exit 3

R="$MZD_ROOT"
OUT="$BASE/diag-$(date +%Y%m%d-%H%M%S).txt"

{
    echo "# MZD touch installer diagnosis"
    echo "installer=$(tr -d '\r\n' <"$BASE/VERSION" 2>/dev/null)"
    echo "date=$(date)"
    echo
    echo "## Firmware"
    for key in JCI_SW_VER JCI_SW_VER_PATCH JCI_SW_FLAVOR JCI_SW_PART_NUMBER JCI_BUILD_START_TIME; do
        printf '%s=%s\n' "$key" "$(mzd_version_value "$key" 2>/dev/null)"
    done
    printf 'normalized=%s\n' "$(mzd_firmware 2>/dev/null || echo unreadable)"
    echo
    echo "## System"
    uname -a 2>/dev/null
    awk '$2 == "/" { print "mount: " $0 }' "$R/proc/mounts" 2>/dev/null
    df -h 2>/dev/null | awk 'NR == 1 || $NF == "/" || $NF ~ /data/'
    echo
    echo "## Android Auto touch (oem-aa-mod)"
    aa_status 2>&1
    if aa_target_binaries_check >/dev/null 2>&1; then
        printf 'binaries_identical_to_tested_EU_build=%s\n' "$AA_BINARIES_KNOWN"
    else
        echo "binaries: missing (see mzd-usb.log)"
    fi
    for f in "$MZD_SM_CONF" "$MZD_SM_WCP" "$MZD_AA_XML" "$MZD_AA_XML_UCP"; do
        [ -f "$f" ] || { printf '%s: missing\n' "$(basename "$f")"; continue; }
        sha=$(mzd_sha256_file "$f" 2>/dev/null)
        same=no
        [ "$sha" = "$(aa_tested_hash "$(basename "$f")")" ] && same=yes
        printf '%s: %s bytes, sha256=%s, same_as_tested_EU=%s, touch_screen=%s\n' "$(basename "$f")" \
            "$(mzd_bytes "$f" 2>/dev/null)" "$sha" "$same" "$(grep -c '<touch_screen>' "$f" 2>/dev/null)"
        [ -e "$f.orig" ] && printf '  %s.orig exists (another installer)\n' "$(basename "$f")"
    done
    for f in "$MZD_SM_CONF" "$MZD_SM_WCP"; do
        [ -f "$f" ] || continue
        printf '%s environ_var/LD_PRELOAD lines:\n' "$(basename "$f")"
        grep -n -E 'environ_var|LD_PRELOAD' "$f" 2>/dev/null || echo "  (none)"
    done
    echo "oem-aa-mod folder:"
    ls -la "$MZD_AA_DIR" 2>/dev/null || echo "  (not present)"
    echo "backups of this installer:"
    ls -1 "$MZD_BACKUP_ROOT" 2>/dev/null || echo "  (none)"
    echo
    echo "## Touch while driving (TouchTune)"
    printf 'state=%s\n' "$(combined_tt_state)"
    if [ -f "$MZD_TT_COMMON" ]; then
        printf 'Common.js: %s bytes, sha256=%s (stock 376b30a4..., TouchTune 019eba18...)\n' \
            "$(mzd_bytes "$MZD_TT_COMMON" 2>/dev/null)" "$(mzd_sha256_file "$MZD_TT_COMMON" 2>/dev/null)"
    else
        echo "Common.js: missing"
    fi
    for key in bus_bcm_speed_restriction lvds_speed_restriction; do
        if [ -f "$MZD_TT_NVRAM_KEYS/$key" ]; then
            printf 'NVRAM %s=%s\n' "$key" "$(tr -d '\r\n' <"$MZD_TT_NVRAM_KEYS/$key" 2>/dev/null)"
        else
            printf 'NVRAM %s=(not present = factory value enable)\n' "$key"
        fi
    done
    if [ -f "$R/data/touchtune/backups/common-js/metadata" ]; then
        echo "TouchTune backup metadata:"
        sed 's/^/  /' "$R/data/touchtune/backups/common-js/metadata" 2>/dev/null
    else
        echo "TouchTune backup: (not present)"
    fi
    echo
    echo "## Processes"
    ps 2>/dev/null | grep -E 'aap_service|jciAAPA|jcinavi|jciMMUI' | grep -v grep
} >"$OUT" 2>&1

mzd_log "diagnosis written: $OUT"
if [ "$MODE" != quiet ]; then
    sync
    mzd_popup "Diagnosis written to the stick:\n$(basename "$OUT")\n\nNothing was changed.\nYou can pull the stick now."
fi
exit 0
