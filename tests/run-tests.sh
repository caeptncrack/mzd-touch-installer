#!/bin/sh
# run-tests.sh -- host test suite for the MZD Touch Installer.
#
# Runs without a car on disposable file trees: a fake Mazda Connect root
# (MZD_ROOT) and a fake USB stick built from stick/. Exercises the combined
# install and removal, repair, partial states, the update in place from older
# versions (1.0.0 with Android Auto 1.6, early builds), every injected fault and its
# rollback, the manifest check, the start dialogs, other regions (North
# America) with unknown target binaries, byte-exact removal of files that
# differ from the EU build, and the diagnosis privacy rules.
#
# Usage (any POSIX sh: Git Bash, Linux, macOS, BusyBox ash):
#   sh tests/run-tests.sh
#   MZD_TEST_REAL_ROOTFS=/path/to/rootfs-dump sh tests/run-tests.sh
#
# Optional, stronger evidence:
#   MZD_TEST_REAL_ROOTFS  a dump of a 74.00.324A root file system; the four
#                         configuration files, the three target binaries and
#                         Common.js are then the real ones
#   upstream ZIPs in downloads/ (python3 tools/build_stick.py build --download)
#                         enables the builder test: the real stick with the
#                         real oem-aa-mod and the real TouchTune 1.2.1 is run
#                         against the fake car (with the real rootfs also
#                         TouchTune patches the real Common.js)
#
# Copyright (C) 2026 caeptncrack
# SPDX-License-Identifier: GPL-3.0-or-later

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd) || exit 1
SRC="$REPO/stick"
TESTROOT=$(mktemp -d "${TMPDIR:-/tmp}/mzd-touch-tests.XXXXXX") || exit 1
PASS=0
FAIL=0
PY=""
for candidate in python3 python; do
    if "$candidate" -c 'import sys' >/dev/null 2>&1; then PY="$candidate"; break; fi
done
echo "TESTROOT=$TESTROOT"
echo "python: ${PY:-none (XML checks reduced, builder test skipped)}"

cleanup() {
    if [ "${MZD_TEST_KEEP:-0}" = 1 ]; then
        echo "TESTROOT kept: $TESTROOT"
        return 0
    fi
    rm -rf "$TESTROOT"
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# openssl is optional on a host; the installers fall back to sha256sum, but
# the real TouchTune insists on openssl. Provide a tiny stand-in when missing.
mkdir -p "$TESTROOT/bin"
if ! command -v openssl >/dev/null 2>&1; then
    cat >"$TESTROOT/bin/openssl" <<'EOF'
#!/bin/sh
# Test stand-in: supports only "openssl dgst -sha256 FILE".
[ "$1" = dgst ] && [ "$2" = -sha256 ] && [ -n "${3:-}" ] || exit 1
h=$(sha256sum "$3" | cut -d' ' -f1) || exit 1
printf 'SHA2-256(%s)= %s\n' "$3" "$h"
EOF
    chmod +x "$TESTROOT/bin/openssl"
    PATH="$TESTROOT/bin:$PATH"
    export PATH
    echo "openssl: test stand-in"
fi

# ---------------------------------------------------------------------------
# Check helpers
# ---------------------------------------------------------------------------

ok() {
    PASS=$((PASS + 1))
    printf 'ok   %s\n' "$1"
}

bad() {
    FAIL=$((FAIL + 1))
    printf 'FAIL %s -- %s\n' "$1" "$2"
}

check_eq() {
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$2', got '$3'"; fi
}

check_file() {
    if [ -f "$2" ]; then ok "$1"; else bad "$1" "file missing: $2"; fi
}

check_no_file() {
    if [ ! -e "$2" ]; then ok "$1"; else bad "$1" "unexpected file: $2"; fi
}

check_dir() {
    if [ -d "$2" ]; then ok "$1"; else bad "$1" "folder missing: $2"; fi
}

check_contains() {
    if grep -q -F -- "$3" "$2" 2>/dev/null; then ok "$1"; else bad "$1" "'$3' not in $2"; fi
}

check_not_contains() {
    if grep -q -F -- "$3" "$2" 2>/dev/null; then bad "$1" "'$3' unexpectedly in $2"; else ok "$1"; fi
}

check_hash() {
    actual=$(sha256sum "$2" 2>/dev/null | cut -d' ' -f1)
    check_eq "$1" "$3" "${actual:-missing}"
}

check_rc() {
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "exit code $2 instead of $3"; fi
}

check_rc_nonzero() {
    if [ "$2" != 0 ]; then ok "$1"; else bad "$1" "exit code 0, an error was expected"; fi
}

section() {
    printf '\n## %s\n' "$1"
}

# ---------------------------------------------------------------------------
# Fake Mazda Connect and fake stick
# ---------------------------------------------------------------------------

make_cmu() {
    dest="$1"
    mkdir -p "$dest/jci/sm" "$dest/jci/aapa" "$dest/jci/navi" "$dest/jci/tools" \
        "$dest/jci/scripts" "$dest/jci/gui/common/js" "$dest/usr/bin" "$dest/etc" \
        "$dest/etc/wayland" "$dest/dev/input" "$dest/data_persist" "$dest/data" \
        "$dest/sys/class/gpio/Watchdog Disable" "$dest/sys/class/nvram/nv-config/keys" \
        "$dest/proc" "$dest/tmp"
    cat >"$dest/jci/version.ini" <<'EOF'
[VersionInfo]
JCI_SW_VER="MAZ_CMU-150_74.00.324"
JCI_SW_FLAVOR="cmu150_EU"
JCI_SW_VER_PATCH="A"
EOF
    cat >"$dest/jci/sm/sm.conf" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<services>
    <service type="process" name="aap_service" path="/usr/bin/aap_service" autorun="yes" retry_count="0">
        <dependency type="service" value="devicemanager"/>
    </service>
    <service type="jci_service" name="jciAAPA" path="/jci/aapa/blmjciaapa.so" autorun="yes">
        <dependency type="service" value="aap_service"/>
    </service>
    <service type="jci_service" name="jcinavi" path="/jci/navi/svcjcinavi.so" autorun="yes" args="">
        <dependency type="service" value="jciVBS"/>
    </service>
    <service type="process" name="unrelated" path="/usr/bin/unrelated" autorun="yes">
        <dependency type="service" value="devicemanager"/>
    </service>
</services>
EOF
    sed 's/name="jcinavi" path="\/jci\/navi\/svcjcinavi.so" autorun="yes" args=""/name="jcinavi" path="\/jci\/navi\/svcjcinavi.so" autorun="yes" args="wcp"/' \
        "$dest/jci/sm/sm.conf" >"$dest/jci/sm/sm_WCP.conf"
    printf 'ELF-TEST-BLM\n' >"$dest/jci/aapa/blmjciaapa.so"
    printf 'ELF-TEST-NAVI\n' >"$dest/jci/navi/svcjcinavi.so"
    printf 'ELF-TEST-AAP\n' >"$dest/usr/bin/aap_service"
    printf '### test common.js\n' >"$dest/jci/gui/common/js/Common.js"
    printf 'rootfs / relfs ro 0 0\n' >"$dest/proc/mounts"
    printf '0\n' >"$dest/sys/class/gpio/Watchdog Disable/value"
    printf 'input = /dev/input/filtered-touchscreen0\n' >"$dest/etc/wayland/compositor.conf"
    : >"$dest/dev/input/filtered-touchscreen0"
    # Stand-ins for Mazda's NVRAM setters (the real ones write /sys/class/nvram).
    for setter in set_speed_restriction_config.sh:bus_bcm_speed_restriction \
                  set_lvds_speed_restriction_config.sh:lvds_speed_restriction; do
        cat >"$dest/jci/scripts/${setter%%:*}" <<EOF
#!/bin/sh
keys=\$(cd "\$(dirname "\$0")/../../sys/class/nvram/nv-config/keys" && pwd) || exit 1
case "\$1" in enable|disable) printf '%s\n' "\$1" >"\$keys/${setter#*:}" ;; *) exit 1 ;; esac
EOF
        chmod +x "$dest/jci/scripts/${setter%%:*}"
    done
    cat >"$dest/usr/bin/xmllint" <<EOF
#!/bin/sh
# Test stand-in for xmllint: real well-formedness check with Python if present.
# MZD_TEST_XMLLINT_FAIL=1 fails every file, =stage only staged *.mzd-new files.
file=
for arg in "\$@"; do file="\$arg"; done
case "\${MZD_TEST_XMLLINT_FAIL:-0}:\$file" in
    1:*|stage:*.mzd-new) exit 1 ;;
esac
[ -n "\$file" ] || exit 0
py="$PY"
[ -n "\$py" ] || exit 0
"\$py" -c 'import sys, xml.etree.ElementTree as ET
try:
    ET.parse(sys.argv[1])
except Exception:
    sys.exit(1)' "\$file"
EOF
    chmod +x "$dest/usr/bin/xmllint"
    # Same layout as the 74.00.324A file: par in <display>, fps and the decoder
    # depth outside <resolution>, navigation not subscribed.
    cat >"$dest/etc/aap_system_attributes.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<aap_attributes>
    <head_unit>
        <display>
            <width>800</width>
            <height>480</height>
            <par>10670</par>
        </display>
        <input_devices>
            <key_codes>
                <value>AAP_KEYCODE_BACK</value>
                <value>AAP_KEYCODE_MEDIA_PLAY</value>
                <value>AAP_KEYCODE_MEDIA_NEXT</value>
            </key_codes>
        </input_devices>
    </head_unit>
    <application>
        <video>
            <resolution>
                <value>800x480</value>
                <density>141</density>
            </resolution>
            <codec_profile>
                <value>H.264_BP_L3.1</value>
                <decoder_additional_depth>3</decoder_additional_depth>
            </codec_profile>
            <fps>60</fps>
        </video>
        <subscription_list>
            <media_playback>
                <subscribe>FALSE</subscribe>
            </media_playback>
            <navigation>
                <subscribe>FALSE</subscribe>
            </navigation>
        </subscription_list>
    </application>
</aap_attributes>
EOF
    sed 's/<key_codes>/<key_codes><!-- UCP -->/' "$dest/etc/aap_system_attributes.xml" \
        >"$dest/etc/aap_system_attributes_UCP.xml"
}

REAL=""
if [ -n "${MZD_TEST_REAL_ROOTFS:-}" ]; then
    if [ -f "$MZD_TEST_REAL_ROOTFS/jci/sm/sm.conf" ]; then
        REAL="$MZD_TEST_REAL_ROOTFS"
    else
        echo "WARN: MZD_TEST_REAL_ROOTFS has no jci/sm/sm.conf: $MZD_TEST_REAL_ROOTFS" >&2
    fi
fi

# Replace the synthetic files with real firmware files where available.
apply_real_rootfs() {
    dest="$1"
    [ -n "$REAL" ] || return 0
    for rel in jci/version.ini jci/sm/sm.conf jci/sm/sm_WCP.conf \
               etc/aap_system_attributes.xml etc/aap_system_attributes_UCP.xml \
               jci/aapa/blmjciaapa.so jci/navi/svcjcinavi.so usr/bin/aap_service \
               jci/gui/common/js/Common.js; do
        [ -f "$REAL/$rel" ] && cp "$REAL/$rel" "$dest/$rel"
    done
    echo "  (real firmware files from $REAL)"
}

new_cmu() {
    cmu="$TESTROOT/cmu-$1"
    cp -a "$TESTROOT/cmu-template" "$cmu"
    printf '%s\n' "$cmu"
}

LAUNCHER='$(S=${HOME%root};N=0;J=;for D in sda1 sdb1 sdc1 sdd1;do P=${S}tmp${S}mnt${S}$D;M=$P${S}STICK.ID;[ -f $M ]&&[ -f $P${S}run.sh ]&&{ N=$((N+1));J=$P${S}run.sh;};done;[ $N = 1 ]&&sh $J).up'
TT_LAUNCHER='$(echo fake touchtune launcher).up'

# Build a stick from stick/, with a tiny synthetic oem-aa-mod and a fake
# TouchTune that records its calls and environment.
make_stick() {
    dest="$1"
    v16="${2:-false}"
    mkdir -p "$dest/lib" "$dest/payload" "$dest/aa-mod" "$dest/touchtune/lib" "$dest/touchtune/patches"
    cp "$SRC/run.sh" "$dest/run.sh"
    for f in mzd-safety.sh aa-touch.sh combined.sh; do cp "$SRC/lib/$f" "$dest/lib/$f"; done
    printf 'fake touchtune launcher\n' >"$dest/lib/touchtune-launcher"
    for f in install.sh uninstall.sh diagnose.sh; do cp "$SRC/payload/$f" "$dest/payload/$f"; done
    cp "$REPO/VERSION" "$dest/VERSION"
    printf 'mzd-touch-installer-v1\n' >"$dest/STICK.ID"
    : >"$dest/jci-autoupdate"
    : >"$dest/$LAUNCHER"
    printf '%s\n' "$LAUNCHER" >"$dest/LAUNCHER.NAME"
    printf '0.10.0\n' >"$dest/aa-mod/VERSION"
    # The shims do not depend on the profile (same oem-aa-mod release).
    printf 'SHIM-BLM\n' >"$dest/aa-mod/libpatch-blmjciaapa.so"
    printf 'SHIM-NAVI\n' >"$dest/aa-mod/libpatch-svcjcinavi.so"
    printf 'SHIM-AAP\n' >"$dest/aa-mod/libpatch-aap_service.so"
    printf '# test libpatch.conf\ntouch = true\nhud = true\nuse_protocol_v1_6 = %s\n' "$v16" \
        >"$dest/aa-mod/libpatch.conf"
    cat >"$dest/aa-mod/aap_system_attributes.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<aap_attributes>
    <head_unit>
        <input_devices>
            <touch_screen>
                <use_internally>true</use_internally>
                <path>/dev/input/filtered-touchscreen0</path>
                <type>AAP_TOUCH_SCREEN_TYPE_CAPACITIVE</type>
                <as_secondary_input>false</as_secondary_input>
            </touch_screen>
            <key_codes>
                <value>AAP_KEYCODE_BACK</value>
            </key_codes>
        </input_devices>
    </head_unit>
</aap_attributes>
EOF
    sed 's#<use_internally>true</use_internally>#<use_internally>false</use_internally>#' \
        "$dest/aa-mod/aap_system_attributes.xml" >"$dest/aa-mod/aap_system_attributes_UCP.xml"
    : >"$dest/aa-mod/SHA256SUMS"
    for f in libpatch-blmjciaapa.so libpatch-svcjcinavi.so libpatch-aap_service.so \
             aap_system_attributes.xml aap_system_attributes_UCP.xml libpatch.conf; do
        printf '%s  %s\n' "$(sha256sum "$dest/aa-mod/$f" | cut -d' ' -f1)" "$f" >>"$dest/aa-mod/SHA256SUMS"
    done
    cat >"$dest/touchtune/install-patches.sh" <<'TTEOF'
#!/bin/sh
# Fake TouchTune: records the call and its environment, then sets a state.
DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd) || exit 1
printf '%s\n' "$*" >>"$DIR/.tt-calls"
env | sort >"$DIR/.tt-env"
if [ -f "${MZD_ROOT:-}/tmp/tt-fail" ]; then exit 1; fi
if [ "$1" = "--restore" ]; then printf 'stock\n' >"$DIR/.tt-state"; else printf 'installed\n' >"$DIR/.tt-state"; fi
exit 0
TTEOF
    printf '#!/bin/sh\n' >"$dest/touchtune/lib/touchtune-helpers.sh"
    printf '#!/bin/sh\n' >"$dest/touchtune/patches/touch-while-driving.sh"
    printf '8f  x\n' >"$dest/touchtune/PAYLOAD.SHA256"
    printf 'touchtune-oss-v2\n' >"$dest/touchtune/TOUCHTUNE.ID"
    printf '1.2.1\n' >"$dest/touchtune/VERSION"
    printf '%s\n' "$TT_LAUNCHER" >"$dest/touchtune/LAUNCHER.NAME"
    : >"$dest/touchtune/jci-autoupdate"
    printf 'fake license\n' >"$dest/touchtune/LICENSE"
    printf 'fake notice\n' >"$dest/touchtune/NOTICE"
    printf 'fake source\n' >"$dest/touchtune/SOURCE.txt"
    printf '#!/bin/sh\n' >"$dest/touchtune/macos-usb-eject.sh"
    printf 'stock\n' >"$dest/touchtune/.tt-state"
    : >"$dest/PAYLOAD.SHA256"
    for rel in VERSION STICK.ID LAUNCHER.NAME jci-autoupdate run.sh \
        lib/mzd-safety.sh lib/aa-touch.sh lib/combined.sh lib/touchtune-launcher \
        payload/install.sh payload/uninstall.sh payload/diagnose.sh aa-mod/SHA256SUMS \
        touchtune/install-patches.sh touchtune/lib/touchtune-helpers.sh \
        touchtune/patches/touch-while-driving.sh touchtune/PAYLOAD.SHA256 \
        touchtune/TOUCHTUNE.ID touchtune/VERSION touchtune/LAUNCHER.NAME \
        touchtune/jci-autoupdate touchtune/LICENSE touchtune/NOTICE \
        touchtune/SOURCE.txt touchtune/macos-usb-eject.sh; do
        printf '%s  %s\n' "$(sha256sum "$dest/$rel" | cut -d' ' -f1)" "$rel" >>"$dest/PAYLOAD.SHA256"
    done
}

new_stick() {
    stick="$TESTROOT/stick-$1"
    make_stick "$stick" "${2:-false}"
    printf '%s\n' "$stick"
}

# run_stick <cmu> <stick> <action> [fault] [dialog sequence] [extra env]
#   action "-" = no ACTION.txt (start dialog); "" = empty ACTION.txt
#   dialog sequence: button numbers in order ("0 1"); afterwards every
#   dialog answers with its first button
run_stick() {
    cmu="$1"
    stick="$2"
    action="$3"
    fault="${4:-}"
    seq="${5:-}"
    extra="${6:-}"
    if [ "$action" = - ]; then
        rm -f "$stick/ACTION.txt"
    else
        printf '%s\n' "$action" >"$stick/ACTION.txt"
    fi
    (
        cd "$stick" || exit 99
        # shellcheck disable=SC2086
        env MZD_TEST_MODE=1 MZD_ROOT="$cmu" MZD_STICK="$stick" MZD_TEST_DIALOG_RC=0 \
            MZD_TEST_DIALOG_SEQ="$seq" MZD_TEST_FAULT="$fault" $extra \
            sh ./run.sh >"$TESTROOT/run.log" 2>&1
    )
}

# Hashes of the four files the Android Auto part changes.
stock_sums() {
    for f in jci/sm/sm.conf jci/sm/sm_WCP.conf etc/aap_system_attributes.xml \
             etc/aap_system_attributes_UCP.xml; do
        [ -f "$1/$f" ] || continue
        printf '%s  %s\n' "$(sha256sum "$1/$f" | cut -d' ' -f1)" "$f"
    done
}

check_stock_unchanged() {
    if [ "$3" = "$(stock_sums "$2")" ]; then ok "$1"; else bad "$1" "the original files were changed"; fi
}

check_no_stages() {
    found=$(find "$2" -name '*.mzd-new' -o -name '*.mzd-verify' 2>/dev/null | head -n 1)
    if [ -z "$found" ]; then ok "$1"; else bad "$1" "stage file left behind: $found"; fi
}

xml_well_formed() {
    [ -n "$PY" ] || return 0
    "$PY" -c 'import sys, xml.etree.ElementTree as ET
try:
    ET.parse(sys.argv[1])
except Exception:
    sys.exit(1)' "$1" 2>/dev/null
}

check_xmls() {
    bad_xml=0
    for f in "$2/jci/sm/sm.conf" "$2/jci/sm/sm_WCP.conf" \
             "$2/etc/aap_system_attributes.xml" "$2/etc/aap_system_attributes_UCP.xml"; do
        xml_well_formed "$f" || { bad_xml=1; printf '   not well-formed: %s\n' "$f"; }
    done
    if [ "$bad_xml" = 0 ]; then ok "$1"; else bad "$1" "XML not well-formed"; fi
}

check_wiring() {
    expected="            <environ_var env_name=\"LD_PRELOAD\" env_value=\"/data_persist/oem-aa-mod/$5\"/>"
    svc_line=$(grep -n "<service [^>]*name=\"$4\"" "$2/$3" | head -n 1 | cut -d: -f1)
    our_line=$(grep -n -F -- "$expected" "$2/$3" | head -n 1 | cut -d: -f1)
    if [ -n "$svc_line" ] && [ -n "$our_line" ] && [ "$our_line" -eq $((svc_line + 1)) ]; then
        ok "$1"
    else
        bad "$1" "wiring $3/$4/$5 (service=$svc_line, preload=$our_line)"
    fi
}

count_markers() {
    grep -c -F 'env_value="/data_persist/oem-aa-mod/' "$1" 2>/dev/null | tr -d '[:space:]'
}

backup_count() {
    find "$1/data_persist/mzd-aa-touch/backups" -maxdepth 1 -type d -name '[0-9]*' 2>/dev/null | wc -l | tr -d '[:space:]'
}

# Backup named in the installation marker.
marker_backup() {
    sed -n 's/^backup=//p' "$1/data_persist/oem-aa-mod/install-state" 2>/dev/null
}

# check_xml_patched <label> <installed-xml> <factory-xml> <true|false>
# The installed AA XML is the factory file plus exactly the oem-aa-mod touch
# entries: <display> and <video> untouched, no real_density, touch block,
# MEDIA_PAUSE and cluster_type once, navigation subscribed; taking the added
# lines out again gives the factory file byte for byte.
check_xml_patched() {
    label="$1"; live="$2"; base="$3"; ui="$4"
    why=""
    for want in '<touch_screen>' "<use_internally>$ui</use_internally>" \
                '<value>AAP_KEYCODE_MEDIA_PAUSE</value>' '<cluster_type>ENUM</cluster_type>'; do
        n=$(grep -c -F -- "$want" "$live" 2>/dev/null | tr -d '[:space:]')
        [ "${n:-0}" = 1 ] || why="$why $want ${n:-0}x;"
    done
    grep -q 'real_density' "$live" && why="$why real_density present;"
    nav=$(awk '/<navigation>/ { getline; print; exit }' "$live" | tr -d ' \t\r')
    [ "$nav" = '<subscribe>TRUE</subscribe>' ] || why="$why navigation '$nav';"
    for block in display video; do
        a=$(sed -n "/<$block>/,/<\/$block>/p" "$base" | sha256sum | cut -d' ' -f1)
        b=$(sed -n "/<$block>/,/<\/$block>/p" "$live" | sha256sum | cut -d' ' -f1)
        [ "$a" = "$b" ] || why="$why <$block> changed;"
    done
    printf '%s\n' '<touch_screen>' '</touch_screen>' "<use_internally>$ui</use_internally>" \
        '<path>/dev/input/filtered-touchscreen0</path>' '<type>AAP_TOUCH_SCREEN_TYPE_CAPACITIVE</type>' \
        '<as_secondary_input>false</as_secondary_input>' '<cluster_type>ENUM</cluster_type>' >"$TESTROOT/xml-added"
    grep -q 'AAP_KEYCODE_MEDIA_PAUSE' "$base" || printf '%s\n' 'AAP_KEYCODE_MEDIA_PAUSE' >>"$TESTROOT/xml-added"
    navbase=$(awk '/<navigation>/ { getline; print; exit }' "$base" | tr -d ' \t\r')
    grep -v -F -f "$TESTROOT/xml-added" "$live" | \
        sed "/<navigation>/{n;s#<subscribe>TRUE</subscribe>#$navbase#;}" >"$TESTROOT/xml-back"
    [ "$(sha256sum <"$TESTROOT/xml-back" | cut -d' ' -f1)" = "$(sha256sum <"$base" | cut -d' ' -f1)" ] || \
        why="$why other lines differ from the factory file;"
    if [ -z "$why" ]; then ok "$label"; else bad "$label" "$why"; fi
}

# Every line of the file ends in CR LF.
all_crlf() {
    [ "$(tr -cd '\r' <"$1" | wc -c | tr -d '[:space:]')" = "$(wc -l <"$1" | tr -d '[:space:]')" ]
}

tt_calls() {
    if [ -f "$1/touchtune/.tt-calls" ]; then
        grep -c -e "$2" "$1/touchtune/.tt-calls" | tr -d '[:space:]'
    else
        printf '0\n'
    fi
}

# Source the three libraries in a subshell for unit-level checks.
lib_eval() {
    cmu="$1"
    shift
    (
        MZD_TEST_MODE=1
        MZD_ROOT="$cmu"
        MZD_STICK="$TESTROOT/no-stick"
        export MZD_TEST_MODE MZD_ROOT MZD_STICK
        mkdir -p "$MZD_STICK"
        . "$SRC/lib/mzd-safety.sh"
        . "$SRC/lib/aa-touch.sh"
        . "$SRC/lib/combined.sh"
        eval "$*"
    ) 2>/dev/null
}

# ===========================================================================
# Tests
# ===========================================================================

section 'Prepare the fixture'
make_cmu "$TESTROOT/cmu-template"
apply_real_rootfs "$TESTROOT/cmu-template"
printf 'template CMU: %s\n' "$TESTROOT/cmu-template"

# ---------------------------------------------------------------------------
section 'Library: root file system probes'
WP="$TESTROOT/writeprobe"
mkdir -p "$WP/jci" "$WP/etc"
check_eq 'write probe: writable' writable "$(lib_eval "$WP" 'mzd_root_write_probe && echo writable || echo not-writable')"
check_eq 'write probe: not writable' not-writable \
    "$(lib_eval "$TESTROOT/does-not-exist" 'mzd_root_write_probe && echo writable || echo not-writable')"
MODDIR="$TESTROOT/mode-test"
mkdir -p "$MODDIR"
printf 'x\n' >"$MODDIR/f"
chmod 644 "$MODDIR/f"
check_eq 'mode 0644 == 644' yes "$(lib_eval "$WP" "mzd_mode_equals '$MODDIR/f' 0644 && echo yes || echo no")"
check_eq 'mode 644 == 644' yes "$(lib_eval "$WP" "mzd_mode_equals '$MODDIR/f' 644 && echo yes || echo no")"
check_eq 'mode 755 != 644' no "$(lib_eval "$WP" "mzd_mode_equals '$MODDIR/f' 755 && echo yes || echo no")"
MFIX="$TESTROOT/mounts-fixture"
mkdir -p "$MFIX/proc"
printf 'rootfs / rootfs rw 0 0\n/dev/ffx01p1 / relfs ro,noatime 0 0\n' >"$MFIX/proc/mounts"
check_eq 'stacked mounts: top relfs ro' ro-yes "$(lib_eval "$MFIX" 'mzd_root_is_read_only && echo ro-yes || echo ro-no')"
check_eq 'stacked mounts: not rw' rw-no "$(lib_eval "$MFIX" 'mzd_root_is_writable && echo rw-yes || echo rw-no')"
printf 'rootfs / rootfs rw 0 0\n/dev/ffx01p1 / relfs rw,noatime 0 0\n' >"$MFIX/proc/mounts"
check_eq 'stacked mounts rw: not ro' ro-no "$(lib_eval "$MFIX" 'mzd_root_is_read_only && echo ro-yes || echo ro-no')"
check_eq 'stacked mounts rw: rw' rw-yes "$(lib_eval "$MFIX" 'mzd_root_is_writable && echo rw-yes || echo rw-no')"

# ---------------------------------------------------------------------------
section 'Library: firmware recognition (all regions of 74.00.324)'
FW="$TESTROOT/fw"
mkdir -p "$FW/jci"
fw_case() {
    printf '[VersionInfo]\nJCI_SW_VER="%s"\nJCI_SW_FLAVOR="%s"\nJCI_SW_VER_PATCH="%s"\n' "$1" "$2" "$3" >"$FW/jci/version.ini"
    lib_eval "$FW" 'if mzd_require_firmware; then echo "ok $MZD_FW $MZD_FW_FLAVOR"; else echo refused; fi'
}
check_eq 'EU 74.00.324A accepted' 'ok 74.00.324A cmu150_EU' "$(fw_case MAZ_CMU-150_74.00.324 cmu150_EU A)"
check_eq 'North America 74.00.324A accepted' 'ok 74.00.324A cmu150_NA' "$(fw_case MAZ_CMU-150_74.00.324 cmu150_NA A)"
check_eq '74.00.324 without patch accepted' 'ok 74.00.324 cmu150_EU' "$(fw_case MAZ_CMU-150_74.00.324 cmu150_EU '')"
check_eq 'lower-case patch letter' 'ok 74.00.324A cmu150_JP' "$(fw_case MAZ_CMU-150_74.00.324 cmu150_JP a)"
check_eq '74.00.311A refused' refused "$(fw_case MAZ_CMU-150_74.00.311 cmu150_EU A)"
check_eq '70.00.100 refused' refused "$(fw_case MAZ_CMU-150_70.00.100 cmu150_NA A)"
rm -f "$FW/jci/version.ini"
check_eq 'missing version.ini refused' refused "$(lib_eval "$FW" 'mzd_require_firmware && echo ok || echo refused')"

# ---------------------------------------------------------------------------
section 'Library: TouchTune state (no test hook)'
TTU=$(new_cmu tt-unit)
printf '### unit test common.js\n' >"$TTU/jci/gui/common/js/Common.js"
check_eq 'unknown Common.js = foreign' foreign "$(lib_eval "$TTU" combined_tt_state)"
fake_sha=$(sha256sum "$TTU/jci/gui/common/js/Common.js" | cut -d' ' -f1)
check_eq 'stock Common.js, no NVRAM keys = stock' stock \
    "$(lib_eval "$TTU" "MZD_TT_STOCK_SHA=$fake_sha; combined_tt_state")"
printf 'disable\n' >"$TTU/sys/class/nvram/nv-config/keys/bus_bcm_speed_restriction"
printf 'disable\n' >"$TTU/sys/class/nvram/nv-config/keys/lvds_speed_restriction"
check_eq 'stock Common.js + NVRAM disable = partial' partial \
    "$(lib_eval "$TTU" "MZD_TT_STOCK_SHA=$fake_sha; combined_tt_state")"
check_eq 'patched Common.js + NVRAM disable = installed' installed \
    "$(lib_eval "$TTU" "MZD_TT_PATCHED_SHA=$fake_sha; combined_tt_state")"
printf 'garbage\n' >"$TTU/sys/class/nvram/nv-config/keys/lvds_speed_restriction"
check_eq 'invalid NVRAM value = foreign' foreign \
    "$(lib_eval "$TTU" "MZD_TT_PATCHED_SHA=$fake_sha; combined_tt_state")"
rm -f "$TTU/jci/gui/common/js/Common.js"
check_eq 'missing Common.js = missing' missing "$(lib_eval "$TTU" combined_tt_state)"

# ---------------------------------------------------------------------------
section 'Install both (ACTION.txt install)'
CMU=$(new_cmu install)
STICK=$(new_stick install)
BEFORE=$(stock_sums "$CMU")
run_stick "$CMU" "$STICK" install
check_rc 'install exit code' "$?" 0
check_contains 'payload verified (25 files)' "$TESTROOT/run.log" 'payload completely verified (25 files)'
check_no_file 'fresh stick: no TouchTune launcher in touchtune/' "$(new_stick fresh-check)/touchtune/$TT_LAUNCHER"
check_contains 'TouchTune launcher written' "$TESTROOT/run.log" 'TouchTune launcher written to the stick'
check_hash 'TouchTune launcher = lib copy' "$STICK/touchtune/$TT_LAUNCHER" \
    "$(sha256sum "$STICK/lib/touchtune-launcher" | cut -d' ' -f1)"
check_eq 'one .up in touchtune/' 1 "$(find "$STICK/touchtune" -maxdepth 1 -name '*.up' | wc -l | tr -d '[:space:]')"
check_no_file 'no temporary launcher left' "$STICK/touchtune/.launcher.tmp"
check_contains 'ACTION.txt asked for confirmation' "$TESTROOT/run.log" 'Selected: Install (ACTION.txt)'
check_contains 'confirmation says when to pull the stick' "$TESTROOT/run.log" 'Pull it only when the screen tells you to.'
check_eq 'sm.conf markers' 2 "$(count_markers "$CMU/jci/sm/sm.conf")"
check_eq 'sm_WCP.conf markers' 2 "$(count_markers "$CMU/jci/sm/sm_WCP.conf")"
check_wiring 'jciAAPA wired (sm.conf)' "$CMU" jci/sm/sm.conf jciAAPA libpatch-blmjciaapa.so
check_wiring 'jcinavi wired (sm.conf)' "$CMU" jci/sm/sm.conf jcinavi libpatch-svcjcinavi.so
check_not_contains 'aap_service not preloaded (Android Auto 1.5)' "$CMU/jci/sm/sm.conf" 'libpatch-aap_service.so'
check_wiring 'jciAAPA wired (sm_WCP.conf)' "$CMU" jci/sm/sm_WCP.conf jciAAPA libpatch-blmjciaapa.so
check_xml_patched 'AA XML = factory file + touch (video untouched)' "$CMU/etc/aap_system_attributes.xml" \
    "$TESTROOT/cmu-template/etc/aap_system_attributes.xml" true
check_xml_patched 'UCP XML = factory file + touch (video untouched)' "$CMU/etc/aap_system_attributes_UCP.xml" \
    "$TESTROOT/cmu-template/etc/aap_system_attributes_UCP.xml" false
check_contains 'AA XML logged as patched' "$TESTROOT/run.log" "AA XML verified: aap_system_attributes.xml (car's file + touch"
check_eq 'marker names the backup' "$(basename "$(ls -d "$CMU"/data_persist/mzd-aa-touch/backups/[0-9]* | head -n1)")" \
    "$(marker_backup "$CMU")"
check_file 'shim blmjciaapa installed' "$CMU/data_persist/oem-aa-mod/libpatch-blmjciaapa.so"
check_no_file 'no aap_service shim (Android Auto 1.5)' "$CMU/data_persist/oem-aa-mod/libpatch-aap_service.so"
check_contains 'install marker: GAL 1.6 off' "$CMU/data_persist/oem-aa-mod/install-state" 'protocol_v16=0'
check_contains 'install marker: installer version' "$CMU/data_persist/oem-aa-mod/install-state" \
    "installer=$(tr -d '\r\n' <"$REPO/VERSION")"
check_not_contains 'fresh install: no previous installer' "$CMU/data_persist/oem-aa-mod/install-state" 'previous_installer='
check_contains 'libpatch.conf on the car: 1.6 off' "$CMU/data_persist/oem-aa-mod/libpatch.conf" 'use_protocol_v1_6 = false'
check_eq 'exactly one backup on the car' 1 "$(backup_count "$CMU")"
check_xmls 'XML well-formed after install' "$CMU"
check_no_stages 'no stage files left' "$CMU"
check_dir 'backup copy on the stick' "$(ls -d "$STICK"/backup-aa-touch-* 2>/dev/null | head -n1)"
check_eq 'TouchTune install called once' 1 "$(tt_calls "$STICK" touch-while-driving)"
check_contains 'TouchTune state installed' "$STICK/touchtune/.tt-state" installed
check_contains 'TouchTune child exit logged' "$TESTROOT/run.log" 'TouchTune child exit=0'
check_not_contains 'child env: no MZD_BACKUP_ROOT' "$STICK/touchtune/.tt-env" 'MZD_BACKUP_ROOT'
check_not_contains 'child env: no MZD_SKIP_REBOOT' "$STICK/touchtune/.tt-env" 'MZD_SKIP_REBOOT'
check_not_contains 'child env: no MZD_CONFIRMED' "$STICK/touchtune/.tt-env" 'MZD_CONFIRMED'
check_contains 'AA restart deferred to TouchTune' "$TESTROOT/run.log" 'restart deferred (MZD_SKIP_REBOOT=1)'
check_no_file 'guard removed' "$CMU/tmp/mzd-usb-installer.guard"
check_contains 'working message right after the confirmation' "$TESTROOT/run.log" 'POPUP: Installing...'
check_contains 'working message for the AA part' "$TESTROOT/run.log" 'POPUP: Installing Android Auto touch...'
check_contains 'AA done: the stick stays in for TouchTune' "$TESTROOT/run.log" 'Do not pull the stick yet.'
check_not_contains 'TouchTune keeps its own last message' "$TESTROOT/run.log" 'You can pull the stick now'

section 'Run again: nothing to do'
AFTER1=$(stock_sums "$CMU")
run_stick "$CMU" "$STICK" install
check_rc 'second install exit code' "$?" 0
check_contains 'already installed reported' "$TESTROOT/run.log" 'already installed'
check_contains 'nothing to do: the stick may be pulled' "$TESTROOT/run.log" 'There is nothing to do.\n\nYou can pull the stick now.'
check_eq 'TouchTune not called again' 1 "$(tt_calls "$STICK" touch-while-driving)"
check_eq 'still one backup' 1 "$(backup_count "$CMU")"
check_eq 'result unchanged' "$AFTER1" "$(stock_sums "$CMU")"

section 'Status'
run_stick "$CMU" "$STICK" status
check_rc 'status exit code' "$?" 0
check_contains 'status: AA ours' "$TESTROOT/run.log" 'state=ours'
check_contains 'status: XML variant factory+touch' "$TESTROOT/run.log" 'aap_system_attributes.xml variant=factory+touch'
check_contains 'status: TouchTune installed' "$TESTROOT/run.log" 'touchtune=installed'

section 'Remove both (ACTION.txt uninstall)'
run_stick "$CMU" "$STICK" uninstall
check_rc 'removal exit code' "$?" 0
check_stock_unchanged 'original files byte-identical' "$CMU" "$BEFORE"
check_no_file 'shims removed' "$CMU/data_persist/oem-aa-mod/libpatch-blmjciaapa.so"
check_no_file 'install marker removed' "$CMU/data_persist/oem-aa-mod/install-state"
check_dir 'removed shims kept aside on the car' "$(ls -d "$CMU"/data_persist/mzd-aa-touch/removed/* 2>/dev/null | head -n1)"
check_xmls 'XML well-formed after removal' "$CMU"
check_eq 'TouchTune --restore called' 1 "$(tt_calls "$STICK" --restore)"
check_contains 'TouchTune state stock' "$STICK/touchtune/.tt-state" stock
run_stick "$CMU" "$STICK" status
check_contains 'status: clean again' "$TESTROOT/run.log" 'state=clean'

section 'Remove when nothing is installed'
CMU2=$(new_cmu revert-clean)
STICK2=$(new_stick revert-clean)
BEFORE2=$(stock_sums "$CMU2")
run_stick "$CMU2" "$STICK2" uninstall
check_rc 'exit code' "$?" 0
check_stock_unchanged 'nothing changed' "$CMU2" "$BEFORE2"
check_eq 'no backup created' 0 "$(backup_count "$CMU2")"
check_contains 'nothing to remove reported' "$TESTROOT/run.log" 'Nothing to remove'
check_contains 'nothing to remove: the stick may be pulled' "$TESTROOT/run.log" 'You can pull the stick now.'
check_eq 'TouchTune not called' 0 "$(tt_calls "$STICK2" .)"

# ---------------------------------------------------------------------------
section 'Partial states'
CMUP=$(new_cmu partial-tt)
STICKP=$(new_stick partial-tt)
run_stick "$CMUP" "$STICKP" install
printf 'stock\n' >"$STICKP/touchtune/.tt-state"
run_stick "$CMUP" "$STICKP" install
check_rc 'AA installed, TouchTune stock: exit code' "$?" 0
check_eq 'only TouchTune runs the second time' 2 "$(tt_calls "$STICKP" touch-while-driving)"
check_eq 'AA unchanged (one backup)' 1 "$(backup_count "$CMUP")"
awk '!/libpatch-svcjcinavi.so/' "$CMUP/jci/sm/sm.conf" >"$CMUP/sm.tmp" && mv "$CMUP/sm.tmp" "$CMUP/jci/sm/sm.conf"
run_stick "$CMUP" "$STICKP" install
check_rc 'AA partial, TouchTune installed: exit code' "$?" 0
check_contains 'repair uses the existing backup' "$TESTROOT/run.log" 'repair with the existing backup'
check_eq 'repaired: 2 markers again' 2 "$(count_markers "$CMUP/jci/sm/sm.conf")"
check_eq 'TouchTune not called for an AA repair' 2 "$(tt_calls "$STICKP" touch-while-driving)"
check_contains 'restart asked once at the end' "$TESTROOT/run.log" 'TEST: SafeReboot would be requested now'
printf 'partial\n' >"$STICKP/touchtune/.tt-state"
run_stick "$CMUP" "$STICKP" install
check_eq 'TouchTune partial is repaired by TouchTune' 3 "$(tt_calls "$STICKP" touch-while-driving)"
printf 'partial\n' >"$STICKP/touchtune/.tt-state"
run_stick "$CMUP" "$STICKP" uninstall
check_rc 'removal from partial TouchTune' "$?" 0
check_eq 'TouchTune --restore for partial' 1 "$(tt_calls "$STICKP" --restore)"
check_eq 'AA removed as well' 0 "$(count_markers "$CMUP/jci/sm/sm.conf")"

# ---------------------------------------------------------------------------
section 'Stick with GAL 1.6 on (use_protocol_v1_6 = true, profile B)'
CMU3=$(new_cmu v16on)
STICK3=$(new_stick v16on true)
run_stick "$CMU3" "$STICK3" install
check_rc 'install exit code' "$?" 0
check_eq '3 markers' 3 "$(count_markers "$CMU3/jci/sm/sm.conf")"
check_wiring 'aap_service wired (sm.conf)' "$CMU3" jci/sm/sm.conf aap_service libpatch-aap_service.so
check_wiring 'aap_service wired (sm_WCP.conf)' "$CMU3" jci/sm/sm_WCP.conf aap_service libpatch-aap_service.so
check_file 'aap_service shim installed' "$CMU3/data_persist/oem-aa-mod/libpatch-aap_service.so"
check_contains 'marker: GAL 1.6 on' "$CMU3/data_persist/oem-aa-mod/install-state" 'protocol_v16=1'
run_stick "$CMU3" "$STICK3" status
check_contains 'GAL 1.6 stick: its own install is ours' "$TESTROOT/run.log" 'state=ours'

# ---------------------------------------------------------------------------
section 'AA XML: the car file is patched, not replaced'
# save_bases <cmu>: keep the factory XMLs of this car for check_xml_patched.
save_bases() {
    for n in aap_system_attributes.xml aap_system_attributes_UCP.xml; do
        cp "$1/etc/$n" "$1.base-$n"
    done
}
# xml_edit <cmu> <awk program>: rewrite both factory XMLs of a test car.
xml_edit() {
    for n in aap_system_attributes.xml aap_system_attributes_UCP.xml; do
        awk "$2" "$1/etc/$n" >"$1/xml.tmp" && mv "$1/xml.tmp" "$1/etc/$n"
    done
}

CMUL=$(new_cmu legacy-xml)
STICKL=$(new_stick legacy-xml)
BEFOREL=$(stock_sums "$CMUL")
run_stick "$CMUL" "$STICKL" install
# An install by an earlier version: the oem-aa-mod XML itself, no backup= line.
cp "$STICKL/aa-mod/aap_system_attributes.xml" "$CMUL/etc/aap_system_attributes.xml"
cp "$STICKL/aa-mod/aap_system_attributes_UCP.xml" "$CMUL/etc/aap_system_attributes_UCP.xml"
sed '/^backup=/d' "$CMUL/data_persist/oem-aa-mod/install-state" >"$CMUL/state.tmp" && \
    mv "$CMUL/state.tmp" "$CMUL/data_persist/oem-aa-mod/install-state"
run_stick "$CMUL" "$STICKL" status
check_contains 'earlier install (oem-aa-mod XML): outdated' "$TESTROOT/run.log" 'state=outdated'
check_contains 'earlier install: XML variant named' "$TESTROOT/run.log" 'aap_system_attributes.xml variant=oem-aa-mod-file'
run_stick "$CMUL" "$STICKL" uninstall
check_rc 'earlier install: removal exit code' "$?" 0
check_stock_unchanged 'earlier install: originals byte-identical' "$CMUL" "$BEFOREL"

CMUY=$(new_cmu xml-layout)
STICKY=$(new_stick xml-layout)
xml_edit "$CMUY" '/<navigation>/ { skip = 3 } skip > 0 { skip--; next } { print }'
BEFOREY=$(stock_sums "$CMUY")
run_stick "$CMUY" "$STICKY" install
check_rc 'unknown XML layout: TouchTune alone accepted' "$?" 0
check_contains 'unknown XML layout: reason logged' "$TESTROOT/run.log" 'has an unexpected layout (touch cannot be added safely)'
check_contains 'unknown XML layout: TouchTune alone offered' "$TESTROOT/run.log" 'Install only TouchTune'
check_stock_unchanged 'unknown XML layout: AA files untouched' "$CMUY" "$BEFOREY"
check_eq 'unknown XML layout: no backup' 0 "$(backup_count "$CMUY")"
check_eq 'unknown XML layout: TouchTune installed' 1 "$(tt_calls "$STICKY" touch-while-driving)"

CMUQ=$(new_cmu xml-no-play)
STICKQ=$(new_stick xml-no-play)
xml_edit "$CMUQ" 'index($0, "<value>AAP_KEYCODE_MEDIA_PLAY</value>") == 0 { print }'
save_bases "$CMUQ"
BEFOREQ=$(stock_sums "$CMUQ")
run_stick "$CMUQ" "$STICKQ" install
check_rc 'no MEDIA_PLAY key: install exit code' "$?" 0
check_xml_patched 'no MEDIA_PLAY key: factory file + touch' "$CMUQ/etc/aap_system_attributes.xml" \
    "$CMUQ.base-aap_system_attributes.xml" true
check_eq 'no MEDIA_PLAY key: MEDIA_PAUSE is the last key' '<value>AAP_KEYCODE_MEDIA_PAUSE</value>' \
    "$(awk '/<\/key_codes>/ { print prev; exit } { prev = $0 }' "$CMUQ/etc/aap_system_attributes.xml" | tr -d ' \t\r')"
run_stick "$CMUQ" "$STICKQ" uninstall
check_stock_unchanged 'no MEDIA_PLAY key: originals byte-identical' "$CMUQ" "$BEFOREQ"

# Git Bash's gawk reads files in text mode and drops the CR of CR LF (the
# car's BusyBox awk keeps it), so the CRLF case only runs where awk keeps CR.
printf 'a\r\n' >"$TESTROOT/crlf-probe"
if [ "$(awk '{ print }' "$TESTROOT/crlf-probe" | tr -cd '\r' | wc -c | tr -d '[:space:]')" = 1 ]; then
    CMUR=$(new_cmu xml-crlf)
    STICKR=$(new_stick xml-crlf)
    xml_edit "$CMUR" '{ print } index($0, "<value>AAP_KEYCODE_MEDIA_PLAY</value>") > 0 { sub(/MEDIA_PLAY/, "MEDIA_PAUSE"); print }'
    xml_edit "$CMUR" '{ printf "%s\r\n", $0 }'
    save_bases "$CMUR"
    BEFORER=$(stock_sums "$CMUR")
    run_stick "$CMUR" "$STICKR" install
    check_rc 'CRLF file with MEDIA_PAUSE: install exit code' "$?" 0
    check_xml_patched 'CRLF file with MEDIA_PAUSE: factory file + touch' "$CMUR/etc/aap_system_attributes_UCP.xml" \
        "$CMUR.base-aap_system_attributes_UCP.xml" false
    if all_crlf "$CMUR/etc/aap_system_attributes.xml"; then ok 'CRLF file: added lines end in CR LF too'; \
        else bad 'CRLF file: added lines end in CR LF too' 'mixed line endings'; fi
    run_stick "$CMUR" "$STICKR" uninstall
    check_stock_unchanged 'CRLF file: originals byte-identical' "$CMUR" "$BEFORER"
else
    printf 'skip CRLF XML case (this awk drops CR when reading a file, e.g. Git Bash gawk)\n'
fi

# ---------------------------------------------------------------------------
section 'Update in place from older versions'
TPL_SUMS=$(stock_sums "$TESTROOT/cmu-template")
NEWVER=$(tr -d '\r\n' <"$REPO/VERSION")
# old_install <name>: a car with an installation by installer 1.0.0 (Android
# Auto 1.6: aap_service shim and LD_PRELOAD line, use_protocol_v1_6 = true).
old_install() {
    oc=$(new_cmu "old-$1")
    os="$TESTROOT/stick-old-$1"
    make_stick "$os" true
    run_stick "$oc" "$os" install
    sed 's/^installer=.*/installer=1.0.0/' "$oc/data_persist/oem-aa-mod/install-state" >"$oc/state.tmp" && \
        mv "$oc/state.tmp" "$oc/data_persist/oem-aa-mod/install-state"
    printf '%s\n' "$oc"
}
marker_has() {
    grep -q -x -F -- "$2" "$1/data_persist/oem-aa-mod/install-state" 2>/dev/null
}

CMUU=$(old_install a)
check_eq '1.0.0 install: 3 markers' 3 "$(count_markers "$CMUU/jci/sm/sm.conf")"
BKU=$(marker_backup "$CMUU")
STICKU=$(new_stick update-a)
printf 'installed\n' >"$STICKU/touchtune/.tt-state"
run_stick "$CMUU" "$STICKU" status
check_contains '1.0.0 install: state outdated' "$TESTROOT/run.log" 'state=outdated'
check_contains '1.0.0 install: reason names 1.6' "$TESTROOT/run.log" 'older installation (installer 1.0.0: Android Auto 1.6)'
AFTERU=$(stock_sums "$CMUU")
run_stick "$CMUU" "$STICKU" - '' '2'
check_rc 'update offered -> Cancel: exit code' "$?" 0
check_contains 'start dialog: older version named' "$TESTROOT/run.log" 'Android Auto touch: older version installed'
check_contains 'start dialog: update offered' "$TESTROOT/run.log" 'An update for Android Auto touch is available.'
check_contains 'start dialog: Update / Remove both' "$TESTROOT/run.log" '[Update|Remove both|Cancel]'
check_eq 'Cancel: nothing changed' "$AFTERU" "$(stock_sums "$CMUU")"
run_stick "$CMUU" "$STICKU" - '' '0 0'
check_rc 'update from the start dialog: exit code' "$?" 0
check_contains 'update: own confirmation' "$TESTROOT/run.log" 'Selected: Update\n\nAndroid Auto touch is updated in place'
check_contains 'update: working message' "$TESTROOT/run.log" 'POPUP: Updating...'
check_contains 'update: AA working message' "$TESTROOT/run.log" 'POPUP: Updating Android Auto touch...'
check_contains 'update: uses the existing backup' "$TESTROOT/run.log" "update in place with the existing backup: $CMUU/data_persist/mzd-aa-touch/backups/$BKU"
check_eq 'update: 2 markers (sm.conf)' 2 "$(count_markers "$CMUU/jci/sm/sm.conf")"
check_eq 'update: 2 markers (sm_WCP.conf)' 2 "$(count_markers "$CMUU/jci/sm/sm_WCP.conf")"
check_not_contains 'update: aap_service line gone' "$CMUU/jci/sm/sm_WCP.conf" 'libpatch-aap_service.so'
check_wiring 'update: jcinavi wired (sm_WCP.conf)' "$CMUU" jci/sm/sm_WCP.conf jcinavi libpatch-svcjcinavi.so
check_no_file 'update: aap_service shim not live' "$CMUU/data_persist/oem-aa-mod/libpatch-aap_service.so"
check_file 'update: aap_service shim kept aside' "$(ls "$CMUU"/data_persist/mzd-aa-touch/removed/libpatch-aap_service.so.* 2>/dev/null | head -n1)"
check_hash 'update: libpatch.conf = the stick file' "$CMUU/data_persist/oem-aa-mod/libpatch.conf" \
    "$(sha256sum "$STICKU/aa-mod/libpatch.conf" | cut -d' ' -f1)"
if marker_has "$CMUU" protocol_v16=0 && marker_has "$CMUU" "installer=$NEWVER" && \
   marker_has "$CMUU" previous_installer=1.0.0 && marker_has "$CMUU" "backup=$BKU"; then
    ok 'update: marker (1.5, new installer, previous 1.0.0, same backup)'
else
    bad 'update: marker (1.5, new installer, previous 1.0.0, same backup)' "$(tr '\n' ' ' <"$CMUU/data_persist/oem-aa-mod/install-state")"
fi
check_eq 'update: still one backup' 1 "$(backup_count "$CMUU")"
check_xml_patched 'update: AA XML = factory file + touch' "$CMUU/etc/aap_system_attributes.xml" \
    "$TESTROOT/cmu-template/etc/aap_system_attributes.xml" true
check_xml_patched 'update: UCP XML = factory file + touch' "$CMUU/etc/aap_system_attributes_UCP.xml" \
    "$TESTROOT/cmu-template/etc/aap_system_attributes_UCP.xml" false
check_xmls 'update: XML well-formed' "$CMUU"
check_no_stages 'update: no stage files' "$CMUU"
check_eq 'update: TouchTune (installed) not run' 0 "$(tt_calls "$STICKU" touch-while-driving)"
check_contains 'update: done message' "$TESTROOT/run.log" 'Android Auto touch updated and verified'
check_contains 'update: restart asked' "$TESTROOT/run.log" 'Android Auto touch is updated.'
check_contains 'update: SafeReboot' "$TESTROOT/run.log" 'TEST: SafeReboot would be requested now'
run_stick "$CMUU" "$STICKU" status
check_contains 'after the update: ours' "$TESTROOT/run.log" 'state=ours'
run_stick "$CMUU" "$STICKU" install
check_contains 'after the update: nothing to do' "$TESTROOT/run.log" 'already installed'
awk '!/libpatch-svcjcinavi.so/' "$CMUU/jci/sm/sm.conf" >"$CMUU/sm.tmp" && mv "$CMUU/sm.tmp" "$CMUU/jci/sm/sm.conf"
run_stick "$CMUU" "$STICKU" install
check_contains 'after the update: a repair is a repair' "$TESTROOT/run.log" 'repair with the existing backup'
if marker_has "$CMUU" previous_installer=1.0.0; then ok 'repair keeps previous_installer'; \
    else bad 'repair keeps previous_installer' "$(tr '\n' ' ' <"$CMUU/data_persist/oem-aa-mod/install-state")"; fi
run_stick "$CMUU" "$STICKU" uninstall
check_rc 'updated install: removal exit code' "$?" 0
check_stock_unchanged 'updated install: originals byte-identical' "$CMUU" "$TPL_SUMS"
check_no_file 'updated install: no shim folder' "$CMUU/data_persist/oem-aa-mod"

# An early build: oem-aa-mod's XMLs copied, no backup= line in the marker.
CMUE=$(old_install early)
STICKE=$(new_stick update-early)
cp "$STICKE/aa-mod/aap_system_attributes.xml" "$CMUE/etc/aap_system_attributes.xml"
cp "$STICKE/aa-mod/aap_system_attributes_UCP.xml" "$CMUE/etc/aap_system_attributes_UCP.xml"
sed -e '/^backup=/d' -e 's/^installer=.*/installer=0.9.0/' "$CMUE/data_persist/oem-aa-mod/install-state" >"$CMUE/state.tmp" && \
    mv "$CMUE/state.tmp" "$CMUE/data_persist/oem-aa-mod/install-state"
run_stick "$CMUE" "$STICKE" status
check_contains 'early build: outdated' "$TESTROOT/run.log" 'state=outdated'
check_contains 'early build: reason names the XML' "$TESTROOT/run.log" 'Android Auto 1.6, oem-aa-mod XML)'
run_stick "$CMUE" "$STICKE" install
check_rc 'early build: update via ACTION.txt: exit code' "$?" 0
check_contains 'early build: ACTION.txt confirmation names the update' "$TESTROOT/run.log" 'Selected: Update (ACTION.txt)'
check_xml_patched 'early build: AA XML = factory file + touch' "$CMUE/etc/aap_system_attributes.xml" \
    "$TESTROOT/cmu-template/etc/aap_system_attributes.xml" true
check_eq 'early build: 2 markers' 2 "$(count_markers "$CMUE/jci/sm/sm.conf")"
if marker_has "$CMUE" previous_installer=0.9.0 && [ -n "$(marker_backup "$CMUE")" ]; then
    ok 'early build: marker names the backup and the previous installer'
else
    bad 'early build: marker names the backup and the previous installer' "$(tr '\n' ' ' <"$CMUE/data_persist/oem-aa-mod/install-state")"
fi
check_eq 'early build: TouchTune (stock) installed in the same run' 1 "$(tt_calls "$STICKE" touch-while-driving)"
run_stick "$CMUE" "$STICKE" uninstall
check_rc 'early build: removal exit code' "$?" 0
check_stock_unchanged 'early build: originals byte-identical' "$CMUE" "$TPL_SUMS"

# A 1.0.0 installation removed by the new stick without updating it first.
CMUO=$(old_install remove)
STICKO=$(new_stick update-remove)
run_stick "$CMUO" "$STICKO" uninstall
check_rc '1.0.0 install removed by the new stick: exit code' "$?" 0
check_stock_unchanged '1.0.0 install removed: originals byte-identical' "$CMUO" "$TPL_SUMS"
check_no_file '1.0.0 install removed: no shim folder' "$CMUO/data_persist/oem-aa-mod"
run_stick "$CMUO" "$STICKO" status
check_contains '1.0.0 install removed: clean' "$TESTROOT/run.log" 'state=clean'

# libpatch.conf changed in another way: not an older version, a repair.
CMUM=$(old_install conf-modified)
STICKM=$(new_stick update-conf-modified)
printf 'hud = false\n' >>"$CMUM/data_persist/oem-aa-mod/libpatch.conf"
run_stick "$CMUM" "$STICKM" status
check_contains 'other libpatch.conf: partial, not outdated' "$TESTROOT/run.log" 'state=partial'
run_stick "$CMUM" "$STICKM" install
check_rc 'other libpatch.conf: repair exit code' "$?" 0
check_hash 'other libpatch.conf: replaced by the stick file' "$CMUM/data_persist/oem-aa-mod/libpatch.conf" \
    "$(sha256sum "$STICKM/aa-mod/libpatch.conf" | cut -d' ' -f1)"

# A fault during the update rolls back to the car's original files.
for flt in stage-write-fail publish-fail readback-fail; do
    CMUF=$(old_install "fault-$flt")
    STICKF=$(new_stick "update-fault-$flt")
    run_stick "$CMUF" "$STICKF" install "$flt"
    check_rc_nonzero "update $flt: aborts" "$?"
    check_stock_unchanged "update $flt: original files restored" "$CMUF" "$TPL_SUMS"
    check_no_file "update $flt: no shim folder" "$CMUF/data_persist/oem-aa-mod"
    check_no_stages "update $flt: no stage files" "$CMUF"
    check_eq "update $flt: TouchTune not started" 0 "$(tt_calls "$STICKF" .)"
    run_stick "$CMUF" "$STICKF" install
    check_rc "update $flt: a new run installs" "$?" 0
    run_stick "$CMUF" "$STICKF" status
    check_contains "update $flt: then ours" "$TESTROOT/run.log" 'state=ours'
done

# ---------------------------------------------------------------------------
section 'CMU clock at 1970: which backup is used'
# The CMU clock restarts at 1970 on every boot: backup names are uptimes.
CMUC=$(new_cmu clock1970)
STICKC=$(new_stick clock1970)
OLDVER=$(cat "$CMUC/jci/version.ini")
# First install on an older firmware (other XML), taken late after boot.
sed 's/^JCI_SW_VER_PATCH=.*/JCI_SW_VER_PATCH=""/' "$CMUC/jci/version.ini" >"$CMUC/v.tmp" && mv "$CMUC/v.tmp" "$CMUC/jci/version.ini"
printf '\n<!-- older firmware -->\n' >>"$CMUC/etc/aap_system_attributes.xml"
run_stick "$CMUC" "$STICKC" install '' '' 'MZD_TEST_STAMP=19700101T000900Z'
check_rc '1970: install on the older firmware' "$?" 0
run_stick "$CMUC" "$STICKC" uninstall
check_rc '1970: removal on the older firmware' "$?" 0
# Firmware update, then a new install taken early after boot (lower stamp).
printf '%s\n' "$OLDVER" >"$CMUC/jci/version.ini"
cp "$TESTROOT/cmu-template/etc/aap_system_attributes.xml" "$CMUC/etc/aap_system_attributes.xml"
BEFOREC=$(stock_sums "$CMUC")
run_stick "$CMUC" "$STICKC" install '' '' 'MZD_TEST_STAMP=19700101T000100Z'
check_rc '1970: newer install with a lower stamp' "$?" 0
check_eq '1970: two backups on the car' 2 "$(backup_count "$CMUC")"
check_eq '1970: marker names the new backup' 19700101T000100Z "$(marker_backup "$CMUC")"
check_xml_patched '1970: XML derived from the new backup' "$CMUC/etc/aap_system_attributes.xml" \
    "$TESTROOT/cmu-template/etc/aap_system_attributes.xml" true
run_stick "$CMUC" "$STICKC" status
check_contains '1970: status uses the marked backup' "$TESTROOT/run.log" 'backups/19700101T000100Z'
run_stick "$CMUC" "$STICKC" uninstall
check_rc '1970: removal exit code' "$?" 0
check_stock_unchanged '1970: the files of the current firmware are restored' "$CMUC" "$BEFOREC"
# Without a marker: the running firmware decides, then the highest stamp.
check_eq '1970: no marker -> backup of the running firmware' 19700101T000100Z \
    "$(lib_eval "$CMUC" 'mzd_require_firmware >/dev/null; mzd_backup_find aa-touch- && basename "$MZD_BACKUP_DIR"')"
check_eq '1970: no firmware match -> highest stamp' 19700101T000900Z \
    "$(lib_eval "$CMUC" 'MZD_FW=74.00.999; mzd_backup_find aa-touch- && basename "$MZD_BACKUP_DIR"')"
check_eq '1970: preferred backup wins' 19700101T000900Z \
    "$(lib_eval "$CMUC" 'mzd_require_firmware >/dev/null; MZD_BACKUP_PREFER=19700101T000900Z; mzd_backup_find aa-touch- && basename "$MZD_BACKUP_DIR"')"
check_eq '1970: preference with a path is ignored' 19700101T000100Z \
    "$(lib_eval "$CMUC" 'mzd_require_firmware >/dev/null; MZD_BACKUP_PREFER=../x; mzd_backup_find aa-touch- && basename "$MZD_BACKUP_DIR"')"
# Same second after boot again: the backup gets a suffix instead of failing.
run_stick "$CMUC" "$STICKC" install '' '' 'MZD_TEST_STAMP=19700101T000100Z'
check_rc '1970: same stamp again: install exit code' "$?" 0
check_eq '1970: same stamp again: suffixed backup' 19700101T000100Z-2 "$(marker_backup "$CMUC")"
check_eq '1970: three backups' 3 "$(backup_count "$CMUC")"
run_stick "$CMUC" "$STICKC" uninstall
check_rc '1970: same stamp again: removal exit code' "$?" 0
check_stock_unchanged '1970: same stamp again: originals byte-identical' "$CMUC" "$BEFOREC"

# ---------------------------------------------------------------------------
section 'Damaged or modified stick'
CMU4=$(new_cmu tamper-mod)
STICK4=$(new_stick tamper-mod)
printf 'TAMPERED\n' >>"$STICK4/aa-mod/libpatch-blmjciaapa.so"
BEFORE4=$(stock_sums "$CMU4")
run_stick "$CMU4" "$STICK4" install
check_rc_nonzero 'modified shim refused' "$?"
check_stock_unchanged 'nothing changed (shim)' "$CMU4" "$BEFORE4"
check_no_file 'no shim folder (shim)' "$CMU4/data_persist/oem-aa-mod"
check_eq 'TouchTune not started (shim)' 0 "$(tt_calls "$STICK4" .)"

CMU5=$(new_cmu tamper-stick)
STICK5=$(new_stick tamper-stick)
printf '# tampered\n' >>"$STICK5/lib/aa-touch.sh"
BEFORE5=$(stock_sums "$CMU5")
run_stick "$CMU5" "$STICK5" install
check_rc_nonzero 'modified library refused' "$?"
check_stock_unchanged 'nothing changed (manifest)' "$CMU5" "$BEFORE5"
check_contains 'manifest error logged' "$TESTROOT/run.log" 'payload hash differs: lib/aa-touch.sh'

STICK5b=$(new_stick tamper-tt)
printf '# tampered\n' >>"$STICK5b/touchtune/patches/touch-while-driving.sh"
run_stick "$CMU5" "$STICK5b" install
check_rc_nonzero 'modified TouchTune file refused' "$?"
check_contains 'TouchTune manifest error logged' "$TESTROOT/run.log" 'payload hash differs: touchtune/patches/touch-while-driving.sh'

STICK5c=$(new_stick two-launchers)
: >"$STICK5c/other.up"
run_stick "$CMU5" "$STICK5c" install
check_rc_nonzero 'second .up file refused' "$?"
check_contains 'second launcher logged' "$TESTROOT/run.log" 'unexpected .up file'

STICK5e=$(new_stick tt-launcher-differs)
printf 'other\n' >"$STICK5e/touchtune/$TT_LAUNCHER"
run_stick "$CMU5" "$STICK5e" install
check_rc_nonzero 'differing TouchTune launcher refused' "$?"
check_contains 'differing TouchTune launcher logged' "$TESTROOT/run.log" 'the TouchTune launcher on the stick differs'
check_stock_unchanged 'nothing changed (TouchTune launcher)' "$CMU5" "$BEFORE5"

STICK5f=$(new_stick tt-launcher-present)
cp "$STICK5f/lib/touchtune-launcher" "$STICK5f/touchtune/$TT_LAUNCHER"
run_stick "$CMU5" "$STICK5f" status
check_rc 'identical TouchTune launcher accepted' "$?" 0
check_contains 'identical TouchTune launcher kept' "$TESTROOT/run.log" 'TouchTune launcher present'

STICK5g=$(new_stick tt-launcher-name)
printf '$(echo x)/../../evil.up\n' >"$STICK5g/touchtune/LAUNCHER.NAME"
awk -v h="$(sha256sum "$STICK5g/touchtune/LAUNCHER.NAME" | cut -d' ' -f1)" \
    '$2 == "touchtune/LAUNCHER.NAME" { $1 = h; print $1 "  " $2; next } { print }' \
    "$STICK5g/PAYLOAD.SHA256" >"$STICK5g/PAYLOAD.new" && mv "$STICK5g/PAYLOAD.new" "$STICK5g/PAYLOAD.SHA256"
run_stick "$CMU5" "$STICK5g" install
check_rc_nonzero 'TouchTune launcher name with a path refused' "$?"
check_contains 'invalid TouchTune launcher name logged' "$TESTROOT/run.log" 'touchtune/LAUNCHER.NAME is invalid'
check_no_file 'no file outside touchtune/' "$TESTROOT/evil.up"
check_stock_unchanged 'nothing changed (TouchTune launcher name)' "$CMU5" "$BEFORE5"

STICK5d=$(new_stick wrong-id)
printf 'mzd-aa-touch-v1\n' >"$STICK5d/STICK.ID"
run_stick "$CMU5" "$STICK5d" install
check_rc_nonzero 'wrong STICK.ID refused' "$?"
check_stock_unchanged 'nothing changed (stick checks)' "$CMU5" "$BEFORE5"

# ---------------------------------------------------------------------------
section 'Unsupported firmware'
CMU6=$(new_cmu fw)
STICK6=$(new_stick fw)
printf '[VersionInfo]\nJCI_SW_VER="MAZ_CMU-150_74.00.311"\nJCI_SW_FLAVOR="cmu150_NA"\nJCI_SW_VER_PATCH="A"\n' >"$CMU6/jci/version.ini"
BEFORE6=$(stock_sums "$CMU6")
run_stick "$CMU6" "$STICK6" install
check_rc_nonzero 'other firmware refused' "$?"
check_stock_unchanged 'nothing changed (firmware)' "$CMU6" "$BEFORE6"
check_contains 'firmware named in the log' "$TESTROOT/run.log" '74.00.311A (cmu150_NA) is not supported'
check_file 'diagnosis written for the bug report' "$(ls "$STICK6"/diag-*.txt 2>/dev/null | head -n1)"
check_contains 'firmware: the stick may be pulled' "$TESTROOT/run.log" 'You can pull the stick now.'
check_eq 'TouchTune not started (firmware)' 0 "$(tt_calls "$STICK6" .)"

# ---------------------------------------------------------------------------
section 'Another oem-aa-mod installation (.orig files)'
CMU7=$(new_cmu foreign)
STICK7=$(new_stick foreign)
cp -a "$CMU7/jci/sm/sm.conf" "$CMU7/jci/sm/sm.conf.orig"
BEFORE7=$(stock_sums "$CMU7")
run_stick "$CMU7" "$STICK7" install '' '0 1'
check_rc_nonzero '"TouchTune only" declined: exit code' "$?"
check_contains 'TouchTune-only offered' "$TESTROOT/run.log" 'Install only TouchTune'
check_stock_unchanged 'AA files untouched (declined)' "$CMU7" "$BEFORE7"
check_eq 'TouchTune not started (declined)' 0 "$(tt_calls "$STICK7" .)"
run_stick "$CMU7" "$STICK7" install
check_rc 'TouchTune only accepted: exit code' "$?" 0
check_stock_unchanged 'AA files untouched (foreign)' "$CMU7" "$BEFORE7"
check_eq 'no own AA backup (foreign)' 0 "$(backup_count "$CMU7")"
check_file 'foreign .orig kept' "$CMU7/jci/sm/sm.conf.orig"
check_eq 'TouchTune installed alone' 1 "$(tt_calls "$STICK7" touch-while-driving)"
run_stick "$CMU7" "$STICK7" uninstall
check_rc 'removal with foreign AA: exit code' "$?" 0
check_stock_unchanged 'foreign AA left alone on removal' "$CMU7" "$BEFORE7"
check_eq 'TouchTune removed' 1 "$(tt_calls "$STICK7" --restore)"

section 'Foreign LD_PRELOAD line without .orig'
CMU8=$(new_cmu foreign-line)
STICK8=$(new_stick foreign-line)
awk '
    done == 0 && /<service[ \t]/ && index($0, "name=\"jciAAPA\"") > 0 {
        print
        print "            <environ_var env_name=\"LD_PRELOAD\" env_value=\"/data_persist/othermod/libother.so\"/>"
        done = 1
        next
    }
    { print }
' "$CMU8/jci/sm/sm.conf" >"$CMU8/sm.tmp" && mv "$CMU8/sm.tmp" "$CMU8/jci/sm/sm.conf"
BEFORE8=$(stock_sums "$CMU8")
run_stick "$CMU8" "$STICK8" install '' '0 1'
check_stock_unchanged 'nothing changed (foreign line)' "$CMU8" "$BEFORE8"
check_no_file 'no shim folder (foreign line)' "$CMU8/data_persist/oem-aa-mod"
check_contains 'foreign line detected' "$TESTROOT/run.log" 'foreign oem-aa-mod traces'

section 'Unknown Common.js (TouchTune not supported on this build)'
CMU9=$(new_cmu tt-foreign)
STICK9=$(new_stick tt-foreign)
rm -f "$STICK9/touchtune/.tt-state"
printf '// another build\n' >"$CMU9/jci/gui/common/js/Common.js"
run_stick "$CMU9" "$STICK9" install
check_rc '"AA touch only" accepted: exit code' "$?" 0
check_contains 'AA-only offered' "$TESTROOT/run.log" 'Install only Android Auto touch'
check_eq 'AA installed alone' 2 "$(count_markers "$CMU9/jci/sm/sm.conf")"
check_eq 'TouchTune not started' 0 "$(tt_calls "$STICK9" .)"
check_contains 'restart asked by this installer' "$TESTROOT/run.log" 'TEST: SafeReboot would be requested now'
cp -a "$CMU9/jci/sm/sm.conf" "$CMU9/jci/sm/sm.conf.orig"
run_stick "$CMU9" "$STICK9" install
check_rc_nonzero 'neither part possible: exit code' "$?"
check_contains 'neither part reported' "$TESTROOT/run.log" 'Neither part can be installed safely'

# ---------------------------------------------------------------------------
section 'Other regions: North America build with unknown binaries'
CMUNA=$(new_cmu na)
STICKNA=$(new_stick na)
printf '[VersionInfo]\nJCI_SW_VER="MAZ_CMU-150_74.00.324"\nJCI_SW_FLAVOR="cmu150_NA"\nJCI_SW_VER_PATCH="A"\n' >"$CMUNA/jci/version.ini"
# A region file differs from the EU build: one more service, other spacing.
awk '/<\/services>/ { print "    <service type=\"process\" name=\"sxm\" path=\"/usr/bin/sxm\" autorun=\"yes\">"; print "        <dependency type=\"service\" value=\"devicemanager\"/>"; print "    </service>" } { print }' \
    "$CMUNA/jci/sm/sm.conf" >"$CMUNA/sm.tmp" && mv "$CMUNA/sm.tmp" "$CMUNA/jci/sm/sm.conf"
printf '\n<!-- NA -->\n' >>"$CMUNA/etc/aap_system_attributes.xml"
printf 'ELF-NA-BLM\n' >"$CMUNA/jci/aapa/blmjciaapa.so"
BEFORENA=$(stock_sums "$CMUNA")
run_stick "$CMUNA" "$STICKNA" install '' '0 1' 'MZD_TEST_ENFORCE_BINARY_HASHES=1'
check_rc_nonzero 'untested build declined: exit code' "$?"
check_contains 'user was told the build differs' "$TESTROOT/run.log" 'differs from the build this installer was tested on'
check_contains 'region named in the dialog' "$TESTROOT/run.log" '74.00.324A, cmu150_NA'
check_stock_unchanged 'nothing changed (declined)' "$CMUNA" "$BEFORENA"
check_eq 'no backup (declined)' 0 "$(backup_count "$CMUNA")"
check_eq 'TouchTune not started (declined)' 0 "$(tt_calls "$STICKNA" .)"
run_stick "$CMUNA" "$STICKNA" install '' '' 'MZD_TEST_ENFORCE_BINARY_HASHES=1'
check_rc 'untested build accepted: exit code' "$?" 0
check_contains 'acceptance logged' "$TESTROOT/run.log" 'untested build accepted by the user'
check_contains 'differing factory file logged' "$TESTROOT/run.log" 'sm.conf differs from the tested EU 74.00.324A file'
check_eq 'NA: 2 markers' 2 "$(count_markers "$CMUNA/jci/sm/sm.conf")"
check_contains 'NA: region service kept' "$CMUNA/jci/sm/sm.conf" 'name="sxm"'
check_eq 'NA: TouchTune installed' 1 "$(tt_calls "$STICKNA" touch-while-driving)"
run_stick "$CMUNA" "$STICKNA" uninstall '' '' 'MZD_TEST_ENFORCE_BINARY_HASHES=1'
check_rc 'NA removal: exit code' "$?" 0
check_stock_unchanged 'NA files restored byte for byte' "$CMUNA" "$BEFORENA"

CMUEU=$(new_cmu eu-known)
STICKEU=$(new_stick eu-known)
if [ -n "$REAL" ] && [ -f "$REAL/jci/aapa/blmjciaapa.so" ]; then
    run_stick "$CMUEU" "$STICKEU" install '' '' 'MZD_TEST_ENFORCE_BINARY_HASHES=1'
    check_rc 'real EU binaries: exit code' "$?" 0
    check_contains 'real EU binaries recognised' "$TESTROOT/run.log" 'identical to the tested EU 74.00.324A build'
    check_not_contains 'no untested-build question' "$TESTROOT/run.log" 'differs from the build this installer was tested on'
else
    printf 'skip real EU binary check (MZD_TEST_REAL_ROOTFS without binaries)\n'
fi

# ---------------------------------------------------------------------------
section 'Stale guard of an interrupted run'
CMU10=$(new_cmu stale-guard)
STICK10=$(new_stick stale-guard)
mkdir -p "$CMU10/tmp/mzd-usb-installer.guard"
run_stick "$CMU10" "$STICK10" install
check_rc_nonzero 'fresh guard blocks' "$?"
run_stick "$CMU10" "$STICK10" install '' '' 'MZD_GUARD_MAX_AGE_S=-1'
check_rc 'stale guard removed' "$?" 0
check_eq 'stale guard: installed' 2 "$(count_markers "$CMU10/jci/sm/sm.conf")"

section 'TouchTune guard present'
CMU11=$(new_cmu tt-guard)
STICK11=$(new_stick tt-guard)
BEFORE11=$(stock_sums "$CMU11")
mkdir -p "$CMU11/tmp/touchtune-installer.guard"
run_stick "$CMU11" "$STICK11" install
check_rc_nonzero 'TouchTune guard blocks' "$?"
check_stock_unchanged 'nothing changed (TouchTune guard)' "$CMU11" "$BEFORE11"
check_eq 'TouchTune not started (guard)' 0 "$(tt_calls "$STICK11" .)"

# ---------------------------------------------------------------------------
section 'Injected faults: every one rolls back to the original state'
for flt in stage-write-fail publish-fail publish-fail-late readback-fail backup-write-fail \
             interrupt-before-publish exit-after-backup; do
    CMUF=$(new_cmu "fault-$flt")
    STICKF=$(new_stick "fault-$flt")
    BEFOREF=$(stock_sums "$CMUF")
    run_stick "$CMUF" "$STICKF" install "$flt"
    rc=$?
    if [ "$flt" = interrupt-before-publish ] || [ "$flt" = exit-after-backup ]; then
        check_rc "$flt: exit code 97" "$rc" 97
    else
        check_rc_nonzero "$flt: aborts" "$rc"
    fi
    check_stock_unchanged "$flt: original files unchanged" "$CMUF" "$BEFOREF"
    check_no_file "$flt: no shim folder" "$CMUF/data_persist/oem-aa-mod"
    check_no_stages "$flt: no stage files" "$CMUF"
    check_eq "$flt: TouchTune not started" 0 "$(tt_calls "$STICKF" .)"
    check_no_file "$flt: guard removed" "$CMUF/tmp/mzd-usb-installer.guard"
done
CMUX=$(new_cmu fault-xml)
STICKX=$(new_stick fault-xml)
BEFOREX=$(stock_sums "$CMUX")
run_stick "$CMUX" "$STICKX" install '' '' 'MZD_TEST_XMLLINT_FAIL=stage'
check_rc_nonzero 'staged XML invalid: aborts' "$?"
check_contains 'staged XML invalid: detected' "$TESTROOT/run.log" 'XML is not well-formed'
check_stock_unchanged 'staged XML invalid: original files unchanged' "$CMUX" "$BEFOREX"
check_no_file 'staged XML invalid: no shim folder' "$CMUX/data_persist/oem-aa-mod"
check_no_stages 'staged XML invalid: no stage files' "$CMUX"
check_eq 'staged XML invalid: TouchTune not started' 0 "$(tt_calls "$STICKX" .)"
# The live files cannot be validated: Android Auto touch is not touched, and
# TouchTune (which does not use these files) is offered alone.
run_stick "$CMUX" "$STICKX" install '' '0 1' 'MZD_TEST_XMLLINT_FAIL=1'
check_rc_nonzero 'live XML not validatable: AA refused' "$?"
check_contains 'live XML not validatable: reason logged' "$TESTROOT/run.log" 'is not well-formed XML'
check_contains 'live XML not validatable: TouchTune alone offered' "$TESTROOT/run.log" 'Install only TouchTune'
check_stock_unchanged 'live XML not validatable: unchanged' "$CMUX" "$BEFOREX"
check_eq 'live XML not validatable: TouchTune declined' 0 "$(tt_calls "$STICKX" .)"

section 'Removal faults end in the original state, never half-removed'
# Rolling back a failed removal means finishing it from the backup.
for flt in stage-write-fail publish-fail readback-fail; do
    CMURF=$(new_cmu "revert-$flt")
    STICKRF=$(new_stick "revert-$flt")
    BEFORERF=$(stock_sums "$CMURF")
    run_stick "$CMURF" "$STICKRF" install
    run_stick "$CMURF" "$STICKRF" uninstall "$flt"
    check_rc_nonzero "removal $flt: reported as failed" "$?"
    check_contains "removal $flt: end message says the stick may be pulled" "$TESTROOT/run.log" 'You can pull the stick now.'
    check_stock_unchanged "removal $flt: original files restored" "$CMURF" "$BEFORERF"
    check_no_stages "removal $flt: no stage files" "$CMURF"
    check_eq "removal $flt: TouchTune not touched" 0 "$(tt_calls "$STICKRF" --restore)"
    run_stick "$CMURF" "$STICKRF" uninstall
    check_rc "removal $flt: second run exit code" "$?" 0
    check_eq "removal $flt: second run removes TouchTune" 1 "$(tt_calls "$STICKRF" --restore)"
    check_stock_unchanged "removal $flt: still original" "$CMURF" "$BEFORERF"
done

section 'TouchTune fails after Android Auto touch'
CMUT=$(new_cmu tt-fail)
STICKT=$(new_stick tt-fail)
: >"$CMUT/tmp/tt-fail"
run_stick "$CMUT" "$STICKT" install
check_rc_nonzero 'TouchTune failure: exit code' "$?"
check_eq 'AA stays installed (no cross-rollback)' 2 "$(count_markers "$CMUT/jci/sm/sm.conf")"
check_contains 'failure reported' "$TESTROOT/run.log" 'TouchTune could not be confirmed'
check_contains 'no restart after the failure' "$TESTROOT/run.log" 'No restart'
check_not_contains 'no SafeReboot after the failure' "$TESTROOT/run.log" 'SafeReboot would be requested'

# ---------------------------------------------------------------------------
section 'Firmware change between install and removal'
CMU12=$(new_cmu fwchange)
STICK12=$(new_stick fwchange)
run_stick "$CMU12" "$STICK12" install
BK12=$(ls -1d "$CMU12"/data_persist/mzd-aa-touch/backups/[0-9]* | head -n1)
chmod u+w "$BK12/metadata" "$BK12/metadata.sha256"
sed 's/^firmware=.*/firmware=74.00.311A/' "$BK12/metadata" >"$BK12/metadata.tmp" && mv "$BK12/metadata.tmp" "$BK12/metadata"
sha256sum "$BK12/metadata" | sed 's#  .*#  metadata#' >"$BK12/metadata.sha256"
chmod 0444 "$BK12/metadata" "$BK12/metadata.sha256"
run_stick "$CMU12" "$STICK12" uninstall
check_rc_nonzero 'removal with a backup of another firmware refused' "$?"
check_contains 'firmware mismatch reported' "$TESTROOT/run.log" 'different firmware'
check_eq 'installation stays' 2 "$(count_markers "$CMU12/jci/sm/sm.conf")"
check_eq 'TouchTune not touched' 0 "$(tt_calls "$STICK12" --restore)"

section 'Official firmware update: new backup and reinstall'
CMU13=$(new_cmu fwupdate)
STICK13=$(new_stick fwupdate)
run_stick "$CMU13" "$STICK13" install
for rel in jci/sm/sm.conf jci/sm/sm_WCP.conf etc/aap_system_attributes.xml etc/aap_system_attributes_UCP.xml; do
    cp "$TESTROOT/cmu-template/$rel" "$CMU13/$rel"
done
BK13=$(ls -1d "$CMU13"/data_persist/mzd-aa-touch/backups/[0-9]* | head -n1)
chmod u+w "$BK13/metadata" "$BK13/metadata.sha256"
sed 's/^firmware=.*/firmware=74.00.311A/' "$BK13/metadata" >"$BK13/metadata.tmp" && mv "$BK13/metadata.tmp" "$BK13/metadata"
sha256sum "$BK13/metadata" | sed 's#  .*#  metadata#' >"$BK13/metadata.sha256"
chmod 0444 "$BK13/metadata" "$BK13/metadata.sha256"
printf 'stock\n' >"$STICK13/touchtune/.tt-state"
sleep 1
run_stick "$CMU13" "$STICK13" install
check_rc 'reinstall after the update: exit code' "$?" 0
check_eq 'installed again' 2 "$(count_markers "$CMU13/jci/sm/sm.conf")"
check_eq 'two backups' 2 "$(backup_count "$CMU13")"
check_contains 'new backup logged' "$TESTROOT/run.log" 'new backup'

# ---------------------------------------------------------------------------
section 'End messages say when the stick may be pulled'
CMUP=$(new_cmu popups)
pop_count() { printf '%s\n' "$1" | grep -c 'POPUP:' | tr -d '[:space:]'; }
out=$(lib_eval "$CMUP" '{ mzd_popup "Failed."; mzd_popup_final; } 2>&1')
check_eq 'plain last message is shown again' 2 "$(pop_count "$out")"
case "$out" in *'POPUP: Failed.\n\nYou can pull the stick now.'*) ok 'plain last message gets the pull hint' ;;
    *) bad 'plain last message gets the pull hint' "$out" ;; esac
out=$(lib_eval "$CMUP" '{ mzd_popup "x"; mzd_ask2 "q" a b; mzd_popup_final; } 2>&1')
check_eq 'after a question nothing is added' 1 "$(pop_count "$out")"
out=$(lib_eval "$CMUP" '{ mzd_popup "Done. Remove the USB stick."; mzd_popup_final; } 2>&1')
check_eq 'a message that already says it stays' 1 "$(pop_count "$out")"
out=$(lib_eval "$CMUP" '{ mzd_popup_busy "Working"; mzd_popup_final; } 2>&1')
case "$out" in *'POPUP: The run has ended.'*'You can pull the stick now.'*) ok 'run ending on the working message gets an end message' ;;
    *) bad 'run ending on the working message gets an end message' "$out" ;; esac
out=$(lib_eval "$CMUP" '{ mzd_popup_busy "Working"; combined_tt_run touch-while-driving >/dev/null 2>&1; mzd_popup_final; } 2>&1')
check_eq 'after TouchTune: no message of ours is added' 1 "$(pop_count "$out")"
out=$(lib_eval "$CMUP" 'MZD_SKIP_REBOOT=1; printf "%s" "$(aa_not_yet_hint)"')
check_eq 'combined run: AA message keeps the stick in' '\n\nDo not pull the stick yet.' "$out"
out=$(lib_eval "$CMUP" 'printf "[%s]" "$(aa_not_yet_hint)"')
check_eq 'single run: no keep-in hint' '[]' "$out"

# ---------------------------------------------------------------------------
section 'Start dialog (no ACTION.txt)'
CMUD=$(new_cmu dialog)
STICKD=$(new_stick dialog)
BEFORED=$(stock_sums "$CMUD")
run_stick "$CMUD" "$STICKD" - '' '2'
check_rc 'not installed -> Cancel: exit code' "$?" 0
check_contains 'state shown: not installed' "$TESTROOT/run.log" 'Android Auto touch: not installed'
check_stock_unchanged 'Cancel changes nothing' "$CMUD" "$BEFORED"
check_contains 'Cancel: message says the stick may be pulled' "$TESTROOT/run.log" \
    'POPUP: Cancelled. Nothing was changed.\n\nYou can pull the stick now.'
run_stick "$CMUD" "$STICKD" - '' '1 1 2'
check_rc 'Diagnosis -> Back -> Cancel: exit code' "$?" 0
check_contains 'Diagnosis asks first' "$TESTROOT/run.log" 'Selected: Diagnosis'
check_contains 'Diagnosis confirmation: Start/Back' "$TESTROOT/run.log" '[Start|Back] -> 1'
check_contains 'Back returns to the start dialog' "$TESTROOT/run.log" 'confirmation: Back to the start dialog'
check_eq 'start dialog shown twice' 2 "$(grep -c -F 'Install Android Auto touch and touch while driving?' "$TESTROOT/run.log" | tr -d '[:space:]')"
check_eq 'Back: no diagnosis written' 0 "$(ls "$STICKD"/diag-*.txt 2>/dev/null | wc -l | tr -d '[:space:]')"
run_stick "$CMUD" "$STICKD" - '' '1 0'
check_rc 'not installed -> Diagnosis -> Start: exit code' "$?" 0
check_file 'Diagnosis file written' "$(ls "$STICKD"/diag-*.txt 2>/dev/null | head -n1)"
check_contains 'Diagnosis: working message' "$TESTROOT/run.log" 'POPUP: Writing the report...'
check_contains 'Diagnosis: the stick may be pulled at the end' "$TESTROOT/run.log" 'Diagnosis written to the stick'
check_contains 'Diagnosis: pull hint' "$TESTROOT/run.log" 'Nothing was changed.\nYou can pull the stick now.'
check_stock_unchanged 'Diagnosis changes nothing' "$CMUD" "$BEFORED"
run_stick "$CMUD" "$STICKD" - '' '0 1 0 1 0 1 0 1 0 1'
check_rc 'Install -> Back five times: exit code' "$?" 0
check_stock_unchanged 'Back five times changes nothing' "$CMUD" "$BEFORED"
check_eq 'Back five times: TouchTune not started' 0 "$(tt_calls "$STICKD" .)"
check_contains 'Back five times ends as cancelled' "$TESTROOT/run.log" 'POPUP: Cancelled. Nothing was changed.'
run_stick "$CMUD" "$STICKD" - '' '0 0'
check_rc 'not installed -> Install -> Start: exit code' "$?" 0
check_eq 'Install from the dialog: AA' 2 "$(count_markers "$CMUD/jci/sm/sm.conf")"
check_eq 'Install from the dialog: TouchTune' 1 "$(tt_calls "$STICKD" touch-while-driving)"
check_contains 'Install asks first' "$TESTROOT/run.log" 'Selected: Install\n\nYour original files are backed up on this car'
check_contains 'Install confirmation says when to pull the stick' "$TESTROOT/run.log" 'Pull it only when the screen tells you to.'
check_not_contains 'start dialog confirmation, not the ACTION.txt one' "$TESTROOT/run.log" '(ACTION.txt)'
run_stick "$CMUD" "$STICKD" - '' '0 1 2'
check_rc 'installed -> Remove both -> Back -> Cancel: exit code' "$?" 0
check_contains 'installed state offers Remove both' "$TESTROOT/run.log" 'Remove both'
check_eq 'cancelled removal keeps AA' 2 "$(count_markers "$CMUD/jci/sm/sm.conf")"
check_eq 'cancelled removal keeps TouchTune' 0 "$(tt_calls "$STICKD" --restore)"
run_stick "$CMUD" "$STICKD" - '' '0 0'
check_rc 'installed -> Remove both -> Start: exit code' "$?" 0
check_contains 'Remove both asks first' "$TESTROOT/run.log" 'Selected: Remove both'
check_contains 'removal: working message' "$TESTROOT/run.log" 'POPUP: Removing...'
check_stock_unchanged 'Remove both restores the originals' "$CMUD" "$BEFORED"
check_eq 'Remove both removes TouchTune' 1 "$(tt_calls "$STICKD" --restore)"
printf 'installed\n' >"$STICKD/touchtune/.tt-state"
run_stick "$CMUD" "$STICKD" '' '' '1 0'
check_rc 'mixed state -> Remove: exit code' "$?" 0
check_contains 'mixed state shows TouchTune installed' "$TESTROOT/run.log" 'Touch while driving (TouchTune): installed'
check_eq 'mixed Remove: TouchTune --restore' 2 "$(tt_calls "$STICKD" --restore)"
check_stock_unchanged 'mixed Remove: AA untouched (was clean)' "$CMUD" "$BEFORED"

section 'ACTION.txt changes are still confirmed on the screen'
CMUA=$(new_cmu action-cancel)
STICKA=$(new_stick action-cancel)
BEFOREA=$(stock_sums "$CMUA")
run_stick "$CMUA" "$STICKA" install '' '1'
check_rc 'ACTION.txt install -> Cancel: exit code' "$?" 0
check_stock_unchanged 'nothing changed (ACTION.txt cancel)' "$CMUA" "$BEFOREA"
check_eq 'TouchTune not started (ACTION.txt cancel)' 0 "$(tt_calls "$STICKA" .)"
check_contains 'ACTION.txt cancel: the stick may be pulled' "$TESTROOT/run.log" 'POPUP: Cancelled. Nothing was changed.'
run_stick "$CMUA" "$STICKA" exit
check_rc 'ACTION.txt exit: exit code' "$?" 0
check_not_contains 'ACTION.txt exit: no message on the screen' "$TESTROOT/run.log" 'POPUP:'
check_stock_unchanged 'ACTION.txt exit changes nothing' "$CMUA" "$BEFOREA"
run_stick "$CMUA" "$STICKA" 'rm-rf'
check_rc_nonzero 'unknown action refused' "$?"
check_contains 'unknown action logged' "$TESTROOT/run.log" 'unknown action in ACTION.txt'
check_stock_unchanged 'unknown action changes nothing' "$CMUA" "$BEFOREA"
run_stick "$CMUA" "$STICKA" touchtune
check_rc 'touchtune action: exit code' "$?" 0
check_eq 'touchtune action opens TouchTune without arguments' 1 "$(grep -c '^$' "$STICKA/touchtune/.tt-calls" | tr -d '[:space:]')"
check_stock_unchanged 'touchtune action leaves AA alone' "$CMUA" "$BEFOREA"

# ---------------------------------------------------------------------------
section 'Diagnosis: read-only and shareable'
CMUG=$(new_cmu diagnose)
STICKG=$(new_stick diagnose)
run_stick "$CMUG" "$STICKG" install
BEFOREG=$(stock_sums "$CMUG")
rm -f "$STICKG"/diag-*.txt
run_stick "$CMUG" "$STICKG" diagnose
check_rc 'diagnosis exit code' "$?" 0
DIAG=$(ls "$STICKG"/diag-*.txt 2>/dev/null | head -n1)
check_file 'diagnosis file' "$DIAG"
check_contains 'diagnosis: firmware' "$DIAG" 'JCI_SW_VER=MAZ_CMU-150_74.00.324'
check_contains 'diagnosis: region' "$DIAG" 'JCI_SW_FLAVOR='
check_contains 'diagnosis: AA state' "$DIAG" 'state=ours'
check_contains 'diagnosis: AA XML variant' "$DIAG" 'variant=factory+touch'
check_contains 'diagnosis: TouchTune state' "$DIAG" 'state=installed'
check_contains 'diagnosis: file hashes' "$DIAG" 'sm.conf: '
check_contains 'diagnosis: our LD_PRELOAD lines' "$DIAG" 'libpatch-blmjciaapa.so'
check_contains 'diagnosis: NVRAM key' "$DIAG" 'NVRAM bus_bcm_speed_restriction='
check_not_contains 'diagnosis: no sm.conf contents' "$DIAG" '<service '
check_not_contains 'diagnosis: no XML contents' "$DIAG" '<aap_attributes>'
check_not_contains 'diagnosis: no Common.js contents' "$DIAG" '### test common.js'
check_stock_unchanged 'diagnosis changes nothing' "$CMUG" "$BEFOREG"
check_eq 'diagnosis: no copy of Mazda files on the stick' 0 \
    "$(find "$STICKG" -name 'diag-*' -type d | wc -l | tr -d '[:space:]')"

# ---------------------------------------------------------------------------
section 'Builder: real stick (tools/build_stick.py)'
DL="$REPO/downloads"
if [ -n "$PY" ] && [ -f "$DL/oem-aa-mod-0.10.0.zip" ] && [ -f "$DL/TouchTune-1.2.1.zip" ] && \
   [ -f "$DL/oem-aa-mod-0.10.0-LICENSE" ] && [ -f "$DL/oem-aa-mod-0.10.0-NOTICE.md" ]; then
    if "$PY" -I "$REPO/tools/build_stick.py" build --out "$TESTROOT/dist" >"$TESTROOT/builder.log" 2>&1; then
        ok 'builder runs'
        BS="$TESTROOT/dist/stick"
        check_eq 'builder: 25 manifest entries' 25 "$(grep -c . "$BS/PAYLOAD.SHA256" | tr -d '[:space:]')"
        check_eq 'builder: 39 files' 39 "$(find "$BS" -type f | wc -l | tr -d '[:space:]')"
        check_eq 'builder: one launcher at the top level' 1 "$(find "$BS" -maxdepth 1 -name '*.up' | wc -l | tr -d '[:space:]')"
        check_eq 'builder: launcher = car-proven name' "$LAUNCHER" "$(cat "$BS/LAUNCHER.NAME")"
        check_eq 'builder: 12 TouchTune files in touchtune/' 12 "$(find "$BS/touchtune" -type f | wc -l | tr -d '[:space:]')"
        check_eq 'builder: no launcher in touchtune/' 0 "$(find "$BS/touchtune" -name '*.up' | wc -l | tr -d '[:space:]')"
        check_hash 'builder: lib copy = TouchTune @launcher' "$BS/lib/touchtune-launcher" \
            "$(awk '$2 == "@launcher" { print $1 }' "$BS/touchtune/PAYLOAD.SHA256")"
        check_eq 'builder: longest path below 200 characters' 0 \
            "$(cd "$BS" && find . -type f | awk 'length($0) > 199' | wc -l | tr -d '[:space:]')"
        check_no_file 'builder: no ACTION.txt' "$BS/ACTION.txt"
        check_no_file 'builder: no stock/ folder' "$BS/stock"
        check_eq 'builder: no Mazda file names' 0 \
            "$(find "$BS" -type f \( -iname 'sm.conf' -o -iname 'sm_WCP.conf' -o -iname 'Common.js' -o -iname 'systemApp.js' -o -iname '*.png' -o -iname 'version.ini' \) | wc -l | tr -d '[:space:]')"
        check_contains 'builder: README links oem-aa-mod' "$BS/README.txt" 'https://github.com/VitaliyKurokhtin/oem-aa-mod'
        check_contains 'builder: README links TouchTune' "$BS/README.txt" 'https://github.com/Miatafy/TouchTune'
        check_file 'builder: oem-aa-mod LICENSE' "$BS/aa-mod/LICENSE"
        check_hash 'builder: libpatch.conf with 1.6 off' "$BS/aa-mod/libpatch.conf" \
            b874a9cf85916799032ae5b874d88a2f714d733a31a3e6cdeba785c6e25d827a
        check_eq 'builder: exactly the one line changed' 'use_protocol_v1_6 = false' \
            "$(grep '^[ \t]*use_protocol_v1_6[ \t]*=' "$BS/aa-mod/libpatch.conf")"
        check_contains 'builder: SHA256SUMS lists the shipped file' "$BS/aa-mod/SHA256SUMS" \
            'b874a9cf85916799032ae5b874d88a2f714d733a31a3e6cdeba785c6e25d827a  libpatch.conf'
        check_contains 'builder: SOURCE.txt names the change' "$BS/aa-mod/SOURCE.txt" 'use_protocol_v1_6 = false'
        check_file 'builder: release ZIP' "$TESTROOT/dist/mzd-touch-installer-$(tr -d '\r\n' <"$REPO/VERSION").zip"

        # Updating a stick that was used in a car keeps logs, diagnoses and
        # the user's copy of the car's files; installer files are replaced.
        UT="$TESTROOT/stick-update"
        cp -a "$BS" "$UT"
        printf 'old log\n' >"$UT/mzd-usb.log"
        printf 'old diagnosis\n' >"$UT/diag-19700101-000347.txt"
        mkdir -p "$UT/backup-aa-touch-19700101T000232Z"
        printf 'car file\n' >"$UT/backup-aa-touch-19700101T000232Z/sm.conf"
        printf 'tt log\n' >"$UT/touchtune/touchtune.log"
        cp "$UT/lib/touchtune-launcher" "$UT/touchtune/$(tr -d '\r\n' <"$UT/touchtune/LAUNCHER.NAME")"
        printf 'stale\n' >"$UT/lib/stale.sh"
        if "$PY" -I "$REPO/tools/build_stick.py" build --out "$TESTROOT/dist2" --target "$UT" >"$TESTROOT/builder2.log" 2>&1; then
            ok 'builder: updates a used stick'
        else
            bad 'builder: updates a used stick' "$(tail -n 3 "$TESTROOT/builder2.log")"
        fi
        check_contains 'stick update: mzd-usb.log kept' "$UT/mzd-usb.log" 'old log'
        check_file 'stick update: diagnosis kept' "$UT/diag-19700101-000347.txt"
        check_contains 'stick update: backup copy kept' "$UT/backup-aa-touch-19700101T000232Z/sm.conf" 'car file'
        check_contains 'stick update: TouchTune log kept' "$UT/touchtune/touchtune.log" 'tt log'
        check_no_file 'stick update: stale installer file removed' "$UT/lib/stale.sh"
        check_eq 'stick update: no launcher left in touchtune/' 0 \
            "$(find "$UT/touchtune" -name '*.up' | wc -l | tr -d '[:space:]')"

        # Real oem-aa-mod + real TouchTune 1.2.1 against the fake car.
        CMUB=$(new_cmu builder)
        cp -a "$BS" "$TESTROOT/stick-builder"
        SB="$TESTROOT/stick-builder"
        BEFOREB=$(stock_sums "$CMUB")
        COMMON_BEFORE=$(sha256sum "$CMUB/jci/gui/common/js/Common.js" | cut -d' ' -f1)
        run_stick "$CMUB" "$SB" install
        rcb=$?
        check_contains 'real stick: TouchTune launcher written' "$TESTROOT/run.log" 'TouchTune launcher written to the stick'
        check_rc 'real stick: install exit code' "$rcb" 0
        check_eq 'real stick: 2 markers (Android Auto 1.5)' 2 "$(count_markers "$CMUB/jci/sm/sm.conf")"
        check_hash 'real stick: real shim installed' "$CMUB/data_persist/oem-aa-mod/libpatch-blmjciaapa.so" \
            a6b87f72ae31429cebe14eea5c6d3a4a2749d4ea643a8c73303b3437533ad5b5
        check_xml_patched 'real stick: AA XML = factory file + touch' "$CMUB/etc/aap_system_attributes.xml" \
            "$TESTROOT/cmu-template/etc/aap_system_attributes.xml" true
        check_xml_patched 'real stick: UCP XML = factory file + touch' "$CMUB/etc/aap_system_attributes_UCP.xml" \
            "$TESTROOT/cmu-template/etc/aap_system_attributes_UCP.xml" false
        if [ "$(sha256sum "$TESTROOT/cmu-template/etc/aap_system_attributes.xml" | cut -d' ' -f1)" = \
             bc852037615dcb4e4eb24ab6f30a2e6f817fe00a22a2f767478b25f75b036812 ]; then
            # Real EU file: oem-aa-mod's touch entries, the video block as shipped.
            check_hash 'real stick: real EU AA XML patched as expected' "$CMUB/etc/aap_system_attributes.xml" \
                779d352ac5c4252fe2a3740b4eba91218974a49d96acb33b9499be0bf2425fb7
            check_hash 'real stick: real EU UCP XML patched as expected' "$CMUB/etc/aap_system_attributes_UCP.xml" \
                d58a32ce609a888e49b67f0e5fabe2d0ce997de9f0e25d905dac950695e31e47
        fi
        check_xmls 'real stick: XML well-formed' "$CMUB"
        if [ "$COMMON_BEFORE" = 376b30a46366a543122956d7feb1b44f147425015837a4d83fedf12a67943351 ]; then
            check_hash 'real TouchTune: Common.js patched' "$CMUB/jci/gui/common/js/Common.js" \
                019eba18e8d629ddb1d55563aab138ce1eb3329fab67b71d9b4178377cf9d9ce
            check_eq 'real TouchTune: bus restriction disabled' disable \
                "$(cat "$CMUB/sys/class/nvram/nv-config/keys/bus_bcm_speed_restriction" 2>/dev/null)"
            check_eq 'real TouchTune: lvds restriction disabled' disable \
                "$(cat "$CMUB/sys/class/nvram/nv-config/keys/lvds_speed_restriction" 2>/dev/null)"
            check_file 'real TouchTune: own backup on the car' "$CMUB/data/touchtune/backups/common-js/Common.js"
            run_stick "$CMUB" "$SB" diagnose
            check_contains 'real stick: diagnosis sees both installed' "$(ls "$SB"/diag-*.txt | head -n1)" 'state=installed'
            run_stick "$CMUB" "$SB" uninstall
            check_rc 'real stick: removal exit code' "$?" 0
            check_stock_unchanged 'real stick: AA originals byte-identical' "$CMUB" "$BEFOREB"
            check_hash 'real TouchTune: Common.js restored' "$CMUB/jci/gui/common/js/Common.js" "$COMMON_BEFORE"
            check_eq 'real TouchTune: bus restriction enabled' enable \
                "$(cat "$CMUB/sys/class/nvram/nv-config/keys/bus_bcm_speed_restriction" 2>/dev/null)"
            check_eq 'real TouchTune: lvds restriction enabled' enable \
                "$(cat "$CMUB/sys/class/nvram/nv-config/keys/lvds_speed_restriction" 2>/dev/null)"
        else
            check_contains 'real stick: AA alone on an unknown Common.js' "$TESTROOT/run.log" 'Install only Android Auto touch'
            check_not_contains 'real stick: TouchTune not started' "$TESTROOT/run.log" 'starting TouchTune'
            run_stick "$CMUB" "$SB" uninstall
            check_rc 'real stick: removal exit code' "$?" 0
            check_stock_unchanged 'real stick: AA originals byte-identical' "$CMUB" "$BEFOREB"
            printf 'note: real TouchTune run needs MZD_TEST_REAL_ROOTFS with the stock Common.js\n'
        fi
        [ "$rcb" = 0 ] || sed -n '1,60p' "$TESTROOT/run.log"

        # The real 1.0.0 release stick (rebuilt from tag v1.0.0), then this
        # stick: the 1.0.0 installation is updated in place.
        if command -v git >/dev/null 2>&1 && command -v tar >/dev/null 2>&1 && \
           git -C "$REPO" rev-parse -q --verify 'refs/tags/v1.0.0^{commit}' >/dev/null 2>&1; then
            OLDREPO="$TESTROOT/repo-v1.0.0"
            mkdir -p "$OLDREPO"
            if git -C "$REPO" archive v1.0.0 | tar -x -C "$OLDREPO" && \
               "$PY" -I "$OLDREPO/tools/build_stick.py" build --out "$TESTROOT/dist-1.0.0" \
                   --aa-mod-zip "$DL/oem-aa-mod-0.10.0.zip" --touchtune-zip "$DL/TouchTune-1.2.1.zip" \
                   --aa-mod-license "$DL/oem-aa-mod-0.10.0-LICENSE" --aa-mod-notice "$DL/oem-aa-mod-0.10.0-NOTICE.md" \
                   >"$TESTROOT/builder-1.0.0.log" 2>&1; then
                ok 'builder 1.0.0: release stick rebuilt from the tag'
                CMUV=$(new_cmu real-update)
                BEFOREV=$(stock_sums "$CMUV")
                cp -a "$TESTROOT/dist-1.0.0/stick" "$TESTROOT/stick-1.0.0"
                run_stick "$CMUV" "$TESTROOT/stick-1.0.0" install
                check_rc 'real 1.0.0 stick: install exit code' "$?" 0
                check_eq 'real 1.0.0 stick: 3 markers (Android Auto 1.6)' 3 "$(count_markers "$CMUV/jci/sm/sm.conf")"
                check_hash 'real 1.0.0 stick: release libpatch.conf' "$CMUV/data_persist/oem-aa-mod/libpatch.conf" \
                    6b32397273f6e445fd8470643cb9b99d4f792f755b89780b3f73af2f1d835582
                BKV=$(marker_backup "$CMUV")
                cp -a "$BS" "$TESTROOT/stick-builder-update"
                SBU="$TESTROOT/stick-builder-update"
                run_stick "$CMUV" "$SBU" status
                check_contains 'real update: 1.0.0 recognized as outdated' "$TESTROOT/run.log" 'older installation (installer 1.0.0: Android Auto 1.6)'
                run_stick "$CMUV" "$SBU" install
                check_rc 'real update 1.0.0 -> new: exit code' "$?" 0
                check_contains 'real update: in place' "$TESTROOT/run.log" 'update in place with the existing backup'
                check_eq 'real update: 2 markers' 2 "$(count_markers "$CMUV/jci/sm/sm.conf")"
                check_eq 'real update: 2 markers (sm_WCP.conf)' 2 "$(count_markers "$CMUV/jci/sm/sm_WCP.conf")"
                check_no_file 'real update: aap_service shim not live' "$CMUV/data_persist/oem-aa-mod/libpatch-aap_service.so"
                check_hash 'real update: libpatch.conf with 1.6 off' "$CMUV/data_persist/oem-aa-mod/libpatch.conf" \
                    b874a9cf85916799032ae5b874d88a2f714d733a31a3e6cdeba785c6e25d827a
                if marker_has "$CMUV" previous_installer=1.0.0 && marker_has "$CMUV" "backup=$BKV" && \
                   marker_has "$CMUV" protocol_v16=0; then
                    ok 'real update: marker (previous 1.0.0, same backup, 1.6 off)'
                else
                    bad 'real update: marker (previous 1.0.0, same backup, 1.6 off)' "$(tr '\n' ' ' <"$CMUV/data_persist/oem-aa-mod/install-state")"
                fi
                check_eq 'real update: one backup' 1 "$(backup_count "$CMUV")"
                check_xml_patched 'real update: AA XML = factory file + touch' "$CMUV/etc/aap_system_attributes.xml" \
                    "$TESTROOT/cmu-template/etc/aap_system_attributes.xml" true
                run_stick "$CMUV" "$SBU" status
                check_contains 'real update: then ours' "$TESTROOT/run.log" 'state=ours'
                run_stick "$CMUV" "$SBU" uninstall
                check_rc 'real update: removal exit code' "$?" 0
                check_stock_unchanged 'real update: AA originals byte-identical' "$CMUV" "$BEFOREV"
            else
                bad 'builder 1.0.0: release stick rebuilt from the tag' "$(tail -n 3 "$TESTROOT/builder-1.0.0.log" 2>/dev/null)"
            fi
        else
            printf 'skip real 1.0.0 -> new update (git, tar or tag v1.0.0 missing)\n'
        fi
    else
        bad 'builder runs' 'see builder.log'
        sed -n '1,20p' "$TESTROOT/builder.log"
    fi
else
    printf 'skip builder test (python or downloads/ missing: python3 tools/build_stick.py build --download)\n'
fi

# ---------------------------------------------------------------------------
printf '\n=========================================\n'
printf 'Result: %s ok, %s failed\n' "$PASS" "$FAIL"
printf '=========================================\n'
[ "$FAIL" -eq 0 ]
