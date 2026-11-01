#!/bin/sh
# combined.sh -- one USB run that installs or removes Android Auto touch
# (oem-aa-mod) AND touch while driving (TouchTune).
#
# Design rules:
#   1. TouchTune (https://github.com/Miatafy/TouchTune, GPL-3.0) runs unmodified
#      and only as a child process; its script is never sourced (both trees
#      define mzd_* functions and set their own traps).
#   2. The child gets a clean environment (env -i), so TouchTune always uses its
#      own defaults and its own backup in /data/touchtune/backups.
#   3. TouchTune exit 0 does not prove a change (its guard and cancel paths also
#      exit 0), so its guard is checked before any change and the TouchTune
#      state is read again after the child.
#   4. TouchTune starts only after the Android Auto transaction has been
#      finalized (rootfs read-only, watchdog re-enabled); after a TouchTune
#      failure this run writes nothing more and does not restart.
#   5. Nothing is rolled back automatically across the two parts: each part is
#      its own verified transaction, and running the stick again is idempotent.
#
# Copyright (C) 2026 caeptncrack
# SPDX-License-Identifier: GPL-3.0-or-later

[ -n "${MZD_COMBINED_LOADED:-}" ] && return 0
MZD_COMBINED_LOADED=1

MZD_TT_DIR="$MZD_STICK/touchtune"
MZD_TT_SCRIPT="$MZD_TT_DIR/install-patches.sh"
MZD_TT_COMMON="$MZD_ROOT/jci/gui/common/js/Common.js"
MZD_TT_NVRAM_KEYS="$MZD_ROOT/sys/class/nvram/nv-config/keys"
MZD_TT_GUARD="$MZD_ROOT/tmp/touchtune-installer.guard"

# TouchTune 1.2.1 profile mazda-connect-74.00.324-common-v1 (same values as in
# touchtune/lib/touchtune-helpers.sh; Common.js is identical across regions).
MZD_TT_STOCK_SHA="376b30a46366a543122956d7feb1b44f147425015837a4d83fedf12a67943351"
MZD_TT_PATCHED_SHA="019eba18e8d629ddb1d55563aab138ce1eb3329fab67b71d9b4178377cf9d9ce"

# ---------------------------------------------------------------------------
# Read-only TouchTune state (missing | stock | installed | partial | foreign)
# ---------------------------------------------------------------------------

combined_tt_nvram() {
    local file="$MZD_TT_NVRAM_KEYS/$1" value
    if [ -f "$file" ] && [ ! -L "$file" ]; then
        value=$(tr -d '\r\n' <"$file" 2>/dev/null) || { printf 'invalid\n'; return 0; }
        case "$value" in
            enable|disable) printf '%s\n' "$value" ;;
            *) printf 'invalid\n' ;;
        esac
        return 0
    fi
    # Missing key = factory state; Mazda's setters create it lazily.
    printf 'enable\n'
}

combined_tt_state() {
    local common bus lvds
    # Host-test hook: a fake TouchTune child may drop a state file.
    if [ "$MZD_TEST_MODE" = 1 ] && [ -f "$MZD_TT_DIR/.tt-state" ]; then
        tr -d '\r\n' <"$MZD_TT_DIR/.tt-state"
        printf '\n'
        return 0
    fi
    if [ ! -f "$MZD_TT_COMMON" ]; then printf 'missing\n'; return 0; fi
    common=$(mzd_sha256_file "$MZD_TT_COMMON" 2>/dev/null) || { printf 'foreign\n'; return 0; }
    case "$common" in
        "$MZD_TT_STOCK_SHA") common=stock ;;
        "$MZD_TT_PATCHED_SHA") common=patched ;;
        *) printf 'foreign\n'; return 0 ;;
    esac
    bus=$(combined_tt_nvram bus_bcm_speed_restriction)
    lvds=$(combined_tt_nvram lvds_speed_restriction)
    case "$common:$bus:$lvds" in
        stock:enable:enable) printf 'stock\n' ;;
        patched:disable:disable) printf 'installed\n' ;;
        *:invalid:*|*:*:invalid) printf 'foreign\n' ;;
        *) printf 'partial\n' ;;
    esac
}

combined_tt_guard_present() {
    [ -e "$MZD_TT_GUARD" ] || [ -L "$MZD_TT_GUARD" ]
}

combined_tt_payload_ok() {
    local f
    for f in install-patches.sh lib/touchtune-helpers.sh patches/touch-while-driving.sh \
             PAYLOAD.SHA256 TOUCHTUNE.ID VERSION; do
        mzd_real_file "$MZD_TT_DIR/$f" || {
            mzd_error "TouchTune payload missing or damaged: touchtune/$f"
            return 1
        }
    done
    return 0
}

# Run TouchTune as a child process with a clean environment (rules 1 and 2).
# combined_tt_run <touch-while-driving|--restore>
combined_tt_run() {
    local action="$1" rc
    mzd_log "starting TouchTune as a child process: $action (env -i)"
    if [ "$MZD_TEST_MODE" = 1 ]; then
        # Tests: pass exactly the test values the child may read.
        env -i PATH="$PATH" MZD_TEST_MODE=1 MZD_ROOT="$MZD_ROOT" MZD_STICK="$MZD_STICK" \
            sh "$MZD_TT_SCRIPT" "$action"
    else
        env -i PATH=/bin:/usr/bin:/sbin:/usr/sbin sh "$MZD_TT_SCRIPT" "$action"
    fi
    rc=$?
    # TouchTune drew its own messages; they stay on the screen.
    mzd_dialog_note "" 0
    mzd_log "TouchTune child exit=$rc"
    return "$rc"
}

# Human-readable state names for the dialogs.
combined_aa_label() {
    case "$1" in
        clean) printf 'not installed\n' ;;
        ours) printf 'installed\n' ;;
        partial) printf 'partially installed\n' ;;
        foreign) printf 'modified by another installer\n' ;;
        *) printf 'unknown state\n' ;;
    esac
}

combined_tt_label() {
    case "$1" in
        stock) printf 'not installed\n' ;;
        installed) printf 'installed\n' ;;
        partial) printf 'partially installed\n' ;;
        missing) printf 'Common.js missing\n' ;;
        *) printf 'not supported on this build\n' ;;
    esac
}

# Combined state for the start dialog; sets COMBINED_AA and COMBINED_TT.
combined_detect() {
    if aa_verify_payload >/dev/null 2>&1; then
        aa_state_parse
        COMBINED_AA="$AA_STATE"
    else
        COMBINED_AA=payload-invalid
    fi
    if combined_tt_payload_ok >/dev/null 2>&1; then
        COMBINED_TT=$(combined_tt_state)
    else
        COMBINED_TT=payload-invalid
    fi
    mzd_log "detected state: Android Auto touch=$COMBINED_AA TouchTune=$COMBINED_TT"
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

combined_install() {
    local aa_before tt_before rc aa_todo=0 tt_todo=0 tt_after
    mzd_log "=== combined install: Android Auto touch + TouchTune ==="
    if ! mzd_require_firmware; then
        mzd_popup "Unsupported firmware.\n\nThis installer supports Mazda Connect 74.00.324 and 74.00.324A.\nNothing was changed."
        return 1
    fi
    aa_verify_payload || {
        mzd_popup "The oem-aa-mod files on the stick are missing or damaged.\n\nNothing was changed."
        return 1
    }
    aa_target_binaries_check || {
        mzd_popup "A required Mazda Connect component is missing (aap_service/blmjciaapa/svcjcinavi or the AA XML).\n\nNothing was changed."
        return 1
    }
    combined_tt_payload_ok || {
        mzd_popup "The TouchTune files on the stick are missing or damaged.\n\nNothing was changed."
        return 1
    }
    if combined_tt_guard_present; then
        mzd_popup "A TouchTune installer is already running.\n\nNothing was changed.\nPlease wait or restart Mazda Connect."
        return 1
    fi
    aa_state_parse
    aa_before="$AA_STATE"
    tt_before=$(combined_tt_state)
    mzd_log "state before the combined install: AA=$aa_before${AA_STATE_REASON:+ ($AA_STATE_REASON)} TouchTune=$tt_before"
    case "$aa_before" in
        clean|partial) aa_todo=1 ;;
        ours) aa_todo=0 ;;
        *) aa_todo=skip ;;
    esac
    case "$tt_before" in
        stock|partial) tt_todo=1 ;;
        installed) tt_todo=0 ;;
        *) tt_todo=skip ;;
    esac
    if [ "$aa_todo" = 0 ] && [ "$tt_todo" = 0 ]; then
        mzd_popup "Android Auto touch and TouchTune are already installed.\n\nThere is nothing to do."
        return 0
    fi
    # One part cannot be installed on this unit: offer the other one alone.
    if [ "$aa_todo" = skip ] && [ "$tt_todo" = skip ]; then
        mzd_popup "Neither part can be installed safely.\n\nAndroid Auto touch: $(combined_aa_label "$aa_before")\nTouchTune: $(combined_tt_label "$tt_before")\n\nNothing was changed. Details: mzd-usb.log"
        return 1
    fi
    if [ "$aa_todo" = skip ]; then
        mzd_ask2 "Android Auto touch: $(combined_aa_label "$aa_before") - it is left alone.\n\nInstall only TouchTune (touch while driving)?" "TouchTune only" "Cancel" || {
            mzd_popup "Cancelled.\n\nNothing was changed."
            return 1
        }
        aa_todo=0
    fi
    if [ "$tt_todo" = skip ]; then
        mzd_ask2 "TouchTune: $(combined_tt_label "$tt_before") - it is left alone.\n\nInstall only Android Auto touch?" "AA touch only" "Cancel" || {
            mzd_popup "Cancelled.\n\nNothing was changed."
            return 1
        }
        tt_todo=0
    fi

    if [ "$aa_todo" = 1 ]; then
        MZD_SKIP_REBOOT=1
        MZD_CONFIRMED=1
        export MZD_SKIP_REBOOT MZD_CONFIRMED
        aa_install
        rc=$?
        unset MZD_SKIP_REBOOT
        if [ "$rc" -ne 0 ]; then
            mzd_popup "The Android Auto touch installation did not complete; TouchTune was not started.\n\nDetails: mzd-usb.log"
            return 1
        fi
        aa_state_parse
        if [ "$AA_STATE" != ours ]; then
            mzd_popup "The final check of Android Auto touch failed ($AA_STATE).\n\nTouchTune was not started; no restart."
            return 1
        fi
        mzd_log "Android Auto touch finalized; now TouchTune"
    fi

    if [ "$tt_todo" = 1 ]; then
        if combined_tt_guard_present; then
            mzd_popup "A TouchTune installer started in the meantime.\n\nAndroid Auto touch: $(combined_aa_label "$(aa_state_parse; printf '%s' "$AA_STATE")")\nTouchTune was not started. No restart."
            return 1
        fi
        combined_tt_run touch-while-driving
        rc=$?
        tt_after=$(combined_tt_state)
        if [ "$rc" -ne 0 ] || [ "$tt_after" != installed ]; then
            if [ "$rc" -eq 0 ]; then
                tt_note="TouchTune requested a restart. Afterwards run the stick again to see the state."
            else
                tt_note="No restart. Logs on the stick: mzd-usb.log, touchtune/touchtune.log"
            fi
            aa_state_parse
            mzd_popup "TouchTune could not be confirmed (exit $rc, state $tt_after).\n\nAndroid Auto touch: $(combined_aa_label "$AA_STATE")\nTouchTune: $(combined_tt_label "$tt_after")\n\n$tt_note"
            return 1
        fi
        mzd_log "TouchTune installed and read back; it requests the final SafeReboot"
        return 0
    fi

    # Only Android Auto touch changed in this run.
    if ! mzd_ask_reboot "Android Auto touch is installed.\nTouchTune: $(combined_tt_label "$(combined_tt_state)")."; then
        mzd_popup "The restart could not be requested.\n\nPlease restart Mazda Connect manually."
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Removal
# ---------------------------------------------------------------------------

combined_revert() {
    local aa_before tt_before rc aa_done=0 tt_after aa_note
    mzd_log "=== combined removal: Android Auto touch + TouchTune ==="
    if ! mzd_require_firmware; then
        mzd_popup "Unsupported firmware.\n\nNothing was changed."
        return 1
    fi
    aa_verify_payload || {
        mzd_popup "The oem-aa-mod files on the stick are missing or damaged.\n\nNothing was changed."
        return 1
    }
    combined_tt_payload_ok || {
        mzd_popup "The TouchTune files on the stick are missing or damaged.\n\nNothing was changed."
        return 1
    }
    if combined_tt_guard_present; then
        mzd_popup "A TouchTune installer is already running.\n\nNothing was changed."
        return 1
    fi
    aa_state_parse
    aa_before="$AA_STATE"
    tt_before=$(combined_tt_state)
    mzd_log "state before the combined removal: AA=$aa_before${AA_STATE_REASON:+ ($AA_STATE_REASON)} TouchTune=$tt_before"

    case "$aa_before" in
        clean) ;;
        ours|partial)
            MZD_SKIP_REBOOT=1
            MZD_CONFIRMED=1
            export MZD_SKIP_REBOOT MZD_CONFIRMED
            aa_revert
            rc=$?
            unset MZD_SKIP_REBOOT
            if [ "$rc" -ne 0 ]; then
                mzd_popup "The removal of Android Auto touch did not complete; TouchTune was not touched.\n\nNo restart. Details: mzd-usb.log"
                return 1
            fi
            aa_state_parse
            if [ "$AA_STATE" != clean ]; then
                mzd_popup "The removal of Android Auto touch could not be confirmed ($AA_STATE).\n\nTouchTune was not touched; no restart."
                return 1
            fi
            aa_done=1
            mzd_log "Android Auto touch removed; original files verified"
            ;;
        *)
            mzd_log "Android Auto touch state $aa_before is left alone"
            ;;
    esac

    if [ "$aa_done" = 1 ]; then
        aa_note=removed
    elif [ "$aa_before" = clean ]; then
        aa_note="not installed"
    else
        aa_note="left alone ($(combined_aa_label "$aa_before"))"
    fi

    case "$tt_before" in
        installed|partial)
            combined_tt_run --restore
            rc=$?
            tt_after=$(combined_tt_state)
            if [ "$rc" -ne 0 ] || [ "$tt_after" != stock ]; then
                if [ "$rc" -eq 0 ]; then
                    tt_note="TouchTune requested a restart. Afterwards run the stick again to see the state."
                else
                    tt_note="No restart. Logs on the stick: mzd-usb.log, touchtune/touchtune.log"
                fi
                mzd_popup "The TouchTune removal could not be confirmed (exit $rc, state $tt_after).\n\nAndroid Auto touch: $aa_note\nTouchTune: $(combined_tt_label "$tt_after")\n\n$tt_note"
                return 1
            fi
            mzd_log "TouchTune removed and read back; it requests the final SafeReboot"
            return 0
            ;;
        stock) ;;
        *)
            mzd_log "TouchTune state $tt_before is left alone"
            ;;
    esac

    if [ "$aa_done" = 1 ]; then
        if ! mzd_ask_reboot "Android Auto touch is removed.\nTouchTune: $(combined_tt_label "$tt_before")."; then
            mzd_popup "The restart could not be requested.\n\nPlease restart Mazda Connect manually."
        fi
        return 0
    fi
    mzd_popup "Nothing to remove.\n\nAndroid Auto touch: $aa_note\nTouchTune: $(combined_tt_label "$tt_before")"
    return 0
}
