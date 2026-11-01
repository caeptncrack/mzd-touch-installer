#!/usr/bin/env python3
"""Build the MZD Touch Installer USB stick (Windows, macOS, Linux).

    python3 tools/build_stick.py build --download
    python3 tools/build_stick.py build --download --target E:\\
    python3 tools/build_stick.py build --aa-mod-zip oem-aa-mod-0.10.0.zip \\
        --touchtune-zip TouchTune-1.2.1.zip --aa-mod-license LICENSE --aa-mod-notice NOTICE.md
    python3 tools/build_stick.py clean /Volumes/MZD

"build" fetches (or takes) the two pinned upstream releases, checks every
upstream file against a pinned SHA-256, assembles the stick in dist/stick/,
verifies it exactly the way run.sh does on the car and writes the release ZIP
dist/mzd-touch-installer-<version>.zip (files at the top level, ready to be
copied onto an empty FAT32 stick). With --target it also writes the stick.

"clean" removes macOS Finder metadata ("._*" files and friends) from a stick
that carries this installer, because "._<launcher>.up" files can stop the
car from starting the stick.

Only the Python standard library is used. No Mazda file is read or shipped.

Copyright (C) 2026 caeptncrack
SPDX-License-Identifier: GPL-3.0-or-later
"""

import argparse
import hashlib
import io
import os
import re
import shutil
import stat
import sys
import tempfile
import urllib.error
import urllib.request
import zipfile
from pathlib import Path, PurePosixPath

REPO = Path(__file__).resolve().parent.parent
SRC = REPO / "stick"

STICK_ID = "mzd-touch-installer-v1"
DEFAULT_PROJECT_URL = "https://github.com/caeptncrack/mzd-touch-installer"

# The file NAME of this empty file is the code the CMU's update service runs:
# it finds the one mounted stick that carries STICK.ID and run.sh and starts
# run.sh. FAT32 accepts every character in it.
LAUNCHER = (
    "$(S=${HOME%root};N=0;J=;for D in sda1 sdb1 sdc1 sdd1;do P=${S}tmp${S}mnt${S}$D;"
    "M=$P${S}STICK.ID;[ -f $M ]&&[ -f $P${S}run.sh ]&&{ N=$((N+1));J=$P${S}run.sh;};done;"
    "[ $N = 1 ]&&sh $J).up"
)

AA_TAG = "0.10.0"
AA_ZIP = {
    "name": "oem-aa-mod-0.10.0.zip",
    "url": "https://github.com/VitaliyKurokhtin/oem-aa-mod/releases/download/0.10.0/oem-aa-mod-0.10.0.zip",
    "sha256": "ba7a0c285269a87e8a199e38517de05da749a67df7ca016abb6d15e65112dc6a",
}
AA_LICENSE = {
    "name": "oem-aa-mod-0.10.0-LICENSE",
    "url": "https://raw.githubusercontent.com/VitaliyKurokhtin/oem-aa-mod/0.10.0/LICENSE",
    "sha256": "d8de517917a591daa447d6be28ffb2fac866703e4feb65e86221be9a22d3033a",
}
AA_NOTICE = {
    "name": "oem-aa-mod-0.10.0-NOTICE.md",
    "url": "https://raw.githubusercontent.com/VitaliyKurokhtin/oem-aa-mod/0.10.0/NOTICE.md",
    "sha256": "e8040f38762f82936d5ba58add63f891205cc627ee3654cc1fc9e53208d90d37",
}
# Files taken from the oem-aa-mod release ZIP (path in the ZIP -> name on the stick).
AA_FILES = {
    "oem-aa-mod-0.10.0/libpatch-blmjciaapa.so":
        ("libpatch-blmjciaapa.so", "a6b87f72ae31429cebe14eea5c6d3a4a2749d4ea643a8c73303b3437533ad5b5"),
    "oem-aa-mod-0.10.0/libpatch-svcjcinavi.so":
        ("libpatch-svcjcinavi.so", "01f3939c764f6fb411b0898e77e88ffefb351404c81179070b2691f5406f9b56"),
    "oem-aa-mod-0.10.0/libpatch-aap_service.so":
        ("libpatch-aap_service.so", "b3a63c334d90be2810e2f22289e91eb71fab94de283edb4e504e00ceac656556"),
    "oem-aa-mod-0.10.0/resources/aap_system_attributes.xml":
        ("aap_system_attributes.xml", "a4774f19940cd1c2afbaad72a9bf0c4dd7a992793d1dfed02509dcf1e93ed023"),
    "oem-aa-mod-0.10.0/resources/aap_system_attributes_UCP.xml":
        ("aap_system_attributes_UCP.xml", "56bcff198fb0a21862793013679b187eef0c8da831134c0cf519632b78a927c2"),
    "oem-aa-mod-0.10.0/resources/libpatch.conf":
        ("libpatch.conf", "6b32397273f6e445fd8470643cb9b99d4f792f755b89780b3f73af2f1d835582"),
}
# libpatch.conf is shipped with one line changed: use_protocol_v1_6 = false
# (the upstream default; the release file says true). With Android Auto 1.6 a
# wireless phone skips the Bluetooth pairing request Mazda Connect waits for,
# so wireless adapters only connect through oem-aa-mod's name-list workaround.
CONF_V16_ON = re.compile(rb"(?m)^use_protocol_v1_6 = true$")
CONF_V16_OFF = b"use_protocol_v1_6 = false"
CONF_SHIPPED_SHA256 = "b874a9cf85916799032ae5b874d88a2f714d733a31a3e6cdeba785c6e25d827a"

TT_TAG = "v1.2.1"
TT_ZIP = {
    "name": "TouchTune-1.2.1.zip",
    "url": "https://github.com/Miatafy/TouchTune/releases/download/v1.2.1/TouchTune-1.2.1.zip",
    "sha256": "3397a541aacebb1c0a4476c12eeb3479a643990ba67521745c7de47ad072dc68",
}
TT_FILE_COUNT = 13
# Files of touchtune/ carried by PAYLOAD.SHA256. The TouchTune launcher is not
# among them: its 253-character name makes touchtune/<name> too long for Windows
# Explorer, so it travels as lib/touchtune-launcher and run.sh gives it its
# official name on the car.
TT_LAUNCHER_COPY = "lib/touchtune-launcher"
TT_MANIFEST = [
    "install-patches.sh", "lib/touchtune-helpers.sh", "patches/touch-while-driving.sh",
    "PAYLOAD.SHA256", "TOUCHTUNE.ID", "VERSION", "LAUNCHER.NAME", "jci-autoupdate",
    "LICENSE", "NOTICE", "SOURCE.txt", "macos-usb-eject.sh",
]

OWN_TEXT_FILES = [
    "run.sh", "lib/mzd-safety.sh", "lib/aa-touch.sh", "lib/combined.sh",
    "payload/install.sh", "payload/uninstall.sh", "payload/diagnose.sh",
]
# Must match EXPECTED in stick/run.sh.
PAYLOAD_MANIFEST = [
    "VERSION", "STICK.ID", "LAUNCHER.NAME", "jci-autoupdate",
] + OWN_TEXT_FILES + [TT_LAUNCHER_COPY, "aa-mod/SHA256SUMS"] + ["touchtune/" + n for n in TT_MANIFEST]

# Never on the stick: Mazda files (by name, and by the hashes we know).
MAZDA_NAMES = {
    "sm.conf", "sm_wcp.conf", "common.js", "systemapp.js", "blmjciaapa.so",
    "svcjcinavi.so", "aap_service", "version.ini", "jci-dialog",
}
MAZDA_HASHES = {
    "fa3484d7c644393ab6cb083990e483201129a207e7755459296dde8ec82a4d84",  # sm.conf EU
    "92034449e76689b995fcd369d584f441829a0ee6e8d74c858cd92f4049f7b27d",  # sm_WCP.conf EU
    "bc852037615dcb4e4eb24ab6f30a2e6f817fe00a22a2f767478b25f75b036812",  # aap_system_attributes.xml EU
    "6a59ae58b903af4a943dfc2cd94560128b2d42f3d097c8c82d43b5d899c17063",  # ..._UCP.xml EU
    "376b30a46366a543122956d7feb1b44f147425015837a4d83fedf12a67943351",  # Common.js stock
    "019eba18e8d629ddb1d55563aab138ce1eb3329fab67b71d9b4178377cf9d9ce",  # Common.js TouchTune
    "23106b04bd6bad514dd879b217a34a0f0289d58f86a0ae022488be6a022ca8e1",  # systemApp.js stock
}

# Left alone on a target stick.
SYSTEM_ENTRIES = {"System Volume Information", "$RECYCLE.BIN", ".fseventsd",
                  ".Spotlight-V100", ".Trashes", ".TemporaryItems"}
KEEP_ON_UPDATE = ("mzd-usb.log",)
KEEP_DIR_PREFIX = "backup-aa-touch-"     # the user's copy of the car's files
TT_LOG = "touchtune/touchtune.log"
MAC_JUNK_DIRS = (".fseventsd", ".Spotlight-V100", ".Trashes", ".TemporaryItems")

ZIP_TIME = (2026, 10, 31, 12, 0, 0)


class BuildError(Exception):
    pass


def say(msg):
    print(msg, flush=True)


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def lf_text(data, name):
    """Normalise one of our own text files to LF with a final newline."""
    if b"\x00" in data:
        raise BuildError(f"{name}: binary data in a text file")
    data = data.replace(b"\r\n", b"\n")
    if b"\r" in data:
        raise BuildError(f"{name}: stray CR character")
    try:
        data.decode("ascii")
    except UnicodeDecodeError:
        raise BuildError(f"{name}: non-ASCII character (the CMU shell and dialogs expect ASCII)")
    if not data.endswith(b"\n"):
        data += b"\n"
    return data


def fetch(spec, given, cache, download):
    """Return the bytes of a pinned input, from --file, the cache or GitHub."""
    path = None
    if given:
        path = Path(given)
        if not path.is_file():
            raise BuildError(f"not found: {given}")
    else:
        cached = cache / spec["name"]
        if cached.is_file() and sha256_file(cached) == spec["sha256"]:
            path = cached
        elif download:
            say(f"  downloading {spec['url']}")
            req = urllib.request.Request(spec["url"], headers={"User-Agent": "mzd-touch-installer-build"})
            with urllib.request.urlopen(req, timeout=60) as resp:
                data = resp.read()
            if sha256_bytes(data) != spec["sha256"]:
                raise BuildError(f"{spec['name']}: downloaded file has an unexpected SHA-256 "
                                 f"({sha256_bytes(data)}, expected {spec['sha256']})")
            cache.mkdir(parents=True, exist_ok=True)
            cached.write_bytes(data)
            path = cached
        else:
            raise BuildError(f"{spec['name']} missing: pass --download or the local file")
    data = path.read_bytes()
    if sha256_bytes(data) != spec["sha256"]:
        raise BuildError(f"{path}: unexpected SHA-256 {sha256_bytes(data)} (expected the pinned "
                         f"release {spec['sha256']})")
    return data


def zip_members(data, label):
    """Read a ZIP into {posix path: bytes}, refusing unsafe member names."""
    out = {}
    with zipfile.ZipFile(io.BytesIO(data)) as zf:
        for info in zf.infolist():
            name = info.filename
            p = PurePosixPath(name)
            if p.is_absolute() or ".." in p.parts or "\\" in name or ":" in name:
                raise BuildError(f"{label}: unsafe path in ZIP: {name!r}")
            if info.is_dir():
                continue
            mode = (info.external_attr >> 16) & 0o170000
            if mode == stat.S_IFLNK:
                raise BuildError(f"{label}: symlink in ZIP: {name!r}")
            out[str(p)] = zf.read(info)
    return out


def aa_mod_files(zip_data, license_data, notice_data):
    members = zip_members(zip_data, "oem-aa-mod ZIP")
    files = {}
    sums = []
    for src, (dst, digest) in AA_FILES.items():
        if src not in members:
            raise BuildError(f"oem-aa-mod ZIP: {src} missing")
        if sha256_bytes(members[src]) != digest:
            raise BuildError(f"oem-aa-mod ZIP: {src} has an unexpected SHA-256")
        data = members[src]
        if dst == "libpatch.conf":
            data, count = CONF_V16_ON.subn(CONF_V16_OFF, data)
            if count != 1 or sha256_bytes(data) != CONF_SHIPPED_SHA256:
                raise BuildError("libpatch.conf: switching use_protocol_v1_6 off did not give the "
                                 "expected file")
            digest = CONF_SHIPPED_SHA256
        files[dst] = data
        sums.append(f"{digest}  {dst}")
    files["SHA256SUMS"] = ("\n".join(sums) + "\n").encode()
    files["VERSION"] = (AA_TAG + "\n").encode()
    files["LICENSE"] = license_data
    files["NOTICE.md"] = notice_data
    files["SOURCE.txt"] = (
        f"oem-aa-mod {AA_TAG} - Android Auto touch for Mazda Connect\n"
        "Author:   VitaliyKurokhtin\n"
        "Upstream: https://github.com/VitaliyKurokhtin/oem-aa-mod (AGPL-3.0)\n"
        f"Release:  https://github.com/VitaliyKurokhtin/oem-aa-mod/releases/tag/{AA_TAG}\n"
        f"Source:   https://github.com/VitaliyKurokhtin/oem-aa-mod/tree/{AA_TAG}\n"
        f"ZIP SHA-256: {AA_ZIP['sha256']}\n"
        "\n"
        "The three shims and both aap_system_attributes XMLs are copied\n"
        "unmodified from the release ZIP. libpatch.conf is the release file with\n"
        "one line changed: use_protocol_v1_6 = false (Android Auto 1.5, as from\n"
        "the factory, so wireless adapters keep their Bluetooth pairing request).\n"
        "SHA256SUMS lists the files as shipped and is checked by the installer\n"
        f"on the car. LICENSE and NOTICE.md are the upstream files of tag {AA_TAG}.\n"
    ).encode()
    return files


def touchtune_files(zip_data):
    members = zip_members(zip_data, "TouchTune ZIP")
    roots = [n[: -len("TOUCHTUNE.ID")] for n in members if n.endswith("TOUCHTUNE.ID")]
    if len(roots) != 1:
        raise BuildError("TouchTune ZIP: expected exactly one TOUCHTUNE.ID")
    root = roots[0]
    files = {n[len(root):]: d for n, d in members.items() if n.startswith(root)}
    if len(files) != len(members):
        raise BuildError("TouchTune ZIP: files outside the release folder")
    if len(files) != TT_FILE_COUNT:
        raise BuildError(f"TouchTune ZIP: {len(files)} files, expected {TT_FILE_COUNT}")
    launcher = files["LAUNCHER.NAME"].decode().strip()
    seen = 0
    for line in files["PAYLOAD.SHA256"].decode().splitlines():
        if not line.strip():
            continue
        digest, rel = line.split(None, 1)
        rel = rel.strip()
        key = launcher if rel == "@launcher" else rel
        if key not in files or sha256_bytes(files[key]) != digest:
            raise BuildError(f"TouchTune ZIP: {rel} does not match TouchTune's own manifest")
        seen += 1
    if seen != 8:
        raise BuildError(f"TouchTune ZIP: its PAYLOAD.SHA256 has {seen} entries, expected 8")
    for rel in TT_MANIFEST:
        if rel not in files:
            raise BuildError(f"TouchTune ZIP: {rel} missing")
    return files


def assemble(args):
    version = lf_text((REPO / "VERSION").read_bytes(), "VERSION").decode().strip()
    lib_version = None
    for line in (SRC / "lib" / "mzd-safety.sh").read_text(encoding="ascii").splitlines():
        if line.startswith("MZD_INSTALLER_VERSION="):
            lib_version = line.split("=", 1)[1].strip('"')
    if lib_version != version:
        raise BuildError(f"VERSION {version} differs from MZD_INSTALLER_VERSION {lib_version}")

    cache = REPO / "downloads"
    say("Upstream releases (pinned SHA-256):")
    aa_zip = fetch(AA_ZIP, args.aa_mod_zip, cache, args.download)
    aa_license = fetch(AA_LICENSE, args.aa_mod_license, cache, args.download)
    aa_notice = fetch(AA_NOTICE, args.aa_mod_notice, cache, args.download)
    tt_zip = fetch(TT_ZIP, args.touchtune_zip, cache, args.download)
    say(f"  oem-aa-mod {AA_TAG} and TouchTune {TT_TAG}: verified")

    files = {}
    for rel in OWN_TEXT_FILES:
        files[rel] = lf_text((SRC / rel).read_bytes(), rel)
    readme = lf_text((SRC / "README.txt").read_bytes(), "README.txt").decode()
    files["README.txt"] = readme.replace("@PROJECT_URL@", args.project_url).encode()
    files["VERSION"] = (version + "\n").encode()
    files["STICK.ID"] = (STICK_ID + "\n").encode()
    files["LAUNCHER.NAME"] = (LAUNCHER + "\n").encode()
    files["jci-autoupdate"] = b""
    files[LAUNCHER] = b""
    for name, data in aa_mod_files(aa_zip, aa_license, aa_notice).items():
        files["aa-mod/" + name] = data
    tt = touchtune_files(tt_zip)
    tt_launcher = tt["LAUNCHER.NAME"].decode().strip()
    files[TT_LAUNCHER_COPY] = tt.pop(tt_launcher)
    for name, data in tt.items():
        files["touchtune/" + name] = data

    manifest = "".join(f"{sha256_bytes(files[rel])}  {rel}\n" for rel in sorted(PAYLOAD_MANIFEST))
    files["PAYLOAD.SHA256"] = manifest.encode()
    files["SHA256SUMS.txt"] = "".join(
        f"{sha256_bytes(files[rel])}  {rel}\n" for rel in sorted(files)).encode()
    return version, files


def check_no_mazda_files(files):
    for rel, data in files.items():
        name = PurePosixPath(rel).name.lower()
        if name in MAZDA_NAMES:
            raise BuildError(f"Mazda file name on the stick: {rel}")
        if sha256_bytes(data) in MAZDA_HASHES:
            raise BuildError(f"Mazda file content on the stick: {rel}")
        if name.endswith((".png", ".jpg", ".js", ".ini")):
            raise BuildError(f"unexpected file type on the stick: {rel}")


def verify_tree(root):
    """Check a stick folder the way run.sh does on the car."""
    root = Path(root)
    sid = (root / "STICK.ID").read_text().strip()
    if sid != STICK_ID:
        raise BuildError("STICK.ID is wrong")
    lines = [l for l in (root / "PAYLOAD.SHA256").read_text().splitlines() if l]
    if len(lines) != len(PAYLOAD_MANIFEST):
        raise BuildError(f"PAYLOAD.SHA256 has {len(lines)} entries, expected {len(PAYLOAD_MANIFEST)}")
    entries = {}
    for line in lines:
        digest, rel = line.split("  ", 1)
        if len(digest) != 64 or rel in entries:
            raise BuildError(f"PAYLOAD.SHA256 is damaged: {line}")
        entries[rel] = digest
    for rel in PAYLOAD_MANIFEST:
        if rel not in entries:
            raise BuildError(f"PAYLOAD.SHA256: {rel} missing")
        if sha256_file(root / rel) != entries[rel]:
            raise BuildError(f"{rel}: hash differs from PAYLOAD.SHA256")
    if (root / "jci-autoupdate").stat().st_size != 0:
        raise BuildError("jci-autoupdate is not empty")
    ups = [p.name for p in root.iterdir() if p.name.endswith(".up") and not p.name.startswith(".")]
    if ups != [LAUNCHER]:
        raise BuildError(f"exactly one .up launcher expected, found {ups}")
    if (root / "LAUNCHER.NAME").read_text().strip() != LAUNCHER:
        raise BuildError("LAUNCHER.NAME does not match the launcher")
    if (root / "ACTION.txt").exists():
        raise BuildError("ACTION.txt must not be on a release stick")
    tt_launcher = None
    for line in (root / "touchtune" / "PAYLOAD.SHA256").read_text().splitlines():
        if line.endswith("  @launcher"):
            tt_launcher = line.split("  ", 1)[0]
    if sha256_file(root / TT_LAUNCHER_COPY) != tt_launcher:
        raise BuildError(f"{TT_LAUNCHER_COPY} does not match TouchTune's @launcher entry")
    tt_ups = [p.name for p in (root / "touchtune").iterdir() if p.name.lower().endswith(".up")]
    if tt_ups:
        raise BuildError("touchtune/ must not carry the launcher (run.sh creates it on the car)")
    junk = [str(p.relative_to(root)) for p in root.rglob("._*")]
    if junk:
        raise BuildError(f"macOS metadata files on the stick: {junk[:3]} (run: build_stick.py clean)")
    sums = {}
    for line in (root / "aa-mod" / "SHA256SUMS").read_text().splitlines():
        digest, name = line.split("  ", 1)
        sums[name] = digest
    for name in ("libpatch-blmjciaapa.so", "libpatch-svcjcinavi.so", "libpatch-aap_service.so",
                 "aap_system_attributes.xml", "aap_system_attributes_UCP.xml", "libpatch.conf"):
        if sha256_file(root / "aa-mod" / name) != sums.get(name):
            raise BuildError(f"aa-mod/{name} does not match aa-mod/SHA256SUMS")
    if sums.get("libpatch.conf") != CONF_SHIPPED_SHA256:
        raise BuildError("aa-mod/libpatch.conf is not the shipped file (use_protocol_v1_6 = false)")


def write_tree(files, root):
    for rel, data in sorted(files.items()):
        dest = root.joinpath(*PurePosixPath(rel).parts)
        dest.parent.mkdir(parents=True, exist_ok=True)
        with open(dest, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())


def write_zip(files, path):
    tmp = path.with_suffix(".zip.tmp")
    with zipfile.ZipFile(tmp, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for rel in sorted(files):
            info = zipfile.ZipInfo(rel, date_time=ZIP_TIME)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = (0o100755 if rel.endswith(".sh") else 0o100644) << 16
            info.create_system = 3
            zf.writestr(info, files[rel])
    os.replace(tmp, path)


def target_state(target):
    entries = [p for p in target.iterdir() if p.name not in SYSTEM_ENTRIES]
    if not entries:
        return "empty", entries
    sid = target / "STICK.ID"
    if sid.is_file() and sid.read_text(errors="replace").strip() == STICK_ID:
        return "ours", entries
    return "foreign", entries


def clean_mac_metadata(target):
    removed = 0
    for p in sorted(target.rglob("._*"), reverse=True):
        if p.is_file():
            p.unlink()
            removed += 1
    for p in target.rglob(".DS_Store"):
        p.unlink()
        removed += 1
    for name in MAC_JUNK_DIRS:
        d = target / name
        if d.is_dir():
            shutil.rmtree(d, ignore_errors=True)
            removed += 1
    return removed


def keep_on_update(p):
    """Logs, diagnoses and the user's backup copies survive a stick update."""
    if p.name in KEEP_ON_UPDATE:
        return True
    if p.name.startswith("diag-") and p.name.endswith(".txt") and p.is_file():
        return True
    return p.name.startswith(KEEP_DIR_PREFIX) and p.is_dir() and not p.is_symlink()


def write_target(files, target):
    target = Path(target)
    if not target.is_dir():
        raise BuildError(f"target is not a folder/drive: {target}")
    state, entries = target_state(target)
    if state == "foreign":
        raise BuildError(f"{target} is not empty and is not an MZD Touch Installer stick; "
                         "format it as FAT32 first (nothing is written)")
    tt_log = None
    if state == "ours":
        log_path = target / TT_LOG
        if log_path.is_file() and not log_path.is_symlink():
            tt_log = log_path.read_bytes()
        for p in entries:
            if keep_on_update(p):
                continue
            if p.is_dir() and not p.is_symlink():
                shutil.rmtree(p)
            else:
                p.unlink()
        say(f"  previous installer files removed from {target} (logs and backup copies kept)")
    write_tree(files, target)
    if tt_log is not None:
        (target / TT_LOG).write_bytes(tt_log)
    clean_mac_metadata(target)
    verify_tree(target)


def cmd_build(args):
    version, files = assemble(args)
    check_no_mazda_files(files)
    out = Path(args.out)
    stick = out / "stick"
    if stick.exists():
        shutil.rmtree(stick)
    stick.mkdir(parents=True)
    write_tree(files, stick)
    verify_tree(stick)
    zpath = out / f"mzd-touch-installer-{version}.zip"
    write_zip(files, zpath)
    with tempfile.TemporaryDirectory() as tmp:
        with zipfile.ZipFile(zpath) as zf:
            for info in zf.infolist():
                dest = Path(tmp).joinpath(*PurePosixPath(info.filename).parts)
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_bytes(zf.read(info))
        verify_tree(tmp)
    say(f"Stick folder: {stick} ({len(files)} files, payload verified)")
    say(f"Release ZIP:  {zpath} (sha256 {sha256_file(zpath)})")
    if args.target:
        write_target(files, args.target)
        say(f"Stick written and verified: {args.target}")
    say("No Mazda files on the stick. Copy the ZIP contents to the top level of an empty FAT32 stick.")


def cmd_clean(args):
    target = Path(args.target)
    state, _ = target_state(target)
    if state != "ours":
        raise BuildError(f"{target} does not carry this installer (STICK.ID); nothing changed")
    removed = clean_mac_metadata(target)
    verify_tree(target)
    say(f"{removed} macOS metadata entries removed; stick verified. Eject it now.")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build", help="build dist/stick and the release ZIP")
    b.add_argument("--download", action="store_true", help="download missing upstream files from GitHub")
    b.add_argument("--aa-mod-zip", help="local oem-aa-mod-0.10.0.zip")
    b.add_argument("--aa-mod-license", help="local LICENSE of oem-aa-mod tag 0.10.0")
    b.add_argument("--aa-mod-notice", help="local NOTICE.md of oem-aa-mod tag 0.10.0")
    b.add_argument("--touchtune-zip", help="local TouchTune-1.2.1.zip")
    b.add_argument("--out", default=str(REPO / "dist"), help="output folder (default: dist/)")
    b.add_argument("--target", help="also write the stick to this drive/folder (must be empty "
                                    "or already carry this installer)")
    b.add_argument("--project-url", default=DEFAULT_PROJECT_URL, help="URL printed in README.txt")
    c = sub.add_parser("clean", help="remove macOS metadata from a stick")
    c.add_argument("target")
    args = ap.parse_args(argv)
    try:
        if args.cmd == "build":
            cmd_build(args)
        else:
            cmd_clean(args)
    except (BuildError, OSError, zipfile.BadZipFile, urllib.error.URLError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
