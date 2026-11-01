#!/bin/sh
# aa-touch.sh -- Android Auto touch for Mazda Connect 74.00.324/324A.
#
# Installs the community "oem-aa-mod" by VitaliyKurokhtin
# (https://github.com/VitaliyKurokhtin/oem-aa-mod, AGPL-3.0): its shims
# unmodified, its libpatch.conf with one line changed (use_protocol_v1_6 =
# false: the car keeps offering Android Auto 1.5, so wireless adapters still
# get their Bluetooth pairing request), and its touch-screen entries added to
# the car's own AA XML (see aa_xml_patch), with these safety properties:
#
#   - the complete oem-aa-mod payload on the stick is hash-verified first
#   - a verified, write-once backup of the four files it changes is taken
#     ON THE CAR before the first write (/data_persist/mzd-aa-touch/backups/);
#     no Mazda file is shipped on the stick, the removal uses this backup
#   - every file is staged beside its target, validated (XML via xmllint,
#     sm.conf via re-removal comparison), flushed and atomically renamed
#   - every published file is read back and verified
#   - any failure rolls back to the recorded state
#   - removal restores exactly the recorded files, byte for byte
#   - an older installation of this installer (1.0.0 with Android Auto 1.6,
#     or an early build that copied the oem-aa-mod XMLs) is recognized and
#     updated in place from the backup it took (state "outdated")
#
# What it changes:
#   /data_persist/oem-aa-mod/libpatch-*.so + libpatch.conf  (the shims)
#   /jci/sm/sm.conf and /jci/sm/sm_WCP.conf  (LD_PRELOAD per <service>)
#   /etc/aap_system_attributes.xml and ..._UCP.xml  (touch_screen device,
#     MEDIA_PAUSE key, navigation subscription; video settings untouched)
#
# Copyright (C) 2026 caeptncrack
# SPDX-License-Identifier: GPL-3.0-or-later

[ -n "${MZD_AA_TOUCH_LOADED:-}" ] && return 0
MZD_AA_TOUCH_LOADED=1

: "${MZD_STICK:?MZD_STICK must be set}"
MZD_AA_SRC="$MZD_STICK/aa-mod"
MZD_AA_STATE_MARKER="$MZD_AA_DIR/install-state"

# Reference build this installer was tested on in a car: EU 74.00.324A
# (cmu150_EU). Other builds (e.g. North America) are accepted; these values
# only decide whether the user is told that the build differs.
MZD_AA_TESTED_BLM_SHA="10e7235bfce075b44c1a8ffc99bbc9b63af85d9262df868ca1874ec36d8d3b71"
MZD_AA_TESTED_NAVI_SHA="be72c69876d0f3e922c22b3d8df8e6671bfd5d9875795d94c67b4175f16f422d"
MZD_AA_TESTED_AAP_SHA="a0187afab34eaf0e0fb84db6974162465004ad1227ad7866eeb15ac7672546cd"
MZD_AA_TESTED_SM_SHA="fa3484d7c644393ab6cb083990e483201129a207e7755459296dde8ec82a4d84"
MZD_AA_TESTED_SMWCP_SHA="92034449e76689b995fcd369d584f441829a0ee6e8d74c858cd92f4049f7b27d"
MZD_AA_TESTED_XML_SHA="bc852037615dcb4e4eb24ab6f30a2e6f817fe00a22a2f767478b25f75b036812"
MZD_AA_TESTED_XMLUCP_SHA="6a59ae58b903af4a943dfc2cd94560128b2d42f3d097c8c82d43b5d899c17063"

AA_MOD_VERSION=""
AA_V16=0
AA_PROFILE=""

AA_LIBS=""
AA_SERVICES=""
AA_HASH_BLM=""
AA_HASH_NAVI=""
AA_HASH_AAP=""
AA_HASH_CONF=""
AA_HASH_XML=""
AA_HASH_XML_UCP=""
AA_STATE=""
AA_STATE_REASON=""
AA_BINARIES_KNOWN=0

# ---------------------------------------------------------------------------
# Payload recognition and verification
# ---------------------------------------------------------------------------

aa_mod_version() {
    local f="$MZD_AA_SRC/VERSION" v
    mzd_real_file "$f" || return 1
    v=$(tr -d '\r\n' <"$f")
    case "$v" in ''|*[!0-9A-Za-z.-]*) return 1 ;; esac
    printf '%s\n' "$v"
}

# Read use_protocol_v1_6 from the libpatch.conf that will be deployed.
# Missing file or key means the upstream default "false". The oem-aa-mod
# release ships "true"; this installer ships "false" (installer 1.0.0 shipped
# "true": with 1.6 a wireless phone skips the Bluetooth pairing request that
# Mazda Connect waits for, so adapters only worked through a workaround).
aa_read_protocol_v16() {
    local val
    if ! val=$(mzd_conf_value "$MZD_AA_SRC/libpatch.conf" use_protocol_v1_6); then
        AA_V16=0
        return 0
    fi
    if mzd_conf_bool "$val"; then AA_V16=1; else AA_V16=0; fi
    mzd_log "libpatch.conf: use_protocol_v1_6=$val -> aap_service shim $([ "$AA_V16" = 1 ] && echo active || echo inactive)"
    return 0
}

# Profile from the hash-verified libpatch.conf:
#   A = this installer: blmjciaapa + svcjcinavi, no aap_service (GAL 1.5)
#   B = with GAL 1.6: all three shims/services (oem-aa-mod release default,
#       installer 1.0.0)
aa_read_profile() {
    AA_PROFILE=""
    if ! mzd_real_file "$MZD_AA_SRC/libpatch.conf"; then
        mzd_error "aa-mod/libpatch.conf is missing on the stick"
        return 1
    fi
    if [ "$AA_V16" = 1 ]; then AA_PROFILE=B; else AA_PROFILE=A; fi
    mzd_log "AA profile: $AA_PROFILE (use_protocol_v1_6=$AA_V16)"
    return 0
}

aa_expected_libs() {
    printf '%s\n' libpatch-blmjciaapa.so libpatch-svcjcinavi.so
    [ "$AA_V16" = 1 ] && printf '%s\n' libpatch-aap_service.so
    return 0
}

aa_expected_services() {
    printf '%s\n' jciAAPA jcinavi
    [ "$AA_V16" = 1 ] && printf '%s\n' aap_service
    return 0
}

# Hash lookup for one file in an oem-aa-mod style SHA256SUMS file.
aa_sum_lookup() {
    local sums="$1" name="$2"
    awk -v n="$name" '
        {
            f = $2
            sub(/^\*/, "", f)
            sub(/^\.\//, "", f)
            if (f == n) { print $1; exit }
        }
    ' "$sums"
}

# Verify one oem-aa-mod source file against aa-mod/SHA256SUMS.
aa_verify_source_file() {
    local name="$1" sums="$MZD_AA_SRC/SHA256SUMS" expected actual
    mzd_real_file "$MZD_AA_SRC/$name" || { mzd_error "aa-mod/$name is missing on the stick"; return 1; }
    expected=$(aa_sum_lookup "$sums" "$name")
    [ -n "$expected" ] || { mzd_error "aa-mod/$name is missing in aa-mod/SHA256SUMS"; return 1; }
    actual=$(mzd_sha256_file "$MZD_AA_SRC/$name") || { mzd_error "aa-mod/$name is not readable"; return 1; }
    [ "$actual" = "$expected" ] || {
        mzd_error "aa-mod/$name hash differs (is $actual, expected $expected)"
        return 1
    }
    return 0
}

# Verify every required oem-aa-mod file against aa-mod/SHA256SUMS. In profile A
# the release bundle still contains the (unused) aap_service shim; it is
# verified too but not installed.
aa_verify_payload() {
    local sums="$MZD_AA_SRC/SHA256SUMS" name libs
    mzd_real_dir "$MZD_AA_SRC" || { mzd_error "aa-mod folder is missing on the stick"; return 1; }
    mzd_require_file "$sums" || return 1
    AA_MOD_VERSION=$(aa_mod_version) || {
        mzd_error "aa-mod/VERSION is missing or invalid"
        return 1
    }
    aa_read_protocol_v16
    aa_read_profile || return 1
    libs=$(aa_expected_libs)
    for name in $libs libpatch.conf aap_system_attributes.xml aap_system_attributes_UCP.xml; do
        aa_verify_source_file "$name" || return 1
    done
    for name in libpatch-blmjciaapa.so libpatch-svcjcinavi.so libpatch-aap_service.so; do
        [ -f "$MZD_AA_SRC/$name" ] || continue
        aa_verify_source_file "$name" || return 1
    done
    # No unexpected shim on the stick: refuse a mixed or tampered payload.
    for name in "$MZD_AA_SRC"/libpatch-*.so; do
        [ -e "$name" ] || continue
        case "$(basename "$name")" in
            libpatch-blmjciaapa.so|libpatch-svcjcinavi.so|libpatch-aap_service.so) ;;
            *) mzd_error "unexpected shim on the stick: $(basename "$name")"; return 1 ;;
        esac
    done
    AA_HASH_BLM=$(mzd_sha256_file "$MZD_AA_SRC/libpatch-blmjciaapa.so")
    AA_HASH_NAVI=$(mzd_sha256_file "$MZD_AA_SRC/libpatch-svcjcinavi.so")
    AA_HASH_CONF=$(mzd_sha256_file "$MZD_AA_SRC/libpatch.conf")
    AA_HASH_XML=$(mzd_sha256_file "$MZD_AA_SRC/aap_system_attributes.xml")
    AA_HASH_XML_UCP=$(mzd_sha256_file "$MZD_AA_SRC/aap_system_attributes_UCP.xml")
    AA_HASH_AAP=""
    if [ -f "$MZD_AA_SRC/libpatch-aap_service.so" ]; then
        AA_HASH_AAP=$(mzd_sha256_file "$MZD_AA_SRC/libpatch-aap_service.so")
    fi
    AA_LIBS="$libs"
    AA_SERVICES=$(aa_expected_services)
    mzd_log "oem-aa-mod $AA_MOD_VERSION completely verified (profile $AA_PROFILE, GAL 1.6 shim: $([ "$AA_V16" = 1 ] && echo yes || echo no))"
    return 0
}

# ---------------------------------------------------------------------------
# State recognition: clean | ours | outdated | partial | foreign | broken
# ---------------------------------------------------------------------------

aa_expected_line() {
    printf '            <environ_var env_name="LD_PRELOAD" env_value="/data_persist/oem-aa-mod/%s"/>' "$1"
}

aa_conf_marker_count() {
    local conf="$1"
    mzd_real_file "$conf" || { printf '0\n'; return 0; }
    grep -c 'env_value="/data_persist/oem-aa-mod/' "$conf" 2>/dev/null || true
}

aa_conf_has_foreign_markers() {
    local conf="$1" line
    mzd_real_file "$conf" || return 1
    # ANY environ_var / LD_PRELOAD line that is not exactly one of our three
    # canonical lines is a foreign modification (other mod, other path, other
    # formatting). It is never adopted, backed up or restored as factory state.
    while IFS= read -r line; do
        case "$line" in
            *environ_var*|*LD_PRELOAD*)
                case "$line" in
                    '            <environ_var env_name="LD_PRELOAD" env_value="/data_persist/oem-aa-mod/libpatch-blmjciaapa.so"/>') ;;
                    '            <environ_var env_name="LD_PRELOAD" env_value="/data_persist/oem-aa-mod/libpatch-svcjcinavi.so"/>') ;;
                    '            <environ_var env_name="LD_PRELOAD" env_value="/data_persist/oem-aa-mod/libpatch-aap_service.so"/>') ;;
                    *) return 0 ;;
                esac
                ;;
        esac
    done <"$conf"
    return 1
}

# SHA-256 of one of the four files in the tested EU build (informational).
aa_tested_hash() {
    case "$1" in
        sm.conf) printf '%s\n' "$MZD_AA_TESTED_SM_SHA" ;;
        sm_WCP.conf) printf '%s\n' "$MZD_AA_TESTED_SMWCP_SHA" ;;
        aap_system_attributes.xml) printf '%s\n' "$MZD_AA_TESTED_XML_SHA" ;;
        aap_system_attributes_UCP.xml) printf '%s\n' "$MZD_AA_TESTED_XMLUCP_SHA" ;;
        *) return 1 ;;
    esac
}

# Log whether the four live files equal the tested EU build. A difference is
# normal on other regions; the files are backed up exactly as found.
aa_log_factory_reference() {
    local f name actual same=0 total=0
    for f in "$MZD_SM_CONF" "$MZD_SM_WCP" "$MZD_AA_XML" "$MZD_AA_XML_UCP"; do
        name=$(basename "$f")
        total=$((total + 1))
        actual=$(mzd_sha256_file "$f" 2>/dev/null) || continue
        if [ "$actual" = "$(aa_tested_hash "$name")" ]; then
            same=$((same + 1))
        else
            mzd_log "$name differs from the tested EU 74.00.324A file (sha256 $actual); it is backed up as found"
        fi
    done
    mzd_log "factory files: $same of $total identical to the tested EU build"
}

# The four live files show no trace of any Android Auto touch modification:
# no LD_PRELOAD/environ_var lines, no .orig copies, no touch_screen block,
# and all four are well-formed XML. This is the "clean" test for every region.
aa_live_files_look_factory() {
    local f
    for f in "$MZD_SM_CONF" "$MZD_SM_WCP"; do
        mzd_real_file "$f" || { AA_STATE_REASON="$(basename "$f") is missing"; return 1; }
        [ "$(aa_conf_marker_count "$f" | tr -d '[:space:]')" = 0 ] || { AA_STATE_REASON="$(basename "$f") contains oem-aa-mod lines"; return 1; }
        if aa_conf_has_foreign_markers "$f"; then AA_STATE_REASON="$(basename "$f") contains foreign LD_PRELOAD lines"; return 1; fi
        if [ -e "$f.orig" ] || [ -L "$f.orig" ]; then AA_STATE_REASON="$(basename "$f").orig exists"; return 1; fi
    done
    for f in "$MZD_AA_XML" "$MZD_AA_XML_UCP"; do
        mzd_real_file "$f" || { AA_STATE_REASON="$(basename "$f") is missing"; return 1; }
        if grep -q '<touch_screen>' "$f" 2>/dev/null; then AA_STATE_REASON="$(basename "$f") already contains touch_screen"; return 1; fi
        if [ -e "$f.orig" ] || [ -L "$f.orig" ]; then AA_STATE_REASON="$(basename "$f").orig exists"; return 1; fi
        aa_xml_patch "$f" /dev/null "$(aa_xml_touch_mode "$f")" || {
            AA_STATE_REASON="$(basename "$f") has an unexpected layout (touch cannot be added safely)"
            return 1
        }
    done
    for f in "$MZD_SM_CONF" "$MZD_SM_WCP" "$MZD_AA_XML" "$MZD_AA_XML_UCP"; do
        mzd_validate_xml "$f" >/dev/null 2>&1 || { AA_STATE_REASON="$(basename "$f") is not well-formed XML"; return 1; }
    done
    return 0
}

aa_service_of() {
    case "$1" in
        libpatch-blmjciaapa.so) printf 'jciAAPA\n' ;;
        libpatch-svcjcinavi.so) printf 'jcinavi\n' ;;
        libpatch-aap_service.so) printf 'aap_service\n' ;;
        *) return 1 ;;
    esac
}

# aa_conf_matches <conf> [libs]: exactly the LD_PRELOAD lines of <libs>
# (default: the current profile), each directly inside its <service> block.
aa_conf_matches() {
    local conf="$1" libs="${2:-$AA_LIBS}" lib service expected count total svc_line our_line
    mzd_real_file "$conf" || return 1
    total=0
    for lib in $libs; do
        expected=$(aa_expected_line "$lib")
        count=$(mzd_count_line "$conf" "$expected")
        count=$(printf '%s' "$count" | tr -d '[:space:]')
        [ "${count:-0}" = 1 ] || { AA_STATE_REASON="$conf: expected LD_PRELOAD line missing or duplicated: $lib"; return 1; }
        total=$((total + 1))
    done
    count=$(aa_conf_marker_count "$conf")
    count=$(printf '%s' "$count" | tr -d '[:space:]')
    [ "${count:-0}" = "$total" ] || { AA_STATE_REASON="$conf: unexpected oem-aa-mod lines (${count:-0} instead of $total)"; return 1; }
    # Wiring check: each shim's LD_PRELOAD line must sit directly inside the
    # matching <service> block (our writer inserts it as the next line).
    for lib in $libs; do
        service=$(aa_service_of "$lib") || return 1
        expected=$(aa_expected_line "$lib")
        svc_line=$(grep -n "<service [^>]*name=\"$service\"" "$conf" 2>/dev/null | head -n1 | cut -d: -f1)
        our_line=$(awk -v line="$expected" '$0 == line { print NR; exit }' "$conf" 2>/dev/null)
        [ -n "$svc_line" ] && [ -n "$our_line" ] || { AA_STATE_REASON="$conf: $service/$lib not wired"; return 1; }
        [ "$our_line" -eq $((svc_line + 1)) ] || { AA_STATE_REASON="$conf: $lib is not directly inside the $service block"; return 1; }
    done
    return 0
}

aa_shims_match() {
    local lib expected
    for lib in $AA_LIBS; do
        case "$lib" in
            libpatch-blmjciaapa.so) expected="$AA_HASH_BLM" ;;
            libpatch-svcjcinavi.so) expected="$AA_HASH_NAVI" ;;
            libpatch-aap_service.so) expected="$AA_HASH_AAP" ;;
        esac
        mzd_real_file "$MZD_AA_DIR/$lib" || { AA_STATE_REASON="shim missing: $lib"; return 1; }
        [ "$(mzd_sha256_file "$MZD_AA_DIR/$lib")" = "$expected" ] || { AA_STATE_REASON="shim hash differs: $lib"; return 1; }
    done
    mzd_real_file "$MZD_AA_DIR/libpatch.conf" || { AA_STATE_REASON="libpatch.conf missing"; return 1; }
    [ "$(mzd_sha256_file "$MZD_AA_DIR/libpatch.conf")" = "$AA_HASH_CONF" ] || { AA_STATE_REASON="libpatch.conf hash differs"; return 1; }
    mzd_real_file "$MZD_AA_STATE_MARKER" || { AA_STATE_REASON="installation marker missing"; return 1; }
    grep -q "^installer=" "$MZD_AA_STATE_MARKER" || { AA_STATE_REASON="installation marker invalid"; return 1; }
    grep -q "^mod_version=$AA_MOD_VERSION$" "$MZD_AA_STATE_MARKER" || { AA_STATE_REASON="installation marker does not match the stick version"; return 1; }
    return 0
}

# ---------------------------------------------------------------------------
# AA XML: add touch to the car's own file instead of replacing it
# ---------------------------------------------------------------------------
# aap_service sends the phone the video settings it reads from
# application/video/resolution/{value,density,real_density,par,fps,
# decoder_additional_depth,width_margin,height_margin}. The oem-aa-mod XML
# moves par, fps and the decoder depth there and adds real_density, which
# changes how the phone scales Android Auto. So the car's XML is kept and only
# what oem-aa-mod adds for its features is inserted:
#   - <touch_screen> as the first entry of <input_devices> (use_internally
#     true in the main XML, false in _UCP, as in oem-aa-mod)
#   - AAP_KEYCODE_MEDIA_PAUSE in <key_codes> (mute pauses the phone)
#   - <navigation>: subscribe TRUE and <cluster_type>ENUM (head-up display)
# <display>, <video> and every other line stay byte for byte as shipped.

# aa_xml_patch <factory-xml> <output> <true|false>
# Fails (exit 3) when the layout is not the expected one.
aa_xml_patch() {
    awk -v ui="$3" '
        function indent(s) { match(s, /^[ \t]*/); return substr(s, 1, RLENGTH) }
        NR == FNR {
            l = $0; sub(/\r$/, "", l)
            if (l ~ /^[ \t]*<input_devices>[ \t]*$/) n_in++
            if (l ~ /^[ \t]*<\/key_codes>[ \t]*$/) n_kend++
            if (l ~ /^[ \t]*<value>AAP_KEYCODE_MEDIA_PLAY<\/value>[ \t]*$/) n_play++
            if (l ~ /AAP_KEYCODE_MEDIA_PAUSE/) n_pause++
            if (l ~ /^[ \t]*<navigation>[ \t]*$/) n_nav++
            if (l ~ /touch_screen|use_internally|as_secondary_input|AAP_TOUCH_SCREEN_TYPE|cluster_type/) n_bad++
            next
        }
        FNR == 1 && (n_in != 1 || n_kend != 1 || n_nav != 1 || n_bad != 0 || n_play > 1 || n_pause > 1) { exit 3 }
        {
            l = $0; cr = ""
            if (sub(/\r$/, "", l)) cr = "\r"
            if (after_nav) {
                after_nav = 0
                if (l !~ /^[ \t]*<subscribe>(TRUE|FALSE)<\/subscribe>[ \t]*$/) exit 3
                i = indent(l)
                print i "<subscribe>TRUE</subscribe>" cr
                print i "<cluster_type>ENUM</cluster_type>" cr
                nav_done = 1
                next
            }
            if (l ~ /^[ \t]*<\/key_codes>[ \t]*$/ && n_pause == 0 && n_play == 0) {
                print indent(l) "    <value>AAP_KEYCODE_MEDIA_PAUSE</value>" cr
                pause_done = 1
            }
            print l cr
            if (l ~ /^[ \t]*<input_devices>[ \t]*$/) {
                i = indent(l) "    "
                print i "<touch_screen>" cr
                print i "    <use_internally>" ui "</use_internally>" cr
                print i "    <path>/dev/input/filtered-touchscreen0</path>" cr
                print i "    <type>AAP_TOUCH_SCREEN_TYPE_CAPACITIVE</type>" cr
                print i "    <as_secondary_input>false</as_secondary_input>" cr
                print i "</touch_screen>" cr
                touch_done = 1
            }
            if (l ~ /^[ \t]*<value>AAP_KEYCODE_MEDIA_PLAY<\/value>[ \t]*$/ && n_pause == 0) {
                print indent(l) "<value>AAP_KEYCODE_MEDIA_PAUSE</value>" cr
                pause_done = 1
            }
            if (l ~ /^[ \t]*<navigation>[ \t]*$/) after_nav = 1
        }
        END {
            if (!touch_done || !nav_done) exit 3
            if (n_pause == 0 && !pause_done) exit 3
        }
    ' "$1" "$1" >"$2"
}

# aa_xml_verify <factory-xml> <candidate> <true|false>
# Independent check of aa_xml_patch: the candidate is well-formed, carries
# exactly one touch block with the expected entries, and taking the inserted
# lines out again (and the navigation subscribe back) gives the factory file
# byte for byte.
aa_xml_verify() {
    local base="$1" candidate="$2" ui="$3" back n line
    mzd_validate_xml "$candidate" || return 1
    for line in '<touch_screen>' "<use_internally>$ui</use_internally>" \
                '<path>/dev/input/filtered-touchscreen0</path>' \
                '<type>AAP_TOUCH_SCREEN_TYPE_CAPACITIVE</type>' \
                '<as_secondary_input>false</as_secondary_input>' '</touch_screen>' \
                '<value>AAP_KEYCODE_MEDIA_PAUSE</value>' '<subscribe>TRUE</subscribe>' \
                '<cluster_type>ENUM</cluster_type>'; do
        n=$(grep -c -F "$line" "$candidate" 2>/dev/null | tr -d '[:space:]')
        case "$line" in
            '<subscribe>TRUE</subscribe>') [ "${n:-0}" -ge 1 ] ;;
            *) [ "${n:-0}" = 1 ] ;;
        esac || { mzd_error "AA XML check: '$line' found ${n:-0}x in $(basename "$candidate")"; return 1; }
    done
    back="$candidate.mzd-verify"
    if ! awk '
        NR == FNR {
            l = $0; sub(/\r$/, "", l)
            if (nav) { navsub = $0; nav = 0 }
            if (l ~ /^[ \t]*<navigation>[ \t]*$/) nav = 1
            if (l ~ /AAP_KEYCODE_MEDIA_PAUSE/) base_pause = 1
            next
        }
        {
            l = $0; sub(/\r$/, "", l)
            if (skip > 0) { skip--; next }
            if (l ~ /^[ \t]*<touch_screen>[ \t]*$/) { skip = 5; next }
            if (!base_pause && l ~ /^[ \t]*<value>AAP_KEYCODE_MEDIA_PAUSE<\/value>[ \t]*$/) next
            if (l ~ /^[ \t]*<cluster_type>ENUM<\/cluster_type>[ \t]*$/) next
            if (nav) {
                nav = 0
                if (l !~ /^[ \t]*<subscribe>TRUE<\/subscribe>[ \t]*$/) exit 3
                print navsub
                next
            }
            print
            if (l ~ /^[ \t]*<navigation>[ \t]*$/) nav = 1
        }
    ' "$base" "$candidate" >"$back"; then
        rm -f "$back"
        mzd_error "AA XML check: unexpected structure in $(basename "$candidate")"
        return 1
    fi
    if [ "$(mzd_sha256_file "$back")" != "$(mzd_sha256_file "$base")" ]; then
        rm -f "$back"
        mzd_error "AA XML check: the change contains unexpected differences: $(basename "$candidate")"
        return 1
    fi
    rm -f "$back"
    return 0
}

# Main XML: use_internally true; _UCP: false (as in oem-aa-mod).
aa_xml_touch_mode() {
    case "$(basename "$1")" in
        aap_system_attributes.xml) printf 'true\n' ;;
        *) printf 'false\n' ;;
    esac
}

# sha256 of the XML this installer writes for <live>, derived from the copy in
# MZD_BACKUP_DIR.
aa_xml_expected_sha() {
    local live="$1" base out sha
    base="$MZD_BACKUP_DIR/$(basename "$live")"
    mzd_real_file "$base" || return 1
    out="$MZD_ROOT/tmp/mzd-xml-expect.$$"
    aa_xml_patch "$base" "$out" "$(aa_xml_touch_mode "$live")" || { rm -f "$out"; return 1; }
    sha=$(mzd_sha256_file "$out") || { rm -f "$out"; return 1; }
    rm -f "$out"
    printf '%s\n' "$sha"
}

# aa_stage_xml <live-xml>: stage <live>.mzd-new from the backup copy.
# Sets AA_STAGED_SHA.
aa_stage_xml() {
    local live="$1" ui base candidate mode uid gid sha
    ui=$(aa_xml_touch_mode "$live")
    base="$MZD_BACKUP_DIR/$(basename "$live")"
    candidate="$live.mzd-new"
    mzd_real_file "$base" || { mzd_error "backup copy missing: $base"; return 1; }
    mzd_discard_stage "$candidate" || return 1
    mzd_fault stage-write-fail && { mzd_error "TEST: injected stage write error"; return 1; }
    if ! aa_xml_patch "$base" "$candidate" "$ui"; then
        rm -f "$candidate"
        mzd_error "the AA XML has an unexpected layout: $(basename "$live")"
        return 1
    fi
    aa_xml_verify "$base" "$candidate" "$ui" || { rm -f "$candidate"; return 1; }
    mode=$(mzd_mode "$live"); uid=$(mzd_uid "$live"); gid=$(mzd_gid "$live")
    chmod "$mode" "$candidate" || { mzd_error "chmod of the stage file failed: $candidate"; rm -f "$candidate"; return 1; }
    if [ "$MZD_TEST_MODE" != 1 ]; then
        chown "$uid:$gid" "$candidate" 2>/dev/null || { mzd_error "chown of the stage file failed: $candidate"; rm -f "$candidate"; return 1; }
    fi
    sha=$(mzd_sha256_file "$candidate") || { rm -f "$candidate"; return 1; }
    mzd_fsync_file "$candidate" || { mzd_error "fsync of the stage file failed: $candidate"; rm -f "$candidate"; return 1; }
    MZD_STAGES="$MZD_STAGES $candidate"
    AA_STAGED_SHA="$sha"
    return 0
}

# aa_xml_matches [legacy]: the installed XMLs are the car's XML plus the touch
# entries (derived from the backup). With "legacy" the oem-aa-mod file itself,
# as written by early builds of this installer, is accepted too (it changes
# how the phone scales Android Auto, so it is only a state to update from).
aa_xml_matches() {
    local accept_legacy="${1:-}" live legacy actual expected name
    for live in "$MZD_AA_XML" "$MZD_AA_XML_UCP"; do
        name=$(basename "$live")
        case "$name" in
            aap_system_attributes.xml) legacy="$AA_HASH_XML" ;;
            *) legacy="$AA_HASH_XML_UCP" ;;
        esac
        mzd_real_file "$live" || { AA_STATE_REASON="$name missing"; return 1; }
        actual=$(mzd_sha256_file "$live") || { AA_STATE_REASON="$name cannot be read"; return 1; }
        if [ "$actual" = "$legacy" ]; then
            [ "$accept_legacy" = legacy ] && continue
            AA_STATE_REASON="$name is the oem-aa-mod file (early installer build)"
            return 1
        fi
        expected=$(aa_xml_expected_sha "$live") || {
            AA_STATE_REASON="$name: the expected file cannot be derived from the backup"
            return 1
        }
        [ "$actual" = "$expected" ] || { AA_STATE_REASON="$name differs from the expected touch-enabled file"; return 1; }
    done
    return 0
}

# Which AA XML is on the car (for status and diagnosis).
aa_xml_variant() {
    local live="$1" name actual legacy expected
    name=$(basename "$live")
    mzd_real_file "$live" || { printf 'missing\n'; return 0; }
    actual=$(mzd_sha256_file "$live")
    case "$name" in
        aap_system_attributes.xml) legacy="$AA_HASH_XML" ;;
        *) legacy="$AA_HASH_XML_UCP" ;;
    esac
    if [ -n "$legacy" ] && [ "$actual" = "$legacy" ]; then printf 'oem-aa-mod-file\n'; return 0; fi
    if [ -n "$MZD_BACKUP_DIR" ] && expected=$(aa_xml_expected_sha "$live") && [ "$actual" = "$expected" ]; then
        printf 'factory+touch\n'; return 0
    fi
    if grep -q '<touch_screen>' "$live" 2>/dev/null; then printf 'other-with-touch\n'; else printf 'without-touch\n'; fi
}

# sha256 of a libpatch.conf with the value of use_protocol_v1_6 blanked out,
# so two files can be compared apart from that one setting.
aa_conf_v16_neutral_sha() {
    local f="$1" out sha
    mzd_real_file "$f" || return 1
    out="$MZD_ROOT/tmp/mzd-conf-v16.$$"
    awk '
        /^[ \t]*use_protocol_v1_6[ \t]*=/ { print "use_protocol_v1_6 = *"; next }
        { print }
    ' "$f" >"$out" || { rm -f "$out"; return 1; }
    sha=$(mzd_sha256_file "$out") || { rm -f "$out"; return 1; }
    rm -f "$out"
    printf '%s\n' "$sha"
}

# aa_marker_value <key>: a value from the installation marker (only safe
# characters).
aa_marker_value() {
    mzd_real_file "$MZD_AA_STATE_MARKER" || return 1
    sed -n "s/^$1=//p" "$MZD_AA_STATE_MARKER" 2>/dev/null | head -n1 | tr -cd '0-9A-Za-z.+_-' | cut -c1-40
}

# An older installation of this installer that is complete in itself:
#   - installer 1.0.0: Android Auto 1.6 (aap_service shim + its LD_PRELOAD
#     line, libpatch.conf with use_protocol_v1_6 = true)
#   - early builds: the oem-aa-mod XMLs copied instead of the car's own XMLs
#     with the touch entries
# Same oem-aa-mod version and shims as on the stick, libpatch.conf equal to the
# stick's apart from use_protocol_v1_6, our marker, our LD_PRELOAD lines only.
# Requires aa_verify_payload and a found backup. Sets AA_STATE_REASON.
aa_outdated_install() {
    local libs lib expected what="" from
    libs="libpatch-blmjciaapa.so libpatch-svcjcinavi.so"
    if [ "$(mzd_count_line "$MZD_SM_CONF" "$(aa_expected_line libpatch-aap_service.so)" | tr -d '[:space:]')" != 0 ]; then
        libs="$libs libpatch-aap_service.so"
        [ "$AA_V16" = 1 ] || what="Android Auto 1.6"
    elif [ "$AA_V16" = 1 ]; then
        return 1
    fi
    aa_conf_matches "$MZD_SM_CONF" "$libs" || return 1
    aa_conf_matches "$MZD_SM_WCP" "$libs" || return 1
    for lib in $libs; do
        case "$lib" in
            libpatch-blmjciaapa.so) expected="$AA_HASH_BLM" ;;
            libpatch-svcjcinavi.so) expected="$AA_HASH_NAVI" ;;
            libpatch-aap_service.so) expected="$AA_HASH_AAP" ;;
        esac
        [ -n "$expected" ] || return 1
        mzd_real_file "$MZD_AA_DIR/$lib" || return 1
        [ "$(mzd_sha256_file "$MZD_AA_DIR/$lib")" = "$expected" ] || return 1
    done
    mzd_real_file "$MZD_AA_DIR/libpatch.conf" || return 1
    [ "$(aa_conf_v16_neutral_sha "$MZD_AA_DIR/libpatch.conf")" = "$(aa_conf_v16_neutral_sha "$MZD_AA_SRC/libpatch.conf")" ] || return 1
    if [ "$(mzd_sha256_file "$MZD_AA_DIR/libpatch.conf")" != "$AA_HASH_CONF" ]; then
        [ -n "$what" ] || what="libpatch.conf"
    fi
    mzd_real_file "$MZD_AA_STATE_MARKER" || return 1
    grep -q '^installer=' "$MZD_AA_STATE_MARKER" || return 1
    grep -q "^mod_version=$AA_MOD_VERSION$" "$MZD_AA_STATE_MARKER" || return 1
    aa_xml_matches legacy || return 1
    if ! aa_xml_matches; then
        what="${what:+$what, }oem-aa-mod XML"
    fi
    [ -n "$what" ] || return 1
    from=$(aa_marker_value installer)
    AA_STATE_REASON="older installation (installer ${from:-unknown}: $what)"
    return 0
}

# Find this installer's backup: the one named in the installation marker,
# otherwise one taken on the running firmware, otherwise the newest valid one.
# (The CMU clock starts at 1970 on every boot, so backup names are not dates.)
aa_backup_find() {
    MZD_BACKUP_PREFER=""
    if mzd_real_file "$MZD_AA_STATE_MARKER"; then
        MZD_BACKUP_PREFER=$(sed -n 's/^backup=\([0-9A-Za-z-]*\)$/\1/p' "$MZD_AA_STATE_MARKER" 2>/dev/null | head -n1)
    fi
    mzd_backup_find "aa-touch-"
}

# Rootfs shows no AA modification (used after an official firmware update,
# which replaces /jci and /etc but keeps /data_persist).
aa_live_rootfs_is_stock() {
    aa_live_files_look_factory
}

# Target binaries of the shims. oem-aa-mod supports every V74 build; this
# installer was car-tested on EU 74.00.324A. Sets AA_BINARIES_KNOWN=1 when all
# three equal that build, 0 otherwise. Fails only when a binary is missing.
aa_binary_known() {
    local path="$1" expected="$2" actual
    if [ "${MZD_TEST_MODE:-0}" = 1 ] && [ "${MZD_TEST_ENFORCE_BINARY_HASHES:-0}" != 1 ]; then
        return 0
    fi
    actual=$(mzd_sha256_file "$path") || return 1
    if [ "$actual" = "$expected" ]; then
        return 0
    fi
    mzd_log "$(basename "$path") differs from the tested EU 74.00.324A build (sha256 $actual)"
    return 1
}

aa_target_binaries_check() {
    AA_BINARIES_KNOWN=0
    mzd_real_file "$MZD_JCI/aapa/blmjciaapa.so" || { mzd_error "target library missing: /jci/aapa/blmjciaapa.so"; return 1; }
    mzd_real_file "$MZD_JCI/navi/svcjcinavi.so" || { mzd_error "target library missing: /jci/navi/svcjcinavi.so"; return 1; }
    mzd_real_file "$MZD_ROOT/usr/bin/aap_service" || { mzd_error "aap_service missing: /usr/bin/aap_service"; return 1; }
    mzd_real_file "$MZD_AA_XML" || { mzd_error "factory XML missing: $MZD_AA_XML"; return 1; }
    mzd_real_file "$MZD_AA_XML_UCP" || { mzd_error "factory XML missing: $MZD_AA_XML_UCP"; return 1; }
    if aa_binary_known "$MZD_JCI/aapa/blmjciaapa.so" "$MZD_AA_TESTED_BLM_SHA" && \
       aa_binary_known "$MZD_JCI/navi/svcjcinavi.so" "$MZD_AA_TESTED_NAVI_SHA" && \
       aa_binary_known "$MZD_ROOT/usr/bin/aap_service" "$MZD_AA_TESTED_AAP_SHA"; then
        AA_BINARIES_KNOWN=1
        mzd_log "target binaries: identical to the tested EU 74.00.324A build"
    else
        mzd_log "target binaries: other build than the tested one (region $MZD_FW_FLAVOR)"
    fi
    return 0
}

# Ask before installing on a build that differs from the tested one.
# Returns 0 to continue. MZD_ACCEPT_UNTESTED_BUILD=1 records an earlier yes.
aa_confirm_untested_build() {
    [ "$AA_BINARIES_KNOWN" = 1 ] && return 0
    [ "${MZD_ACCEPT_UNTESTED_BUILD:-0}" = 1 ] && return 0
    if mzd_ask2 "This Mazda Connect software ($MZD_FW, $MZD_FW_FLAVOR) differs from the build this installer was tested on in a car (EU 74.00.324A).\n\noem-aa-mod supports all V74 builds. Your files are backed up first and can be restored with this stick.\n\nContinue?" "Continue" "Cancel"; then
        MZD_ACCEPT_UNTESTED_BUILD=1
        export MZD_ACCEPT_UNTESTED_BUILD
        mzd_log "untested build accepted by the user"
        return 0
    fi
    mzd_log "installation cancelled: untested build not accepted"
    return 1
}

# Determine AA_STATE and AA_STATE_REASON. Requires aa_verify_payload first.
aa_state() {
    local conf any_marker=0 foreign_marker=0 touch=0 shims=0 backup_ok=0 count reason
    AA_STATE=""
    AA_STATE_REASON=""
    if ! mzd_real_file "$MZD_SM_CONF" || ! mzd_real_file "$MZD_SM_WCP"; then
        AA_STATE=broken
        AA_STATE_REASON="sm.conf/sm_WCP.conf missing"
        printf 'broken|%s\n' "$AA_STATE_REASON"
        return 0
    fi
    # A .orig backup or a marker line from another installer is foreign.
    for conf in "$MZD_SM_CONF" "$MZD_SM_WCP"; do
        if [ -e "$conf.orig" ] || [ -L "$conf.orig" ]; then foreign_marker=1; fi
        if aa_conf_has_foreign_markers "$conf"; then foreign_marker=1; fi
    done
    if [ -e "$MZD_AA_XML.orig" ] || [ -e "$MZD_AA_XML_UCP.orig" ] || [ -L "$MZD_AA_XML.orig" ] || [ -L "$MZD_AA_XML_UCP.orig" ]; then
        foreign_marker=1
    fi
    if mzd_real_file "$MZD_AA_XML" && grep -q '<touch_screen>' "$MZD_AA_XML" 2>/dev/null; then touch=1; fi
    if mzd_real_file "$MZD_AA_XML_UCP" && grep -q '<touch_screen>' "$MZD_AA_XML_UCP" 2>/dev/null; then touch=1; fi
    for conf in "$MZD_SM_CONF" "$MZD_SM_WCP"; do
        count=$(aa_conf_marker_count "$conf" | tr -d '[:space:]')
        [ "${count:-0}" != 0 ] && any_marker=1
    done
    if [ -d "$MZD_AA_DIR" ]; then
        for conf in "$MZD_AA_DIR"/libpatch-*.so; do
            [ -e "$conf" ] && shims=1 && break
        done
    fi
    if [ "$any_marker" = 0 ] && [ "$touch" = 0 ] && [ "$shims" = 0 ] && [ "$foreign_marker" = 0 ]; then
        if aa_live_files_look_factory; then
            AA_STATE=clean
            printf 'clean|%s\n' "$AA_STATE_REASON"
            return 0
        fi
        AA_STATE=broken
        printf 'broken|%s\n' "$AA_STATE_REASON"
        return 0
    fi
    if [ "$foreign_marker" = 1 ]; then
        AA_STATE=foreign
        AA_STATE_REASON="foreign oem-aa-mod traces (.orig files or other LD_PRELOAD lines)"
        printf 'foreign|%s\n' "$AA_STATE_REASON"
        return 0
    fi
    # Our own install always has a private, validated backup; without it the
    # state cannot be attributed to this installer.
    if aa_backup_find; then
        backup_ok=1
    fi
    if [ "$backup_ok" = 0 ]; then
        AA_STATE=foreign
        AA_STATE_REASON="oem-aa-mod traces present, but no backup of this installer"
        printf 'foreign|%s\n' "$AA_STATE_REASON"
        return 0
    fi
    if aa_conf_matches "$MZD_SM_CONF" && aa_conf_matches "$MZD_SM_WCP" && \
       aa_xml_matches && aa_shims_match; then
        AA_STATE=ours
        printf 'ours|%s\n' "$AA_STATE_REASON"
        return 0
    fi
    [ -n "$AA_STATE_REASON" ] || AA_STATE_REASON="partial installation (lines or files differ)"
    reason="$AA_STATE_REASON"
    if aa_outdated_install; then
        AA_STATE=outdated
        printf 'outdated|%s\n' "$AA_STATE_REASON"
        return 0
    fi
    AA_STATE_REASON="$reason"
    AA_STATE=partial
    printf 'partial|%s\n' "$AA_STATE_REASON"
    return 0
}

# Run aa_state and keep the reason in the current shell (command substitution
# would otherwise lose AA_STATE_REASON). Sets AA_STATE, AA_STATE_REASON.
aa_state_parse() {
    local line
    line=$(aa_state)
    AA_STATE=${line%%|*}
    if [ "$line" = "$AA_STATE" ]; then
        AA_STATE_REASON=""
    else
        AA_STATE_REASON=${line#*|}
    fi
}

# ---------------------------------------------------------------------------
# Staged file changes
# ---------------------------------------------------------------------------

# Stage a patched copy of one service config: remove all oem-aa-mod lines,
# insert the expected LD_PRELOAD line after every required <service>
# definition, validate XML and prove the diff is exactly the inserted lines.
# This is the same change as the upstream installer's sed, done verifiably.
# Sets AA_STAGED_SHA.
aa_stage_conf() {
    local conf="$1" candidate base added mode uid gid sha
    local lib service expected count
    added="$conf.mzd-added"
    candidate="$conf.mzd-new"
    base="$conf.mzd-base"
    rm -f "$added" "$base" 2>/dev/null || true
    : >"$added" || { mzd_error "cannot create helper file: $added"; return 1; }
    mzd_require_file "$conf" || return 1
    mzd_discard_stage "$candidate" >/dev/null 2>&1 || true
    if ! awk '
        $0 !~ /env_value="\/data_persist\/oem-aa-mod\// { print }
    ' "$conf" >"$candidate"; then
        mzd_error "could not clean the configuration: $conf"
        return 1
    fi
    mzd_validate_xml "$candidate" || { rm -f "$candidate" "$added"; return 1; }
    cp "$candidate" "$base" || { mzd_error "cannot create the verification base: $base"; rm -f "$candidate" "$added"; return 1; }
    for service in $AA_SERVICES; do
        count=$(grep -c "<service [^>]*name=\"$service\"" "$candidate" 2>/dev/null || true)
        count=$(printf '%s' "$count" | tr -d '[:space:]')
        [ "${count:-0}" = 1 ] || {
            mzd_error "service $service not found exactly once in $conf (${count:-0}x)"
            rm -f "$candidate" "$added" "$base"
            return 1
        }
        case "$service" in
            jciAAPA) lib=libpatch-blmjciaapa.so ;;
            jcinavi) lib=libpatch-svcjcinavi.so ;;
            aap_service) lib=libpatch-aap_service.so ;;
            *) rm -f "$candidate" "$added" "$base"; return 1 ;;
        esac
        expected=$(aa_expected_line "$lib")
        printf '%s\n' "$expected" >>"$added"
        if ! awk -v svc="$service" -v line="$expected" '
            done == 0 && /<service[ \t]/ && index($0, "name=\"" svc "\"") > 0 {
                print; print line; done = 1; next
            }
            { print }
            END { if (done != 1) exit 3 }
        ' "$candidate" >"$candidate.tmp"; then
            mzd_error "could not patch service $service: $conf"
            rm -f "$candidate" "$candidate.tmp" "$added" "$base"
            return 1
        fi
        mv -f "$candidate.tmp" "$candidate" || return 1
    done
    mzd_validate_xml "$candidate" || { rm -f "$candidate" "$added" "$base"; return 1; }
    if ! mzd_stage_verify_conf "$candidate" "$base" "$added"; then
        rm -f "$candidate" "$added" "$base"
        return 1
    fi
    rm -f "$base"
    mode=$(mzd_mode "$conf"); uid=$(mzd_uid "$conf"); gid=$(mzd_gid "$conf")
    if [ "$MZD_TEST_MODE" != 1 ]; then
        chmod "$mode" "$candidate" || return 1
        chown "$uid:$gid" "$candidate" 2>/dev/null || return 1
    fi
    sha=$(mzd_sha256_file "$candidate") || { rm -f "$candidate" "$added"; return 1; }
    mzd_fsync_file "$candidate" || { rm -f "$candidate" "$added"; return 1; }
    MZD_STAGES="$MZD_STAGES $candidate"
    AA_STAGED_SHA="$sha"
    rm -f "$added"
    return 0
}

aa_install_shims() {
    local lib src expected in_use used previous
    # Keep track of an update in place: the installer version found on the car
    # (or the one an earlier update already recorded).
    previous=$(aa_marker_value installer) || previous=""
    if [ -z "$previous" ] || [ "$previous" = "$MZD_INSTALLER_VERSION" ]; then
        previous=$(aa_marker_value previous_installer) || previous=""
    fi
    if [ ! -d "$MZD_AA_DIR" ]; then
        mkdir -p "$MZD_AA_DIR" || { mzd_error "cannot create the target folder: $MZD_AA_DIR"; return 1; }
    fi
    for lib in $AA_LIBS; do
        case "$lib" in
            libpatch-blmjciaapa.so) expected="$AA_HASH_BLM" ;;
            libpatch-svcjcinavi.so) expected="$AA_HASH_NAVI" ;;
            libpatch-aap_service.so) expected="$AA_HASH_AAP" ;;
        esac
        src="$MZD_AA_SRC/$lib"
        mzd_stage_copy "$src" "$MZD_AA_DIR/$lib" "$expected" || return 1
        mzd_publish_staged "$MZD_AA_DIR/$lib" "$expected" 0644 0 0 || return 1
    done
    mzd_stage_copy "$MZD_AA_SRC/libpatch.conf" "$MZD_AA_DIR/libpatch.conf" "$AA_HASH_CONF" || return 1
    mzd_publish_staged "$MZD_AA_DIR/libpatch.conf" "$AA_HASH_CONF" 0644 0 0 || return 1
    # Profile switch: move shims that the current profile does not use out of
    # the live directory (kept as evidence, not deleted).
    for lib in libpatch-svcjcinavi.so libpatch-aap_service.so; do
        in_use=0
        for used in $AA_LIBS; do
            [ "$used" = "$lib" ] && in_use=1
        done
        [ "$in_use" = 1 ] && continue
        if [ -e "$MZD_AA_DIR/$lib" ]; then
            mkdir -p "$MZD_REMOVED_DIR"
            mv "$MZD_AA_DIR/$lib" "$MZD_REMOVED_DIR/$lib.$(mzd_stamp)" ||
                { mzd_error "cannot move the unused shim: $lib"; return 1; }
            mzd_log "unused shim moved aside (profile $AA_PROFILE): $lib"
        fi
    done
    {
        printf 'installer=%s\n' "$MZD_INSTALLER_VERSION"
        printf 'mod_version=%s\n' "$AA_MOD_VERSION"
        printf 'protocol_v16=%s\n' "$AA_V16"
        printf 'profile=%s\n' "$AA_PROFILE"
        printf 'installed=%s\n' "$(mzd_stamp)"
        printf 'backup=%s\n' "$(basename "$MZD_BACKUP_DIR")"
        printf 'source_sha256_blm=%s\n' "$AA_HASH_BLM"
        printf 'source_sha256_navi=%s\n' "$AA_HASH_NAVI"
        [ -n "$previous" ] && printf 'previous_installer=%s\n' "$previous"
        :
    } >"$MZD_AA_DIR/install-state" || { mzd_error "cannot write the installation marker"; return 1; }
    mzd_fsync_file "$MZD_AA_DIR/install-state" || return 1
    mzd_fsync_dir "$MZD_AA_DIR" || return 1
    mzd_log "shims installed and read back ($AA_LIBS, GAL 1.6: $AA_V16)"
    return 0
}

aa_remove_shims() {
    local target stamp file
    stamp=$(mzd_stamp)
    target="$MZD_REMOVED_DIR/$stamp-$$"
    [ -d "$MZD_AA_DIR" ] || return 0
    mkdir -p "$target" || { mzd_error "cannot create the removal folder: $target"; return 1; }
    for file in "$MZD_AA_DIR"/libpatch-*.so "$MZD_AA_DIR/libpatch.conf" "$MZD_AA_DIR/install-state"; do
        [ -e "$file" ] || continue
        mv "$file" "$target/" || { mzd_error "cannot move the shim: $file"; return 1; }
    done
    # Staging artifacts of a failed publish must not keep the directory alive.
    for file in "$MZD_AA_DIR"/*.mzd-new "$MZD_AA_DIR"/*.mzd-verify "$MZD_AA_DIR"/*.mzd-base "$MZD_AA_DIR"/*.mzd-added; do
        [ -e "$file" ] || continue
        rm -f "$file" || { mzd_error "cannot remove the stage file: $file"; return 1; }
    done
    rmdir "$MZD_AA_DIR" 2>/dev/null || true
    mzd_log "shims moved aside: $target"
    return 0
}

# Restore the four backed-up files and verify them.
aa_restore_stock_files() {
    local conf xml name sha failures=0
    [ -n "$MZD_BACKUP_DIR" ] || { mzd_error "no backup available"; return 1; }
    for conf in "$MZD_SM_CONF" "$MZD_SM_WCP" "$MZD_AA_XML" "$MZD_AA_XML_UCP"; do
        name=$(basename "$conf")
        sha=$(mzd_backup_record "$name" | cut -d'|' -f1)
        [ -n "$sha" ] || { mzd_error "backup does not know $name"; return 1; }
        mzd_backup_restore_stage "$name" "$conf" || return 1
        mzd_publish_staged "$conf" "$sha" || return 1
    done
    # Validate as the final step: even when xmllint itself is the fault, the
    # files are already restored and the caller can still remove the shims.
    for xml in "$MZD_SM_CONF" "$MZD_SM_WCP" "$MZD_AA_XML" "$MZD_AA_XML_UCP"; do
        mzd_validate_xml "$xml" || failures=1
    done
    if [ "$failures" = 0 ]; then
        mzd_log "original files restored from the backup and verified"
        return 0
    fi
    mzd_error "original files restored, but XML validation failed"
    return 1
}

# ---------------------------------------------------------------------------
# Backup handling
# ---------------------------------------------------------------------------

# Create a fresh, verified write-once backup of the current files.
aa_create_new_backup() {
    local f
    if ! mzd_backup_begin "aa-touch-$AA_MOD_VERSION"; then
        return 1
    fi
    for f in "$MZD_SM_CONF" "$MZD_SM_WCP" "$MZD_AA_XML" "$MZD_AA_XML_UCP"; do
        mzd_backup_add "$f" "$(basename "$f")" || return 1
    done
    if ! mzd_backup_publish; then
        return 1
    fi
    mzd_backup_copy_to_stick
    mzd_fault exit-after-backup
    return 0
}

# Is the firmware recorded in the backup the same as the running one?
aa_backup_firmware_matches() {
    local fw
    fw=$(mzd_backup_meta_value firmware 2>/dev/null || true)
    case "$fw" in
        ''|unknown) return 0 ;; # older backup without firmware record: accept
    esac
    [ "$fw" = "$MZD_FW" ]
}

# ---------------------------------------------------------------------------
# Rollback hooks (called from mzd_cleanup when a transaction is interrupted)
# ---------------------------------------------------------------------------

aa_rollback_install() {
    local count failures=0
    mzd_log "rolling back the AA touch installation"
    aa_restore_stock_files || failures=1
    aa_remove_shims || failures=1
    count=$(aa_conf_marker_count "$MZD_SM_CONF" | tr -d '[:space:]')
    [ "${count:-0}" = 0 ] || { mzd_error "rollback: sm.conf still contains oem-aa-mod lines"; return 1; }
    count=$(aa_conf_marker_count "$MZD_SM_WCP" | tr -d '[:space:]')
    [ "${count:-0}" = 0 ] || { mzd_error "rollback: sm_WCP.conf still contains oem-aa-mod lines"; return 1; }
    if mzd_real_file "$MZD_AA_XML" && grep -q '<touch_screen>' "$MZD_AA_XML" 2>/dev/null; then
        mzd_error "rollback: aap_system_attributes.xml still contains touch_screen"
        return 1
    fi
    if mzd_real_file "$MZD_AA_XML_UCP" && grep -q '<touch_screen>' "$MZD_AA_XML_UCP" 2>/dev/null; then
        mzd_error "rollback: aap_system_attributes_UCP.xml still contains touch_screen"
        return 1
    fi
    if [ "$failures" != 0 ]; then
        mzd_error "rollback could not be completely verified"
        return 1
    fi
    mzd_log "rollback verified: original state restored"
    return 0
}

aa_rollback_revert() {
    # Rolling back a failed removal means finishing the removal: restore the
    # original files again and remove any shims that were already moved away.
    mzd_log "rollback of the removal: making sure the original state is restored"
    aa_restore_stock_files || return 1
    aa_remove_shims || return 1
    mzd_log "rollback of the removal verified"
    return 0
}

# ---------------------------------------------------------------------------
# Install / repair
# ---------------------------------------------------------------------------

aa_abort() {
    local message="$1"
    mzd_error "$message"
    mzd_discard_stages || true
    if [ "$MZD_TRANSACTION_ACTIVE" = 1 ] && [ -n "$MZD_ROLLBACK_FN" ]; then
        if "$MZD_ROLLBACK_FN"; then
            mzd_popup "$message\n\nThe backed-up original state was restored.\nAndroid Auto touch is not active."
        else
            mzd_popup "$message\n\nWARNING: the rollback could not be completely verified!\nKeep the USB stick and check mzd-usb.log."
        fi
        MZD_TRANSACTION_ACTIVE=0
        MZD_ROLLBACK_FN=""
    else
        mzd_popup "$message\n\nNothing was changed."
    fi
    mzd_finalize || true
    return 1
}

# MZD_CONFIRMED=1: the user already confirmed in the start dialog.
aa_install() {
    local state before conf sha lib name new_backup=0 done_text
    mzd_log "=== Android Auto touch: install ==="
    if ! mzd_require_firmware; then
        mzd_popup "Unsupported firmware.\n\nThis installer supports Mazda Connect 74.00.324 and 74.00.324A.\nNothing was changed."
        return 1
    fi
    if ! aa_verify_payload; then
        mzd_popup "The oem-aa-mod files on the stick are incomplete or damaged.\n\nNothing was changed.\nDetails: mzd-usb.log"
        return 1
    fi
    if ! aa_target_binaries_check; then
        mzd_popup "A required Mazda Connect component is missing (aap_service/blmjciaapa/svcjcinavi or the AA XML).\n\nNothing was changed.\nDetails: mzd-usb.log"
        return 1
    fi
    aa_state_parse
    state=$AA_STATE
    mzd_log "state before install: $state${AA_STATE_REASON:+ ($AA_STATE_REASON)}"
    case "$state" in
        foreign)
            mzd_popup "Another installer already modified Android Auto on this unit.\n\nFor safety nothing was changed.\nPlease remove it with the original installer first."
            return 1
            ;;
        broken)
            mzd_popup "The Mazda Connect configuration is not in a state this installer can handle (${AA_STATE_REASON}).\n\nNothing was changed.\nPlease run the diagnosis."
            return 1
            ;;
        ours|partial|outdated)
            if ! aa_backup_find; then
                mzd_popup "No valid backup of this installer was found.\n\nRepair is not possible.\nNothing was changed."
                return 1
            fi
            if ! aa_backup_firmware_matches; then
                # An official firmware update replaced /jci and /etc: the rootfs
                # may be original again while the shims/backup stayed in
                # /data_persist. Only then a fresh backup is safe.
                if aa_live_rootfs_is_stock; then
                    mzd_log "firmware change detected (backup: $(mzd_backup_meta_value firmware), now: $MZD_FW); rootfs shows no modification -> new backup"
                    new_backup=1
                else
                    mzd_popup "The backup was taken on a different firmware.\n\nA repair with this backup is not safe.\nNothing was changed."
                    return 1
                fi
            fi
            if [ "$new_backup" = 0 ] && [ "${MZD_CONFIRMED:-0}" != 1 ]; then
                if [ "$state" = outdated ]; then
                    mzd_ask2 "An older version of Android Auto touch\nis installed.\n\nUpdate it now?\nThe backup taken on this car is used." "Update" "Cancel" || {
                        mzd_log "update cancelled"
                        return 1
                    }
                else
                    mzd_ask2 "Android Auto touch is $([ "$state" = ours ] && echo already || echo partially) installed.\n\nRepair it now?" "Repair" "Cancel" || {
                        mzd_log "installation cancelled"
                        return 1
                    }
                fi
            fi
            ;;
        clean)
            new_backup=1
            ;;
        *)
            mzd_popup "Unknown starting state ($state).\n\nNothing was changed."
            return 1
            ;;
    esac
    if [ "$new_backup" = 1 ]; then
        aa_log_factory_reference
    fi
    aa_confirm_untested_build || {
        mzd_popup "Installation cancelled.\n\nNothing was changed."
        return 1
    }
    if [ "$state" = outdated ]; then
        mzd_popup_busy "Updating Android Auto touch...\n\nDo not pull the stick and\ndo not press anything."
    else
        mzd_popup_busy "Installing Android Auto touch...\n\nDo not pull the stick and\ndo not press anything."
    fi

    if [ "$new_backup" = 1 ]; then
        if ! aa_create_new_backup; then
            mzd_popup "The backup could not be created and verified.\n\nNothing was changed."
            return 1
        fi
    elif [ "$state" = outdated ]; then
        mzd_log "update in place with the existing backup: $MZD_BACKUP_DIR ($AA_STATE_REASON)"
    elif [ -n "$MZD_BACKUP_DIR" ]; then
        mzd_log "repair with the existing backup: $MZD_BACKUP_DIR"
    fi

    if ! mzd_prepare_mutation; then
        mzd_popup "Mazda Connect could not be made writable.\n\nNothing was changed."
        return 1
    fi
    MZD_TRANSACTION_ACTIVE=1
    MZD_ROLLBACK_FN=aa_rollback_install
    mzd_log "transaction active: shims -> service configs -> XMLs"

    aa_install_shims || { aa_abort "The shims could not be installed."; return 1; }

    for conf in "$MZD_SM_CONF" "$MZD_SM_WCP"; do
        if ! aa_stage_conf "$conf"; then
            aa_abort "The configuration could not be prepared: $(basename "$conf")"
            return 1
        fi
        sha="$AA_STAGED_SHA"
        if ! mzd_publish_staged "$conf" "$sha"; then
            aa_abort "The configuration could not be written/verified: $(basename "$conf")"
            return 1
        fi
        mzd_log "configuration verified: $(basename "$conf")"
    done

    for lib in "$MZD_AA_XML" "$MZD_AA_XML_UCP"; do
        name=$(basename "$lib")
        if ! aa_stage_xml "$lib"; then
            aa_abort "The AA XML could not be prepared: $name"
            return 1
        fi
        sha="$AA_STAGED_SHA"
        if ! mzd_publish_staged "$lib" "$sha"; then
            aa_abort "The AA XML could not be written/verified: $name"
            return 1
        fi
        mzd_log "AA XML verified: $name (car's file + touch, video settings unchanged)"
    done

    # Final readback of the complete target state before the transaction is
    # released (this also covers a stale/partial config left behind).
    before=$state
    aa_state_parse
    state=$AA_STATE
    if [ "$state" != ours ]; then
        aa_abort "The final check failed (state $state: ${AA_STATE_REASON})."
        return 1
    fi
    MZD_TRANSACTION_ACTIVE=0
    MZD_ROLLBACK_FN=""
    mzd_log "installation completely verified"

    if ! mzd_finalize; then
        mzd_popup "The installation was written, but watchdog/rootfs could not be verified afterwards.\n\nDo not switch off the car now. Run the diagnosis."
        return 1
    fi
    mzd_backup_copy_to_stick
    if [ "$before" = outdated ]; then
        mzd_popup "Android Auto touch updated and verified\n(installer $MZD_INSTALLER_VERSION, oem-aa-mod $AA_MOD_VERSION).\n\nThe new version is active after the restart.$(aa_not_yet_hint)"
        done_text="Android Auto touch is updated."
    else
        mzd_popup "Android Auto touch (oem-aa-mod $AA_MOD_VERSION) installed and verified.\n\nTouch in Android Auto is active after the restart.$(aa_not_yet_hint)"
        done_text="Android Auto touch is installed."
    fi
    if ! mzd_ask_reboot "$done_text"; then
        mzd_popup "The restart (Mazda SafeReboot) could not be requested.\n\nPlease restart Mazda Connect manually.\nThe installation is complete."
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Removal
# ---------------------------------------------------------------------------

# In a combined run the next step follows at once: keep the stick in.
aa_not_yet_hint() {
    [ "${MZD_SKIP_REBOOT:-0}" = 1 ] && printf '%s' '\n\nDo not pull the stick yet.'
    return 0
}

# MZD_CONFIRMED=1: the user already confirmed in the start dialog.
aa_revert() {
    local state
    mzd_log "=== Android Auto touch: remove ==="
    if ! mzd_require_firmware; then
        mzd_popup "Firmware not recognized or not supported.\n\nRemoval refused for safety."
        return 1
    fi
    aa_verify_payload || {
        mzd_popup "The oem-aa-mod files on the stick are missing or damaged.\n\nRemoval is not possible."
        return 1
    }
    aa_state_parse
    state=$AA_STATE
    mzd_log "state before removal: $state${AA_STATE_REASON:+ ($AA_STATE_REASON)}"
    case "$state" in
        clean)
            mzd_popup "Android Auto touch is not installed.\n\nThere is nothing to remove."
            return 0
            ;;
        foreign)
            mzd_popup "The existing Android Auto modification was not made by this installer.\n\nRemoval refused for safety.\nPlease use the original installer."
            return 1
            ;;
        broken)
            mzd_popup "The Mazda Connect configuration is not in a state this installer can handle (${AA_STATE_REASON}).\n\nRemoval refused.\nPlease run the diagnosis."
            return 1
            ;;
    esac
    if ! aa_backup_find; then
        mzd_popup "No valid backup of this installer was found.\n\nRemoval refused: there is no reliable way back."
        return 1
    fi
    if ! aa_backup_firmware_matches; then
        mzd_popup "The backup was taken on a different firmware ($(mzd_backup_meta_value firmware)).\n\nRemoval refused: there is no reliable way back for this state."
        return 1
    fi
    if [ "${MZD_CONFIRMED:-0}" != 1 ]; then
        mzd_ask2 "Remove Android Auto touch?\n\nThe service configuration and the AA XMLs are restored from the backup taken on this car." "Remove" "Cancel" || {
            mzd_log "removal cancelled"
            return 1
        }
    fi
    if ! mzd_prepare_mutation; then
        mzd_popup "Mazda Connect could not be made writable.\n\nNothing was changed."
        return 1
    fi
    MZD_TRANSACTION_ACTIVE=1
    MZD_ROLLBACK_FN=aa_rollback_revert

    aa_restore_stock_files || { aa_abort "The original files could not be restored."; return 1; }
    aa_remove_shims || { aa_abort "The shims could not be removed."; return 1; }

    aa_state_parse
    state=$AA_STATE
    if [ "$state" != clean ]; then
        aa_abort "The final check of the removal failed (state $state: ${AA_STATE_REASON})."
        return 1
    fi
    MZD_TRANSACTION_ACTIVE=0
    MZD_ROLLBACK_FN=""
    mzd_log "removal completely verified"

    if ! mzd_finalize; then
        mzd_popup "The removal was written, but watchdog/rootfs could not be verified afterwards.\n\nRun the diagnosis."
        return 1
    fi
    mzd_popup "Android Auto touch removed; the original files are verified.\n\nAfter the restart Android Auto behaves as from the factory.$(aa_not_yet_hint)"
    if ! mzd_ask_reboot "Android Auto touch is removed."; then
        mzd_popup "The restart (Mazda SafeReboot) could not be requested.\n\nPlease restart Mazda Connect manually.\nThe removal is complete."
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Status (for the diagnosis)
# ---------------------------------------------------------------------------

aa_status() {
    local conf
    if ! aa_verify_payload 2>/dev/null; then
        printf 'aa-mod payload on stick: INVALID/MISSING\n'
        return 0
    fi
    aa_state_parse
    printf 'state=%s\n' "$AA_STATE"
    [ -n "$AA_STATE_REASON" ] && printf 'reason=%s\n' "$AA_STATE_REASON"
    printf 'mod_version=%s\n' "$AA_MOD_VERSION"
    printf 'protocol_v16=%s\n' "$AA_V16"
    printf 'profile=%s\n' "$AA_PROFILE"
    if mzd_real_file "$MZD_AA_STATE_MARKER"; then
        printf 'install_state=%s\n' "$(tr '\n' ' ' <"$MZD_AA_STATE_MARKER")"
    fi
    if aa_backup_find; then
        printf 'backup=%s\n' "$MZD_BACKUP_DIR"
        printf 'backup_firmware=%s\n' "$(mzd_backup_meta_value firmware 2>/dev/null)"
    else
        printf 'backup=none\n'
    fi
    for conf in "$MZD_SM_CONF" "$MZD_SM_WCP"; do
        printf '%s oem-aa-mod lines=%s\n' "$(basename "$conf")" "$(aa_conf_marker_count "$conf" | tr -d '[:space:]')"
    done
    for conf in "$MZD_AA_XML" "$MZD_AA_XML_UCP"; do
        printf '%s variant=%s\n' "$(basename "$conf")" "$(aa_xml_variant "$conf")"
    done
    return 0
}
