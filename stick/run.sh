#!/bin/sh
# run.sh -- entry point of the MZD touch installer.
#
# The CMU's auto-update service starts this script as root when the stick
# contains the empty trigger file "jci-autoupdate" and exactly one ".up" file
# whose file name is a shell command substitution. That launcher finds this
# stick by STICK.ID and runs this file.
#
# This file is the only unverified starting point (by definition); it verifies
# the complete remaining payload against PAYLOAD.SHA256 before sourcing or
# running anything else. It never writes to the system by itself: the
# transactions in lib/aa-touch.sh and the TouchTune child own the write window.
#
# Host tests run this script with MZD_TEST_MODE=1, MZD_ROOT=<fake root> and
# MZD_STICK=<test stick> (see tests/run-tests.sh).
#
# Copyright (C) 2026 caeptncrack
# SPDX-License-Identifier: GPL-3.0-or-later

BASE=$(cd "$(dirname "$0")" && pwd) || exit 1
MZD_STICK="$BASE"
MZD_LOG="$BASE/mzd-usb.log"
EXPECTED_STICK_ID="mzd-touch-installer-v1"
export MZD_STICK
PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
export PATH

# The stick may be mounted read-only; the update service usually keeps it rw.
mount -o rw,remount "$BASE" 2>/dev/null || true
if [ "${MZD_TEST_MODE:-0}" = 1 ]; then
    echo "TEST MODE: output to the console instead of mzd-usb.log"
else
    if : >>"$MZD_LOG" 2>/dev/null; then
        exec >>"$MZD_LOG" 2>&1
    else
        echo "WARNING: USB log not writable, console output only" >&2
    fi
fi
echo "=== MZD touch installer $(date) ==="
echo "BASE=$BASE"

popup_error() {
    [ -x /jci/tools/jci-dialog ] || return 0
    killall -q jci-dialog 2>/dev/null || true
    /jci/tools/jci-dialog --info --title="MZD Touch Installer" \
        --text="$1\n\nNothing was changed.\nDetails: mzd-usb.log on the stick\nYou can pull the stick now." --no-cancel \
        >/dev/null 2>&1 &
    sleep 4
    killall -q jci-dialog 2>/dev/null || true
}

fail() {
    echo "ERROR: $*" >&2
    popup_error "$*"
    exit 1
}

# --- SHA-256 helper available before the payload is sourced -----------------
sha256_of() {
    local out value
    if [ -x /usr/bin/openssl ]; then
        out=$(/usr/bin/openssl dgst -sha256 "$1" 2>/dev/null) || return 1
        value=${out##* }
    elif command -v openssl >/dev/null 2>&1; then
        out=$(openssl dgst -sha256 "$1" 2>/dev/null) || return 1
        value=${out##* }
    elif command -v sha256sum >/dev/null 2>&1; then
        out=$(sha256sum "$1" 2>/dev/null) || return 1
        value=${out%% *}
    elif command -v busybox >/dev/null 2>&1; then
        out=$(busybox sha256sum "$1" 2>/dev/null) || return 1
        value=${out%% *}
    else
        return 1
    fi
    [ "${#value}" -eq 64 ] || return 1
    printf '%s\n' "$value" | tr 'A-F' 'a-f'
}

# --- 1) Stick identity ------------------------------------------------------
[ -f "$BASE/STICK.ID" ] || fail "STICK.ID is missing on the stick"
[ "$(tr -d '\r\n' <"$BASE/STICK.ID")" = "$EXPECTED_STICK_ID" ] || fail "STICK.ID is invalid (wrong stick?)"

# --- 2) Complete payload manifest ------------------------------------------
MANIFEST="$BASE/PAYLOAD.SHA256"
EXPECTED="VERSION STICK.ID LAUNCHER.NAME jci-autoupdate run.sh \
lib/mzd-safety.sh lib/aa-touch.sh lib/combined.sh lib/touchtune-launcher \
payload/install.sh payload/uninstall.sh payload/diagnose.sh \
aa-mod/SHA256SUMS \
touchtune/install-patches.sh touchtune/lib/touchtune-helpers.sh \
touchtune/patches/touch-while-driving.sh touchtune/PAYLOAD.SHA256 \
touchtune/TOUCHTUNE.ID touchtune/VERSION touchtune/LAUNCHER.NAME \
touchtune/jci-autoupdate touchtune/LICENSE touchtune/NOTICE touchtune/SOURCE.txt \
touchtune/macos-usb-eject.sh"
# The official TouchTune launcher travels as lib/touchtune-launcher (see 3b).
EXPECTED_COUNT=25

[ -f "$MANIFEST" ] || fail "PAYLOAD.SHA256 is missing"
manifest_lines=$(grep -c . "$MANIFEST" 2>/dev/null | tr -d '[:space:]')
[ "${manifest_lines:-0}" = "$EXPECTED_COUNT" ] || \
    fail "PAYLOAD.SHA256 has ${manifest_lines:-0} entries (expected $EXPECTED_COUNT)"
for rel in $EXPECTED; do
    entry=$(awk -v n="$rel" '
        $2 == n {
            count++
            if (length($1) != 64) bad = 1
            digest = $1
        }
        END {
            if (count != 1 || bad) exit 1
            print digest
        }
    ' "$MANIFEST") || fail "manifest entry missing or duplicated: $rel"
    [ -f "$BASE/$rel" ] || fail "payload file missing: $rel"
    actual=$(sha256_of "$BASE/$rel") || fail "cannot hash: $rel"
    [ "$actual" = "$entry" ] || fail "payload hash differs: $rel (stick damaged or modified)"
done
echo "payload completely verified ($EXPECTED_COUNT files)"

# --- 3) Metadata -------------------------------------------------------------
[ ! -s "$BASE/jci-autoupdate" ] || fail "jci-autoupdate must be empty"
launcher=$(tr -d '\r\n' <"$BASE/LAUNCHER.NAME" 2>/dev/null)
case "$launcher" in
    '$('*').up') ;;
    *) fail "LAUNCHER.NAME is invalid" ;;
esac
launcher_found=0
for candidate in "$BASE"/*.up; do
    [ -e "$candidate" ] || [ -L "$candidate" ] || continue
    launcher_found=$((launcher_found + 1))
    [ "$(basename "$candidate")" = "$launcher" ] || fail "unexpected .up file on the stick"
done
[ "$launcher_found" = 1 ] || fail "exactly one .up launcher expected ($launcher_found found)"
stick_version=$(tr -d '\r\n' <"$BASE/VERSION" 2>/dev/null)
case "$stick_version" in ''|*[!0-9A-Za-z.-]*) fail "VERSION is invalid" ;; esac
echo "stick $stick_version, launcher $launcher"

# --- 3b) TouchTune launcher ---------------------------------------------------
# TouchTune's launcher has a 253-character name. Inside touchtune/ the path is
# longer than Windows Explorer can extract, so the release carries its bytes as
# lib/touchtune-launcher (verified above) and the file gets its official name
# here, on the stick, before TouchTune checks its own payload. It stays inert:
# the auto-update service only looks at the top level of the stick.
tt_launcher=$(tr -d '\r\n' <"$BASE/touchtune/LAUNCHER.NAME" 2>/dev/null)
case "$tt_launcher" in
    */*) fail "touchtune/LAUNCHER.NAME is invalid" ;;
    '$('*').up') ;;
    *) fail "touchtune/LAUNCHER.NAME is invalid" ;;
esac
tt_launcher_path="$BASE/touchtune/$tt_launcher"
tt_launcher_want=$(sha256_of "$BASE/lib/touchtune-launcher") || fail "cannot hash: lib/touchtune-launcher"
if [ -e "$tt_launcher_path" ] || [ -L "$tt_launcher_path" ]; then
    { [ -f "$tt_launcher_path" ] && [ ! -L "$tt_launcher_path" ] && \
        [ "$(sha256_of "$tt_launcher_path")" = "$tt_launcher_want" ]; } || \
        fail "the TouchTune launcher on the stick differs (copy the ZIP contents again)"
    echo "TouchTune launcher present"
else
    tt_tmp="$BASE/touchtune/.launcher.tmp"
    { cp "$BASE/lib/touchtune-launcher" "$tt_tmp" && mv -f "$tt_tmp" "$tt_launcher_path" && sync && \
        [ "$(sha256_of "$tt_launcher_path")" = "$tt_launcher_want" ]; } || {
        rm -f "$tt_tmp" 2>/dev/null
        fail "the TouchTune launcher could not be written to the stick (read-only?)"
    }
    echo "TouchTune launcher written to the stick"
fi

# --- 4) Load verified libraries and install traps --------------------------
. "$BASE/lib/mzd-safety.sh" || fail "the safety library could not be loaded"
if [ "${MZD_TEST_MODE:-0}" != 1 ]; then
    [ -d /jci ] || fail "/jci not found - this is not a Mazda Connect unit"
fi
. "$BASE/lib/aa-touch.sh" || fail "the AA touch library could not be loaded"
. "$BASE/lib/combined.sh" || fail "the combined library could not be loaded"
mzd_install_traps
mzd_guard || fail "another installer run is already active"
# Only the process that created the guard may remove it on cleanup.
MZD_GUARD_OWNER=1

run_payload() {
    local rc
    echo "action: $1"
    [ -f "$BASE/payload/$1.sh" ] || { mzd_error "payload missing: $1"; exit 1; }
    sh "$BASE/payload/$1.sh" "$BASE"
    rc=$?
    sync
    echo "payload result: $rc"
    exit "$rc"
}

# --- 5) Firmware -------------------------------------------------------------
if ! mzd_require_firmware; then
    MZD_TEST_MODE="${MZD_TEST_MODE:-0}" sh "$BASE/payload/diagnose.sh" "$BASE" quiet >/dev/null 2>&1
    sync
    mzd_popup "Unsupported firmware: ${MZD_FW:-$(mzd_firmware 2>/dev/null || echo unknown)} ($MZD_FW_FLAVOR).\n\nThis installer supports Mazda Connect 74.00.324 and 74.00.324A.\nNothing was changed. A diagnosis file was written to the stick.\n\nYou can pull the stick now."
    exit 1
fi

# --- 6) Action ----------------------------------------------------------------
ACTION=""
if [ -f "$BASE/ACTION.txt" ]; then
    ACTION=$(tr -d '\r\n ' <"$BASE/ACTION.txt")
fi

combined_detect
STATE_TEXT="Android Auto touch: $(combined_aa_label "$COMBINED_AA")\nTouch while driving (TouchTune): $(combined_tt_label "$COMBINED_TT")"

# Every button of the start dialog opens a confirmation that says what will
# happen and when the stick may be pulled; "Back" returns to the start dialog.
# jci-dialog draws no pressed state, so the next screen appearing at once is
# the visible answer to a tap. Lines stay short: jci-dialog does not wrap.
# confirm_action <action> <selected button> <second button>; 0 = confirmed
confirm_action() {
    case "$1" in
        install)
            mzd_ask2 "Selected: $2\n\nYour original files are backed up on this car,\nthen what is missing is installed and checked.\nMazda Connect restarts at the end.\n\nDo not pull the stick while it works.\nPull it only when the screen tells you to." "Start" "$3"
            ;;
        update)
            mzd_ask2 "Selected: $2\n\nAndroid Auto touch is updated in place with\nthe backup already taken on this car;\nanything missing is installed and checked.\nMazda Connect restarts at the end.\n\nDo not pull the stick while it works.\nPull it only when the screen tells you to." "Start" "$3"
            ;;
        uninstall)
            mzd_ask2 "Selected: $2\n\nYour original files are restored from the\nbackups on this car and checked.\nMazda Connect restarts at the end.\n\nDo not pull the stick while it works.\nPull it only when the screen tells you to." "Start" "$3"
            ;;
        diagnose)
            mzd_ask2 "Selected: $2\n\nA report (diag-*.txt) is written to the stick.\nNothing on the car is changed, no restart.\n\nPull the stick only when the screen\ntells you to." "Start" "$3"
            ;;
        *) return 0 ;;
    esac
}

CANCELLED=0
# KIND=update: "install" on an older installation (same payload, own texts).
KIND=""
UPDATE_TEXT="An update for Android Auto touch is available."
if [ -z "$ACTION" ]; then
    round=0
    while :; do
        round=$((round + 1))
        KIND=""
        case "$COMBINED_AA:$COMBINED_TT" in
            payload-invalid:*|*:payload-invalid)
                fail "the installer files on the stick are damaged"
                ;;
            outdated:installed)
                mzd_ask3 "$STATE_TEXT\n\n$UPDATE_TEXT\nWhat do you want to do?" "Update" "Remove both" "Cancel"
                case $? in 0) ACTION=install; KIND=update; LABEL=Update ;; 1) ACTION=uninstall; LABEL="Remove both" ;; *) ACTION=exit ;; esac
                ;;
            outdated:*)
                mzd_ask3 "$STATE_TEXT\n\n$UPDATE_TEXT\nWhat do you want to do?" "Update" "Remove" "Cancel"
                case $? in 0) ACTION=install; KIND=update; LABEL=Update ;; 1) ACTION=uninstall; LABEL=Remove ;; *) ACTION=exit ;; esac
                ;;
            ours:installed)
                mzd_ask3 "$STATE_TEXT\n\nWhat do you want to do?" "Remove both" "Diagnosis" "Cancel"
                case $? in 0) ACTION=uninstall; LABEL="Remove both" ;; 1) ACTION=diagnose; LABEL=Diagnosis ;; *) ACTION=exit ;; esac
                ;;
            ours:*|partial:*|*:installed|*:partial)
                mzd_ask3 "$STATE_TEXT\n\nWhat do you want to do?" "Install" "Remove" "Cancel"
                case $? in 0) ACTION=install; LABEL=Install ;; 1) ACTION=uninstall; LABEL=Remove ;; *) ACTION=exit ;; esac
                ;;
            *)
                mzd_ask3 "$STATE_TEXT\n\nInstall Android Auto touch and touch while driving?\nYour original files are backed up on this car first." "Install" "Diagnosis" "Cancel"
                case $? in 0) ACTION=install; LABEL=Install ;; 1) ACTION=diagnose; LABEL=Diagnosis ;; *) ACTION=exit ;; esac
                ;;
        esac
        [ "$ACTION" = exit ] && { CANCELLED=1; break; }
        confirm_action "${KIND:-$ACTION}" "$LABEL" "Back" && break
        mzd_log "confirmation: Back to the start dialog"
        ACTION=exit
        # A stick left in the car never loops for ever.
        [ "$round" -lt 5 ] || { CANCELLED=1; break; }
    done
else
    # ACTION.txt (advanced use): still confirm every change on the screen, so
    # a stick that stays in the car never changes anything by itself.
    case "$ACTION:$COMBINED_AA" in
        install:outdated)
            KIND=update
            confirm_action update "Update (ACTION.txt)" Cancel || { ACTION=exit; CANCELLED=1; }
            ;;
        install:*) confirm_action install "Install (ACTION.txt)" Cancel || { ACTION=exit; CANCELLED=1; } ;;
        uninstall:*) confirm_action uninstall "Remove (ACTION.txt)" Cancel || { ACTION=exit; CANCELLED=1; } ;;
    esac
fi

# Shown at once after the confirmation, until the payload's next message.
case "$ACTION" in
    install)
        if [ "$KIND" = update ]; then
            mzd_popup_busy "Updating...\n\nDo not pull the stick and\ndo not press anything."
        else
            mzd_popup_busy "Installing...\n\nDo not pull the stick and\ndo not press anything."
        fi
        ;;
    uninstall) mzd_popup_busy "Removing...\n\nDo not pull the stick and\ndo not press anything." ;;
    diagnose) mzd_popup_busy "Writing the report...\n\nDo not pull the stick." ;;
esac

case "$ACTION" in
    exit|cancel)
        echo "action: exit"
        if [ "$CANCELLED" = 1 ]; then
            sync
            mzd_popup "Cancelled. Nothing was changed.\n\nYou can pull the stick now."
        fi
        exit 0
        ;;
    status)
        aa_status
        printf 'touchtune=%s\n' "$COMBINED_TT"
        exit 0
        ;;
    touchtune)
        # TouchTune's own on-screen menu (repair/remove TouchTune alone).
        echo "action: TouchTune menu"
        env -i PATH=/bin:/usr/bin:/sbin:/usr/sbin sh "$BASE/touchtune/install-patches.sh"
        exit $?
        ;;
    install|uninstall|diagnose)
        MZD_CONFIRMED=1
        export MZD_CONFIRMED
        run_payload "$ACTION"
        ;;
    *)
        fail "unknown action in ACTION.txt: $ACTION"
        ;;
esac
