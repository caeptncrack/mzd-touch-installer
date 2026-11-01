#!/bin/sh
# mzd-safety.sh -- shared safety helpers for the MZD touch installer.
#
# The installer runs on a Mazda Connect CMU with firmware 74.00.324 or
# 74.00.324A (any region) as root, started by the CMU's auto-update service
# from a FAT32 USB stick. This library owns everything that can damage the
# unit if it goes wrong:
#
#   - logging and on-screen dialogs (jci-dialog)
#   - payload/hash verification (openssl, fallback sha256sum)
#   - firmware recognition (jci/version.ini)
#   - write-once backups under /data_persist
#   - staged writes beside the destination + atomic rename + readback
#   - XML validation with the firmware's own xmllint
#   - watchdog and read-only-rootfs handling
#   - Mazda SafeReboot (D-Bus) instead of a raw reboot
#   - trap-driven cleanup, rollback hook and a test mode
#
# Shell: BusyBox ash on the CMU; POSIX sh in the host tests. Only commands
# present on the CMU are used in production.
#
# Test mode (MZD_TEST_MODE=1) uses MZD_ROOT as a fake CMU root, skips mount,
# watchdog, chown and D-Bus calls and lets tests inject faults. The host test
# suite under tests/ drives this library.
#
# This file is verified against PAYLOAD.SHA256 by run.sh before it is sourced.
#
# Copyright (C) 2026 caeptncrack
# SPDX-License-Identifier: GPL-3.0-or-later

[ -n "${MZD_SAFETY_LOADED:-}" ] && return 0
MZD_SAFETY_LOADED=1

MZD_TEST_MODE="${MZD_TEST_MODE:-0}"
MZD_ROOT="${MZD_ROOT:-}"
MZD_STICK="${MZD_STICK:-}"
MZD_STICK_ID="mzd-touch-installer-v1"
MZD_INSTALLER_VERSION="1.0.1"

MZD_JCI="$MZD_ROOT/jci"
MZD_ETC="$MZD_ROOT/etc"
MZD_DATA="$MZD_ROOT/data_persist"
# Private state of this installer. The path is shared with an earlier
# version of this installer so that its backups stay usable for the removal.
MZD_TOOLS_DIR="$MZD_DATA/mzd-aa-touch"
MZD_BACKUP_ROOT="$MZD_TOOLS_DIR/backups"
MZD_REMOVED_DIR="$MZD_TOOLS_DIR/removed"
MZD_AA_DIR="$MZD_DATA/oem-aa-mod"
MZD_SM_CONF="$MZD_JCI/sm/sm.conf"
MZD_SM_WCP="$MZD_JCI/sm/sm_WCP.conf"
MZD_VERSION_INI="$MZD_JCI/version.ini"
MZD_AA_XML="$MZD_ETC/aap_system_attributes.xml"
MZD_AA_XML_UCP="$MZD_ETC/aap_system_attributes_UCP.xml"
MZD_WATCHDOG="$MZD_ROOT/sys/class/gpio/Watchdog Disable/value"
MZD_MOUNTS="$MZD_ROOT/proc/mounts"
MZD_GUARD="$MZD_ROOT/tmp/mzd-usb-installer.guard"

MZD_OPENSSL="${MZD_OPENSSL:-/usr/bin/openssl}"
[ -x "$MZD_OPENSSL" ] || MZD_OPENSSL=$(command -v openssl 2>/dev/null || true)
MZD_XMLLINT="${MZD_XMLLINT:-$MZD_ROOT/usr/bin/xmllint}"
[ -x "$MZD_XMLLINT" ] || MZD_XMLLINT=$(command -v xmllint 2>/dev/null || true)
MZD_FSYNC="${MZD_FSYNC:-/bin/fsync}"
[ -x "$MZD_FSYNC" ] || MZD_FSYNC=$(command -v fsync 2>/dev/null || true)
MZD_DBUS_SEND="${MZD_DBUS_SEND:-/usr/bin/dbus-send}"
[ -x "$MZD_DBUS_SEND" ] || MZD_DBUS_SEND=$(command -v dbus-send 2>/dev/null || true)
MZD_LOG="${MZD_LOG:-$MZD_STICK/mzd-usb.log}"

MZD_SUPPORTED_FW="74.00.324"
MZD_FW=""
MZD_FW_FLAVOR=""

MZD_ROOT_WRITABLE=0
MZD_WATCHDOG_DISABLED=0
MZD_TRANSACTION_ACTIVE=0
MZD_ROLLBACK_FN=""
MZD_STAGES=""
MZD_BACKUP_DIR=""
MZD_BACKUP_PENDING=""
MZD_BACKUP_STAMP=""
MZD_BACKUP_PREFER=""
MZD_TEST_FAULT="${MZD_TEST_FAULT:-}"
MZD_PUBLISH_COUNT=0
# Last plain popup of this process and whether a "working" popup is showing;
# mzd_popup_final turns the last one into the end message of the run.
MZD_LAST_POPUP=""
MZD_BUSY_SHOWN="${MZD_BUSY_SHOWN:-0}"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

mzd_log() {
    printf '%s\n' "[mzd-usb] $*" >&2
}

mzd_error() {
    mzd_log "ERROR: $*"
}

# ---------------------------------------------------------------------------
# On-screen dialogs (jci-dialog)
# ---------------------------------------------------------------------------

mzd_dialog_available() {
    [ -x "$MZD_JCI/tools/jci-dialog" ]
}

mzd_kill_dialogs() {
    [ "$MZD_TEST_MODE" = 1 ] && return 0
    killall -q jci-dialog 2>/dev/null || true
}

# Host tests: answer dialogs from MZD_TEST_DIALOG_SEQ ("1 0 ...", one value per
# dialog, inherited by child scripts) or from the fixed MZD_TEST_DIALOG_RC.
# Sets MZD_TEST_RC (no command substitution: the queue must shrink here).
mzd_test_dialog_next() {
    local default="$1"
    if [ -n "${MZD_TEST_DIALOG_SEQ:-}" ]; then
        MZD_TEST_RC=${MZD_TEST_DIALOG_SEQ%% *}
        if [ "$MZD_TEST_RC" = "$MZD_TEST_DIALOG_SEQ" ]; then
            MZD_TEST_DIALOG_SEQ=""
        else
            MZD_TEST_DIALOG_SEQ=${MZD_TEST_DIALOG_SEQ#* }
        fi
        export MZD_TEST_DIALOG_SEQ
        return 0
    fi
    MZD_TEST_RC="${MZD_TEST_DIALOG_RC:-$default}"
}

# Remember what the screen shows (see mzd_popup_final).
mzd_dialog_note() {
    MZD_LAST_POPUP="$1"
    MZD_BUSY_SHOWN="$2"
    export MZD_BUSY_SHOWN
}

# Non-blocking status message.
mzd_popup() {
    mzd_dialog_note "$1" 0
    if [ "$MZD_TEST_MODE" = 1 ]; then
        mzd_log "POPUP: $1"
        return 0
    fi
    mzd_dialog_available || return 0
    mzd_kill_dialogs
    "$MZD_JCI/tools/jci-dialog" --info --title="MZD Touch Installer" --text="$1" \
        --no-cancel >/dev/null 2>&1 &
}

# Non-blocking "working, do not pull the stick" message; the next dialog
# replaces it. Inherited by the payload child (MZD_BUSY_SHOWN).
mzd_popup_busy() {
    mzd_popup "$1"
    mzd_dialog_note "" 1
}

# End of a run: the last message stays on the screen. When it is a plain
# message, show it once more with the hint that the stick may be pulled now;
# a run that ends while "working" is showing gets a short end message instead.
# Restart questions and TouchTune's own messages already say it.
mzd_popup_final() {
    if [ -n "$MZD_LAST_POPUP" ]; then
        case "$MZD_LAST_POPUP" in
            *"Remove the USB"*|*"pull the stick now"*) return 0 ;;
        esac
        sync
        mzd_popup "$MZD_LAST_POPUP\n\nYou can pull the stick now."
    elif [ "$MZD_BUSY_SHOWN" = 1 ]; then
        sync
        mzd_popup "The run has ended.\nDetails: mzd-usb.log on the stick.\n\nYou can pull the stick now."
    fi
    return 0
}

# Blocking status message.
mzd_info() {
    mzd_dialog_note "" 0
    if [ "$MZD_TEST_MODE" = 1 ]; then
        mzd_log "INFO: $1"
        return 0
    fi
    mzd_dialog_available || return 0
    mzd_kill_dialogs
    "$MZD_JCI/tools/jci-dialog" --info --title="MZD Touch Installer" --text="$1" \
        --no-cancel >/dev/null 2>&1
}

# Two-button question: 0 = first button, 1 = second button.
mzd_ask2() {
    local rc
    mzd_dialog_note "" 0
    if [ "$MZD_TEST_MODE" = 1 ]; then
        mzd_test_dialog_next 1
        rc=$MZD_TEST_RC
        mzd_log "ASK2: $1 [$2|$3] -> $rc"
        return "$rc"
    fi
    mzd_dialog_available || return 1
    mzd_kill_dialogs
    "$MZD_JCI/tools/jci-dialog" --question --title="MZD Touch Installer" \
        --text="$1" --ok-label="$2" --cancel-label="$3" >/dev/null 2>&1
    rc=$?
    mzd_log "ASK2: $1 [$2|$3] -> $rc"
    case $rc in 0) return 0 ;; *) return 1 ;; esac
}

# Three-button question: 0 = first, 1 = second, 2 = third button.
mzd_ask3() {
    local rc
    mzd_dialog_note "" 0
    if [ "$MZD_TEST_MODE" = 1 ]; then
        mzd_test_dialog_next 2
        rc=$MZD_TEST_RC
        mzd_log "ASK3: $1 [$2|$3|$4] -> $rc"
        return "$rc"
    fi
    mzd_dialog_available || return 2
    mzd_kill_dialogs
    "$MZD_JCI/tools/jci-dialog" --3-button-dialog --title="MZD Touch Installer" \
        --text="$1" --ok-label="$2" --cancel-label="$3" --button3-label="$4" \
        >/dev/null 2>&1
    rc=$?
    mzd_log "ASK3: $1 [$2|$3|$4] -> $rc"
    case $rc in 0|1|2) return $rc ;; *) return 2 ;; esac
}

# ---------------------------------------------------------------------------
# Hashes, sizes, attributes
# ---------------------------------------------------------------------------

# Print the SHA-256 of a file as 64 lowercase hex characters, or return 1.
mzd_sha256_file() {
    local path="$1" out value
    [ -f "$path" ] && [ -r "$path" ] || return 1
    if [ -n "$MZD_OPENSSL" ] && [ -x "$MZD_OPENSSL" ]; then
        out=$("$MZD_OPENSSL" dgst -sha256 "$path" 2>/dev/null) || return 1
        value=${out##* }
    elif command -v sha256sum >/dev/null 2>&1; then
        out=$(sha256sum "$path" 2>/dev/null) || return 1
        value=${out%% *}
    elif command -v busybox >/dev/null 2>&1 && busybox sha256sum "$path" >/dev/null 2>&1; then
        out=$(busybox sha256sum "$path" 2>/dev/null) || return 1
        value=${out%% *}
    else
        return 1
    fi
    [ "${#value}" -eq 64 ] || return 1
    case "$value" in *[!0-9a-fA-F]*) return 1 ;; esac
    printf '%s\n' "$value" | tr 'A-F' 'a-f'
}

mzd_bytes() {
    local raw
    raw=$(wc -c <"$1" 2>/dev/null) || return 1
    raw=$(printf '%s' "$raw" | tr -d '[:space:]')
    case "$raw" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s\n' "$raw"
}

mzd_mode() {
    stat -c '%a' "$1" 2>/dev/null && return 0
    stat -f '%Lp' "$1" 2>/dev/null
}

mzd_uid() {
    stat -c '%u' "$1" 2>/dev/null && return 0
    stat -f '%u' "$1" 2>/dev/null
}

mzd_gid() {
    stat -c '%g' "$1" 2>/dev/null && return 0
    stat -f '%g' "$1" 2>/dev/null
}

mzd_real_file() {
    [ -f "$1" ] && [ ! -L "$1" ] && [ -r "$1" ]
}

mzd_real_dir() {
    [ -d "$1" ] && [ ! -L "$1" ]
}

mzd_require_file() {
    mzd_real_file "$1" || { mzd_error "file missing or not a regular file: $1"; return 1; }
}

# Canonical numeric comparison of a file mode: "644" and "0644" are equal.
mzd_mode_canon() {
    local m
    m=$(printf '%s' "$1" | sed 's/^0*//')
    [ -n "$m" ] || m=0
    printf '%s\n' "$m"
}

mzd_mode_equals() {
    local actual expected
    actual=$(mzd_mode "$1") || return 1
    expected=$(mzd_mode_canon "$2")
    [ -n "$expected" ] || return 1
    [ "$(mzd_mode_canon "$actual")" = "$expected" ]
}

# Validate an XML file with the firmware's xmllint. Refuses to continue when
# no validator is available unless MZD_ALLOW_NO_XMLLINT=1 (host tests).
mzd_validate_xml() {
    local file="$1"
    mzd_real_file "$file" || { mzd_error "XML not readable: $file"; return 1; }
    if [ -n "$MZD_XMLLINT" ] && [ -x "$MZD_XMLLINT" ]; then
        if ! "$MZD_XMLLINT" --noout "$file" 2>/dev/null; then
            mzd_error "XML is not well-formed: $file"
            return 1
        fi
        return 0
    fi
    if [ "${MZD_ALLOW_NO_XMLLINT:-0}" = 1 ]; then
        mzd_log "WARNING: no xmllint available, XML check skipped"
        return 0
    fi
    mzd_error "xmllint is missing; cannot validate XML"
    return 1
}

# ---------------------------------------------------------------------------
# Firmware
# ---------------------------------------------------------------------------

# Value of one key in version.ini (quotes and CR removed), or return 1.
mzd_version_value() {
    local key="$1" value
    mzd_real_file "$MZD_VERSION_INI" || return 1
    value=$(grep "^$key=" "$MZD_VERSION_INI" 2>/dev/null | head -n 1 | cut -d'"' -f2 | tr -d '\r')
    [ -n "$value" ] || return 1
    printf '%s\n' "$value"
}

# Print the normalized firmware version (e.g. "74.00.324A") or return 1.
# The region is not part of JCI_SW_VER; it is reported by JCI_SW_FLAVOR.
mzd_firmware() {
    local ver patch
    ver=$(mzd_version_value JCI_SW_VER | tr '[:lower:]' '[:upper:]') || return 1
    patch=$(mzd_version_value JCI_SW_VER_PATCH 2>/dev/null | tr '[:lower:]' '[:upper:]')
    [ -n "$ver" ] || return 1
    ver=${ver##*_}
    if [ -n "$patch" ]; then
        case "$ver" in
            *"$patch") ;;
            *) ver="${ver}${patch}" ;;
        esac
    fi
    printf '%s\n' "$ver"
}

# Firmware region flavor, e.g. "cmu150_EU" or "cmu150_NA" (informational).
mzd_firmware_flavor() {
    mzd_version_value JCI_SW_FLAVOR 2>/dev/null || printf 'unknown\n'
}

# Accept exactly the 74.00.324 family (base and A), any region. Sets MZD_FW.
mzd_require_firmware() {
    local fw
    if [ "$MZD_TEST_MODE" = 1 ] && [ -n "${MZD_TEST_FIRMWARE:-}" ]; then
        fw="$MZD_TEST_FIRMWARE"
    else
        if ! fw=$(mzd_firmware); then
            mzd_error "cannot read the firmware version: $MZD_VERSION_INI"
            return 1
        fi
    fi
    MZD_FW_FLAVOR=$(mzd_firmware_flavor)
    case "$fw" in
        "$MZD_SUPPORTED_FW"|"$MZD_SUPPORTED_FW"A)
            MZD_FW="$fw"
            mzd_log "firmware $fw ($MZD_FW_FLAVOR) detected (supported)"
            return 0
            ;;
        *)
            mzd_error "firmware $fw ($MZD_FW_FLAVOR) is not supported (only $MZD_SUPPORTED_FW and ${MZD_SUPPORTED_FW}A)"
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Read-only rootfs and watchdog
# ---------------------------------------------------------------------------

# The CMU stacks "rootfs" and the relfs root on "/"; /proc/mounts lists
# both and the relfs entry is the effective topmost mount. All helpers below
# use the LAST "/" entry.
mzd_root_has_option() {
    local want="$1"
    # /proc/mounts is a symlink to /proc/self/mounts on the CMU, so this must
    # not use mzd_real_file() (which rejects symlinks).
    [ -r "$MZD_MOUNTS" ] || return 1
    awk -v want="$want" '
        $2 == "/" { line = $4 }
        END {
            if (line == "") exit 1
            count = split(line, option, ",")
            for (i = 1; i <= count; i++) if (option[i] == want) exit 0
            exit 1
        }
    ' "$MZD_MOUNTS"
}

mzd_root_is_read_only() { mzd_root_has_option ro; }
mzd_root_is_writable() { mzd_root_has_option rw; }

# Print the effective "/" mount lines for the log (e.g. after a failed remount).
mzd_log_root_mounts() {
    [ -r "$MZD_MOUNTS" ] || { mzd_log "mount table not readable: $MZD_MOUNTS"; return 0; }
    awk '$2 == "/" { print "MOUNT: " $0 }' "$MZD_MOUNTS" 2>/dev/null || true
}

# Decisive write test on the root filesystem: create and remove a tiny probe
# file. This verifies the actual state independent of how /proc/mounts reports
# the options. Returns 0 when the root filesystem is writable.
mzd_root_write_probe() {
    local dir probe
    for dir in "$MZD_JCI" "$MZD_ETC" "$MZD_ROOT"; do
        [ -d "$dir" ] || continue
        probe="$dir/.mzd-write-test.$$"
        if ( : >"$probe" ) 2>/dev/null; then
            rm -f "$probe" 2>/dev/null || true
            return 0
        fi
    done
    return 1
}

# Remount the root filesystem and verify the result in /proc/mounts. With the
# stacked mounts on this unit `mount -o ro,remount /` can hit the wrong entry;
# therefore try the device explicitly first, then the mountpoint forms.
mzd_remount_root() {
    local want="$1" dev fstype out
    case "$want" in ro|rw) ;; *) return 1 ;; esac
    dev=$(awk '$2 == "/" && $1 ~ /^\/dev\// { d = $1 } END { if (d != "") print d; else exit 1 }' "$MZD_MOUNTS" 2>/dev/null || true)
    fstype=$(awk '$2 == "/" { f = $3 } END { if (f != "") print f; else exit 1 }' "$MZD_MOUNTS" 2>/dev/null || true)
    if [ -n "$dev" ]; then
        if out=$(mount -o "$want,remount" "$dev" / 2>&1); then
            mzd_root_has_option "$want" && return 0
            mzd_log "remount $dev / ($want) had no effect: ${out:-no output}"
        else
            mzd_log "remount $dev / ($want) failed: ${out:-no output}"
        fi
        if [ -n "$fstype" ]; then
            if out=$(mount -t "$fstype" -o "$want,remount" "$dev" / 2>&1); then
                mzd_root_has_option "$want" && return 0
                mzd_log "remount -t $fstype $dev / ($want) had no effect: ${out:-no output}"
            else
                mzd_log "remount -t $fstype $dev / ($want) failed: ${out:-no output}"
            fi
        fi
    fi
    if out=$(mount -o "$want,remount" / 2>&1); then
        mzd_root_has_option "$want" && return 0
        mzd_log "remount / ($want) had no effect: ${out:-no output}"
    else
        mzd_log "remount / ($want) failed: ${out:-no output}"
    fi
    if out=$(mount -o "remount,$want" / 2>&1); then
        mzd_root_has_option "$want" && return 0
        mzd_log "remount / (remount,$want) had no effect: ${out:-no output}"
    else
        mzd_log "remount / (remount,$want) failed: ${out:-no output}"
    fi
    return 1
}

mzd_watchdog_read() { tr -d '\r\n' <"$MZD_WATCHDOG" 2>/dev/null; }
mzd_watchdog_write() { printf '%s\n' "$1" >"$MZD_WATCHDOG" 2>/dev/null; }

# Make / writable and disable the hardware watchdog for the mutation window.
mzd_prepare_mutation() {
    [ "$MZD_ROOT_WRITABLE" = 0 ] || return 0
    if [ "$MZD_TEST_MODE" = 1 ]; then
        MZD_ROOT_WRITABLE=1
        return 0
    fi
    mzd_log "remounting rootfs read-write"
    if ! mzd_remount_root rw; then
        mzd_log "remount command without success; checking writability with a write test"
    fi
    if ! mzd_root_write_probe; then
        mzd_error "rootfs is not writable (write test failed)"
        mzd_log_root_mounts
        return 1
    fi
    MZD_ROOT_WRITABLE=1
    if [ -e "$MZD_WATCHDOG" ]; then
        mzd_log "disabling the watchdog for the write phase"
        if ! mzd_watchdog_write 1 || [ "$(mzd_watchdog_read)" != 1 ]; then
            mzd_watchdog_write 0 2>/dev/null || true
            mzd_error "could not disable the watchdog"
            return 1
        fi
        MZD_WATCHDOG_DISABLED=1
    else
        mzd_log "WARNING: watchdog interface not present"
    fi
    return 0
}

mzd_fsync_file() {
    if [ -n "$MZD_FSYNC" ] && [ -x "$MZD_FSYNC" ] && [ -e "$1" ]; then
        "$MZD_FSYNC" "$1" 2>/dev/null
        return $?
    fi
    if [ "$MZD_TEST_MODE" = 1 ]; then
        return 0
    fi
    sync
}

mzd_fsync_dir() {
    mzd_fsync_file "$1"
}

# Restore watchdog and read-only rootfs, then flush. Never leaves the unit in
# a half-open state silently; returns non-zero if a step could not be verified.
mzd_finalize() {
    local failures=0
    if [ "$MZD_TEST_MODE" = 1 ]; then
        MZD_ROOT_WRITABLE=0
        MZD_WATCHDOG_DISABLED=0
        sync 2>/dev/null || true
        return 0
    fi
    sync || failures=$((failures + 1))
    if [ "$MZD_ROOT_WRITABLE" = 1 ]; then
        mzd_log "remounting rootfs read-only"
        if ! mzd_remount_root ro; then
            mzd_log "remount command without success; checking writability with a write test"
        fi
        if mzd_root_write_probe; then
            mzd_error "rootfs is still writable after the remount (write test succeeded)"
            mzd_log_root_mounts
            failures=$((failures + 1))
        else
            MZD_ROOT_WRITABLE=0
        fi
    fi
    if [ "$MZD_WATCHDOG_DISABLED" = 1 ]; then
        mzd_log "re-enabling the watchdog"
        if mzd_watchdog_write 0 && [ "$(mzd_watchdog_read)" = 0 ]; then
            MZD_WATCHDOG_DISABLED=0
        else
            mzd_error "could not re-enable the watchdog"
            failures=$((failures + 1))
        fi
    fi
    sync || failures=$((failures + 1))
    [ "$failures" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Mazda SafeReboot (never a raw reboot)
# ---------------------------------------------------------------------------

mzd_safe_reboot() {
    local reply status
    if [ "$MZD_TEST_MODE" = 1 ]; then
        mzd_log "TEST: SafeReboot would be requested now"
        return 0
    fi
    if [ -z "$MZD_DBUS_SEND" ] || [ ! -x "$MZD_DBUS_SEND" ]; then
        mzd_error "dbus-send is missing; SafeReboot not possible"
        return 1
    fi
    reply=$("$MZD_DBUS_SEND" --address=unix:path=/tmp/dbus_service_socket \
        --print-reply --reply-timeout=5000 --type=method_call \
        --dest=com.jci.blm.system /com/jci/blm/system \
        com.jci.blmsystem.Interface.SafeReboot 2>&1) || {
        mzd_error "SafeReboot call failed: $reply"
        return 1
    }
    status=$(printf '%s\n' "$reply" | awk '$1 == "int32" { print $2; exit }')
    if [ "$status" != "100" ]; then
        mzd_error "SafeReboot returned status ${status:-?} (expected 100)"
        return 1
    fi
    mzd_log "Mazda SafeReboot accepted"
    return 0
}

# Ask the user to restart; returns 0 unless a requested restart failed.
# MZD_SKIP_REBOOT=1 suppresses the dialog and the restart (combined run: a later
# step, TouchTune, owns the single final SafeReboot).
mzd_ask_reboot() {
    local rc
    if [ "${MZD_SKIP_REBOOT:-0}" = 1 ]; then
        mzd_log "restart deferred (MZD_SKIP_REBOOT=1); a later step requests it"
        return 0
    fi
    mzd_ask2 "$1\n\nRemove the USB stick.\nRestart Mazda Connect now?" "Restart now" "Later"
    rc=$?
    case $rc in
        0) mzd_safe_reboot ;;
        *) mzd_log "restart deferred by the user"; return 0 ;;
    esac
}

# ---------------------------------------------------------------------------
# Staged writes: stage beside the destination, publish by rename, read back
# ---------------------------------------------------------------------------

mzd_discard_stage() {
    local path="$1"
    [ -n "$path" ] || return 0
    if [ -e "$path" ] || [ -L "$path" ]; then
        chmod u+w "$path" 2>/dev/null || true
        rm -f "$path" || { mzd_error "cannot remove stage file: $path"; return 1; }
    fi
    case " $MZD_STAGES " in
        *" $path "*) MZD_STAGES=$(printf '%s\n' "$MZD_STAGES" | tr ' ' '\n' | awk -v p="$path" '$0 != "" && $0 != p' | tr '\n' ' ') ;;
    esac
    return 0
}

mzd_discard_stages() {
    local failures=0 path
    for path in $MZD_STAGES; do
        mzd_discard_stage "$path" || failures=$((failures + 1))
    done
    MZD_STAGES=""
    return "$failures"
}

# mzd_stage_copy <source> <destination> <expected-sha256>
# Builds <destination>.mzd-new with the destination's attributes (or 0644
# root:root for a new file), verifies the digest and flushes it. No live file
# is touched yet.
mzd_stage_copy() {
    local src="$1" dest="$2" expected="$3" candidate candidate_sha mode uid gid
    mzd_require_file "$src" || return 1
    candidate="$dest.mzd-new"
    mzd_discard_stage "$candidate" || return 1
    mkdir -p "$(dirname "$dest")" || { mzd_error "cannot create the target directory: $dest"; return 1; }
    mzd_fault stage-write-fail && { mzd_error "TEST: injected stage write error"; return 1; }
    if ! cp "$src" "$candidate"; then
        mzd_error "copy to stage failed: $candidate"
        return 1
    fi
    if [ -e "$dest" ]; then
        mode=$(mzd_mode "$dest"); uid=$(mzd_uid "$dest"); gid=$(mzd_gid "$dest")
    else
        mode=644; uid=0; gid=0
    fi
    chmod "$mode" "$candidate" || { mzd_error "chmod of the stage file failed: $candidate"; return 1; }
    if [ "$MZD_TEST_MODE" != 1 ]; then
        chown "$uid:$gid" "$candidate" 2>/dev/null || {
            mzd_error "chown of the stage file failed: $candidate"
            return 1
        }
    fi
    candidate_sha=$(mzd_sha256_file "$candidate") || {
        mzd_error "cannot hash the stage file: $candidate"
        return 1
    }
    if [ "$candidate_sha" != "$expected" ]; then
        mzd_error "stage hash differs: $candidate (is $candidate_sha, expected $expected)"
        return 1
    fi
    mzd_fsync_file "$candidate" || { mzd_error "fsync of the stage file failed: $candidate"; return 1; }
    MZD_STAGES="$MZD_STAGES $candidate"
    return 0
}

# mzd_publish_staged <destination> <expected-sha256> [mode] [uid] [gid]
# Atomically renames the staged file over the destination and verifies content
# and attributes afterwards.
mzd_publish_staged() {
    local dest="$1" expected="$2" mode="${3:-}" uid="${4:-}" gid="${5:-}" candidate actual
    candidate="$dest.mzd-new"
    [ -f "$candidate" ] || { mzd_error "stage file missing: $candidate"; return 1; }
    MZD_PUBLISH_COUNT=$((MZD_PUBLISH_COUNT + 1))
    if [ "$MZD_TEST_MODE" = 1 ] && [ "${MZD_TEST_FAULT:-}" = publish-fail-late ] && \
       [ "$MZD_PUBLISH_COUNT" -ge 6 ]; then
        MZD_TEST_FAULT=""
        mzd_error "TEST: injected late publish error"
        return 1
    fi
    mzd_fault interrupt-before-publish
    mzd_fault publish-fail && { mzd_error "TEST: injected publish error"; return 1; }
    if [ -z "$mode" ]; then mode=$(mzd_mode "$candidate"); fi
    if [ -z "$uid" ]; then uid=$(mzd_uid "$candidate"); fi
    if [ -z "$gid" ]; then gid=$(mzd_gid "$candidate"); fi
    if ! mv -f "$candidate" "$dest"; then
        mzd_error "atomic rename failed: $dest"
        return 1
    fi
    mzd_discard_stage "$candidate" >/dev/null 2>&1 || true
    mzd_fsync_dir "$(dirname "$dest")" || {
        mzd_error "fsync of the target directory failed: $dest"
        return 1
    }
    mzd_fault readback-fail && { mzd_error "TEST: injected readback error"; return 1; }
    actual=$(mzd_sha256_file "$dest") || {
        mzd_error "cannot hash the published file: $dest"
        return 1
    }
    if [ "$actual" != "$expected" ]; then
        mzd_error "readback hash differs: $dest (is $actual, expected $expected)"
        return 1
    fi
    if ! mzd_mode_equals "$dest" "$mode"; then
        mzd_error "readback mode differs: $dest (is $(mzd_mode "$dest"), expected $mode)"
        return 1
    fi
    if [ "$MZD_TEST_MODE" != 1 ]; then
        if [ "$(mzd_uid "$dest")" != "$uid" ] || [ "$(mzd_gid "$dest")" != "$gid" ]; then
            mzd_error "readback owner differs: $dest (is $(mzd_uid "$dest"):$(mzd_gid "$dest"), expected $uid:$gid)"
            return 1
        fi
    fi
    return 0
}

# mzd_stage_verify_conf <candidate> <original> <file-with-added-lines>
# Proves that exactly the intended line(s) were added: removes them again and
# compares with the original; also validates the XML.
mzd_stage_verify_conf() {
    local candidate="$1" original="$2" added_lines="$3" tmp line
    mzd_validate_xml "$candidate" || return 1
    mzd_real_file "$added_lines" || { mzd_error "list of inserted lines is missing"; return 1; }
    tmp="$candidate.mzd-verify"
    cp "$candidate" "$tmp" || { mzd_error "verification copy failed"; return 1; }
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        awk -v line="$line" '$0 != line { print }' "$tmp" >"$tmp.next" || {
            mzd_error "verification of the configuration change failed"
            rm -f "$tmp" "$tmp.next"
            return 1
        }
        mv -f "$tmp.next" "$tmp" || return 1
    done <"$added_lines"
    if [ "$(mzd_sha256_file "$original")" != "$(mzd_sha256_file "$tmp")" ]; then
        mzd_error "configuration change contains unexpected differences: $candidate"
        rm -f "$tmp"
        return 1
    fi
    rm -f "$tmp"
    return 0
}

# ---------------------------------------------------------------------------
# Write-once backups under /data_persist/mzd-aa-touch/backups/<stamp>/
# ---------------------------------------------------------------------------

mzd_backup_begin() {
    local label="$1" stamp
    [ "$MZD_TRANSACTION_ACTIVE" = 0 ] || { mzd_error "no backup allowed during an active transaction"; return 1; }
    [ -n "$label" ] || label=mzd
    if ! mkdir -p "$MZD_BACKUP_ROOT"; then
        mzd_error "cannot create the backup directory: $MZD_BACKUP_ROOT"
        return 1
    fi
    # The CMU clock starts at 1970 on every boot, so the stamp is an uptime,
    # not a date; mzd_backup_find does not rely on its order alone.
    if [ "$MZD_TEST_MODE" = 1 ] && [ -n "${MZD_TEST_STAMP:-}" ]; then
        stamp="$MZD_TEST_STAMP"
    else
        stamp=$(mzd_stamp)
    fi
    MZD_BACKUP_STAMP="$stamp"
    MZD_BACKUP_PENDING="$MZD_BACKUP_ROOT/.pending-$$-$stamp"
    rm -rf "$MZD_BACKUP_PENDING" 2>/dev/null || true
    if ! mkdir "$MZD_BACKUP_PENDING"; then
        mzd_error "cannot create the pending backup: $MZD_BACKUP_PENDING"
        MZD_BACKUP_PENDING=""
        return 1
    fi
    printf 'format=mzd-aa-touch-backup-v1\nlabel=%s\ncreated=%s\ninstaller=%s\nfirmware=%s\n' \
        "$label" "$stamp" "$MZD_INSTALLER_VERSION" "${MZD_FW:-unknown}" >"$MZD_BACKUP_PENDING/metadata" || return 1
    : >"$MZD_BACKUP_PENDING/index" || return 1
    mzd_log "backup started: $MZD_BACKUP_PENDING"
    return 0
}

# mzd_backup_add <source> <name>
# Copies a live file into the pending backup and records hash, bytes, attrs.
mzd_backup_add() {
    local src="$1" name="$2" sha bytes mode uid gid
    [ -n "$MZD_BACKUP_PENDING" ] || { mzd_error "no backup in progress"; return 1; }
    mzd_require_file "$src" || return 1
    mzd_fault backup-write-fail && { mzd_error "TEST: injected backup write error"; return 1; }
    cp -p "$src" "$MZD_BACKUP_PENDING/$name" || { mzd_error "backup copy failed: $name"; return 1; }
    sha=$(mzd_sha256_file "$src") || { mzd_error "cannot hash the source: $src"; return 1; }
    bytes=$(mzd_bytes "$src") || return 1
    mode=$(mzd_mode "$src") || return 1
    uid=$(mzd_uid "$src") || return 1
    gid=$(mzd_gid "$src") || return 1
    chmod 0444 "$MZD_BACKUP_PENDING/$name" 2>/dev/null || true
    printf '%s|%s|%s|%s|%s|%s|%s\n' "$name" "$sha" "$bytes" "$mode" "$uid" "$gid" "$src" \
        >>"$MZD_BACKUP_PENDING/index" || return 1
    mzd_log "backed up: $name ($sha)"
    return 0
}

mzd_backup_publish() {
    local target meta_digest n
    [ -n "$MZD_BACKUP_PENDING" ] || { mzd_error "no backup in progress"; return 1; }
    [ -n "${MZD_BACKUP_STAMP:-}" ] || { mzd_error "backup timestamp missing"; return 1; }
    cat "$MZD_BACKUP_PENDING/index" >>"$MZD_BACKUP_PENDING/metadata" || return 1
    meta_digest=$(mzd_sha256_file "$MZD_BACKUP_PENDING/metadata") || return 1
    printf '%s  metadata\n' "$meta_digest" >"$MZD_BACKUP_PENDING/metadata.sha256" || return 1
    chmod 0444 "$MZD_BACKUP_PENDING/metadata" "$MZD_BACKUP_PENDING/metadata.sha256" 2>/dev/null || true
    mzd_fault backup-write-fail && { mzd_error "TEST: injected backup write error"; return 1; }
    mzd_fsync_file "$MZD_BACKUP_PENDING/metadata" || return 1
    mzd_fsync_file "$MZD_BACKUP_PENDING/metadata.sha256" || return 1
    chmod 0755 "$MZD_BACKUP_PENDING" || return 1
    # Two runs in the same second after boot get the same stamp; add a suffix.
    target="$MZD_BACKUP_ROOT/$MZD_BACKUP_STAMP"
    n=2
    while [ -e "$target" ] || [ -L "$target" ]; do
        if [ "$n" -gt 99 ]; then
            mzd_error "backup target already exists: $target"
            return 1
        fi
        target="$MZD_BACKUP_ROOT/$MZD_BACKUP_STAMP-$n"
        n=$((n + 1))
    done
    if ! mv "$MZD_BACKUP_PENDING" "$target"; then
        mzd_error "could not publish the backup: $target"
        return 1
    fi
    MZD_BACKUP_DIR="$target"
    MZD_BACKUP_PENDING=""
    mzd_fsync_dir "$MZD_BACKUP_ROOT" || return 1
    mzd_backup_validate "$target" || {
        mzd_error "published backup is invalid: $target"
        return 1
    }
    mzd_log "backup published and verified: $target"
    return 0
}

# Validate a backup directory: metadata digest, every file hash and size.
mzd_backup_validate() {
    local dir="${1:-$MZD_BACKUP_DIR}" name sha bytes mode uid gid src
    local failures=0 meta_digest
    mzd_real_dir "$dir" || { mzd_error "backup directory missing: $dir"; return 1; }
    mzd_require_file "$dir/metadata" || return 1
    mzd_require_file "$dir/metadata.sha256" || return 1
    read -r meta_digest _ <"$dir/metadata.sha256" || return 1
    [ "$(mzd_sha256_file "$dir/metadata")" = "$meta_digest" ] || {
        mzd_error "backup metadata does not match metadata.sha256"
        return 1
    }
    grep -q '^format=mzd-aa-touch-backup-v1$' "$dir/metadata" || {
        mzd_error "unknown backup format: $dir"
        return 1
    }
    grep -q '^label=' "$dir/metadata" || return 1
    grep -q '^created=' "$dir/metadata" || return 1
    while IFS='|' read -r name sha bytes mode uid gid src; do
        case "$name" in
            ''|'#'*) continue ;;
            format=mzd-aa-touch-backup-v1|label=*|created=*|installer=*|firmware=*) continue ;;
        esac
        if ! mzd_real_file "$dir/$name"; then
            mzd_error "backup file missing: $dir/$name"
            failures=$((failures + 1))
            continue
        fi
        [ "$(mzd_sha256_file "$dir/$name")" = "$sha" ] || {
            mzd_error "backup file hash differs: $name"
            failures=$((failures + 1))
        }
        [ "$(mzd_bytes "$dir/$name")" = "$bytes" ] || {
            mzd_error "backup file size differs: $name"
            failures=$((failures + 1))
        }
        # Content integrity is what matters here; the recorded mode/uid/gid are
        # restored and verified when the backup is written back.
    done <"$dir/metadata"
    [ "$failures" -eq 0 ]
}

# mzd_backup_usable <dir> <label_prefix>: valid and (with a prefix) ours.
mzd_backup_usable() {
    local dir="$1" label_prefix="$2"
    mzd_backup_validate "$dir" >/dev/null 2>&1 || return 1
    if [ -n "$label_prefix" ] && ! grep -q "^label=$label_prefix" "$dir/metadata" 2>/dev/null; then
        mzd_log "backup ignored (foreign label): $dir"
        return 1
    fi
    return 0
}

# Pick a valid backup; sets MZD_BACKUP_DIR. With a label prefix only backups
# written by this installer are accepted (e.g. "aa-touch-").
# The CMU clock restarts at 1970 on every boot, so the stamp order says nothing
# about age. Order of preference:
#   1. MZD_BACKUP_PREFER (basename recorded by the install that is in place)
#   2. the highest stamp taken on the running firmware (MZD_FW)
#   3. the highest stamp of any firmware
mzd_backup_find() {
    local label_prefix="${1:-}" dir fw list
    MZD_BACKUP_DIR=""
    mzd_real_dir "$MZD_BACKUP_ROOT" || return 1
    case "$MZD_BACKUP_PREFER" in
        ''|*/*|.*) ;;
        *)
            dir="$MZD_BACKUP_ROOT/$MZD_BACKUP_PREFER"
            if mzd_backup_usable "$dir" "$label_prefix"; then
                MZD_BACKUP_DIR="$dir"
                return 0
            fi
            mzd_log "recorded backup not usable, searching: $dir"
            ;;
    esac
    list=$(ls -1d "$MZD_BACKUP_ROOT"/[0-9]* 2>/dev/null | sort -r)
    if [ -n "$MZD_FW" ]; then
        for dir in $list; do
            fw=$(mzd_backup_meta_value firmware "$dir" 2>/dev/null) || continue
            [ "$fw" = "$MZD_FW" ] || continue
            if mzd_backup_usable "$dir" "$label_prefix"; then
                MZD_BACKUP_DIR="$dir"
                return 0
            fi
        done
    fi
    for dir in $list; do
        if mzd_backup_usable "$dir" "$label_prefix"; then
            MZD_BACKUP_DIR="$dir"
            return 0
        fi
    done
    return 1
}

# Look up a record in the backup metadata (name -> "sha|bytes|mode|uid|gid|src").
mzd_backup_record() {
    local name="$1" dir="${2:-$MZD_BACKUP_DIR}"
    awk -F'|' -v n="$name" '$1 == n { print $2"|"$3"|"$4"|"$5"|"$6"|"$7; exit }' "$dir/metadata"
}

# Read a metadata key from a backup directory (e.g. the firmware it was taken on).
mzd_backup_meta_value() {
    local key="$1" dir="${2:-$MZD_BACKUP_DIR}"
    [ -n "$dir" ] && [ -f "$dir/metadata" ] || return 1
    awk -v k="$key" '
        index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }
    ' "$dir/metadata"
}

mzd_backup_restore_stage() {
    local name="$1" dest="$2" rec sha bytes mode uid gid src
    [ -n "$MZD_BACKUP_DIR" ] || { mzd_error "no backup available"; return 1; }
    rec=$(mzd_backup_record "$name") || true
    [ -n "$rec" ] || { mzd_error "backup does not contain $name"; return 1; }
    IFS='|' read -r sha bytes mode uid gid src <<EOF
$rec
EOF
    mzd_require_file "$MZD_BACKUP_DIR/$name" || return 1
    mzd_stage_copy "$MZD_BACKUP_DIR/$name" "$dest" "$sha" || return 1
    chmod "$mode" "$dest.mzd-new" || return 1
    if [ "$MZD_TEST_MODE" != 1 ]; then
        chown "$uid:$gid" "$dest.mzd-new" 2>/dev/null || return 1
    fi
    return 0
}

# Copy the published backup to the stick for the owner (best effort).
mzd_backup_copy_to_stick() {
    local target
    [ -n "$MZD_STICK" ] && [ -d "$MZD_STICK" ] || return 0
    [ -n "$MZD_BACKUP_DIR" ] || return 0
    target="$MZD_STICK/backup-aa-touch-$(basename "$MZD_BACKUP_DIR")"
    if [ -e "$target" ]; then
        mzd_log "USB backup copy already exists: $target"
        return 0
    fi
    if cp -a "$MZD_BACKUP_DIR" "$target" 2>/dev/null; then
        mzd_log "backup copied to USB: $target"
        if [ "$MZD_TEST_MODE" != 1 ]; then sync; fi
        return 0
    fi
    mzd_log "WARNING: backup copy to USB failed"
    return 0
}

# ---------------------------------------------------------------------------
# Fault injection (host tests only)
# ---------------------------------------------------------------------------

# Returns 0 when the fault is injected (caller fails), 1 when it is not.
mzd_fault() {
    [ "$MZD_TEST_MODE" = 1 ] || return 1
    [ "${MZD_TEST_FAULT:-}" = "$1" ] || return 1
    mzd_log "TEST: fault '$1' triggered"
    case "$1" in
        interrupt-before-publish)
            MZD_TEST_FAULT=""
            mzd_cleanup 97
            ;;
        exit-after-backup)
            MZD_TEST_FAULT=""
            exit 97
            ;;
        *)
            # Fail-type faults fire once; the rollback path must be able to run.
            MZD_TEST_FAULT=""
            return 0
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Cleanup and trap handling
# ---------------------------------------------------------------------------

# Call once at installer start; installs the exit/hangup/interrupt traps.
mzd_install_traps() {
    trap mzd_cleanup 0
    trap 'mzd_log "HUP received"; exit 129' HUP
    trap 'mzd_log "INT received"; exit 130' INT
    trap 'mzd_log "TERM received"; exit 143' TERM
}

mzd_cleanup() {
    local status="${1:-$?}" failures=0
    trap - 0 HUP INT TERM
    if [ "$MZD_TRANSACTION_ACTIVE" = 1 ] && [ -n "$MZD_ROLLBACK_FN" ]; then
        mzd_log "transaction active: rollback via $MZD_ROLLBACK_FN"
        if ! "$MZD_ROLLBACK_FN"; then
            mzd_error "rollback could not be completely verified"
            failures=$((failures + 1))
        fi
        MZD_TRANSACTION_ACTIVE=0
        MZD_ROLLBACK_FN=""
    fi
    mzd_discard_stages || failures=$((failures + 1))
    if ! mzd_finalize; then
        failures=$((failures + 1))
    fi
    if [ -n "$MZD_BACKUP_PENDING" ] && [ -d "$MZD_BACKUP_PENDING" ]; then
        rm -rf "$MZD_BACKUP_PENDING" 2>/dev/null || true
    fi
    if [ "${MZD_GUARD_OWNER:-0}" = 1 ]; then rmdir "$MZD_GUARD" 2>/dev/null || true; fi
    if [ "$MZD_TEST_MODE" != 1 ]; then sync 2>/dev/null || true; fi
    if [ "$failures" -ne 0 ] && [ "$status" -eq 0 ]; then
        status=1
    fi
    mzd_log "end (status $status)"
    exit "$status"
}

# Guard directory against a second concurrent installer run.
mzd_guard() {
    local parent now then age max_age
    parent=$(dirname "$MZD_GUARD")
    if [ ! -d "$parent" ]; then
        mkdir -p "$parent" 2>/dev/null || {
            mzd_error "cannot create the guard parent directory: $parent"
            return 1
        }
    fi
    if [ -e "$MZD_GUARD" ] || [ -L "$MZD_GUARD" ]; then
        max_age="${MZD_GUARD_MAX_AGE_S:-900}"
        now=$(date -u +%s 2>/dev/null || echo 0)
        then=$(stat -c '%Y' "$MZD_GUARD" 2>/dev/null || echo 0)
        age=0
        [ "$now" -gt 0 ] && [ "$then" -gt 0 ] && age=$((now - then))
        if [ "$then" -gt 0 ] && [ "$age" -gt "$max_age" ]; then
            mzd_log "WARNING: removing the stale guard of an interrupted run ($age s): $MZD_GUARD"
            rm -rf "$MZD_GUARD" 2>/dev/null || true
        else
            mzd_error "another installer run is active (guard: $MZD_GUARD). After a power loss: wait for a restart."
            return 1
        fi
    fi
    mkdir "$MZD_GUARD" 2>/dev/null || {
        mzd_error "cannot create the guard directory: $MZD_GUARD"
        return 1
    }
    return 0
}

# ---------------------------------------------------------------------------
# Small helpers shared by the transactions
# ---------------------------------------------------------------------------

# Number of exact whole-line matches in a file. Implemented with awk because
# the target BusyBox grep may lack -x.
mzd_count_line() {
    local file="$1" line="$2"
    mzd_real_file "$file" || { printf '0\n'; return 0; }
    awk -v line="$line" '$0 == line { n++ } END { printf "%d\n", n + 0 }' "$file" 2>/dev/null || printf '0\n'
}

# Parse "key = value" from a libpatch.conf-style file (comments stripped).
mzd_conf_value() {
    local file="$1" key="$2" val
    mzd_real_file "$file" || return 1
    val=$(sed 's/#.*//' "$file" 2>/dev/null | grep -i "^[[:space:]]*$key[[:space:]]*=" | tail -n1 | cut -d'=' -f2- | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    [ -n "$val" ] || return 1
    printf '%s\n' "$val"
}

# Boolean parser used for libpatch.conf values.
mzd_conf_bool() {
    case "$1" in
        true|1|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

# UTC timestamp usable in filenames.
mzd_stamp() {
    date -u +%Y%m%dT%H%M%SZ
}
