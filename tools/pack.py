#!/usr/bin/env python
# Build the distributable KSU module zip.
#
# PowerShell's Compress-Archive writes backslash entry names (camfix\x.xml) and
# drops the unix mode, which makes the module silently fail to run its scripts,
# so packaging goes through this script instead. Entries are copied byte-for-byte
# from the working tree (no newline translation).
#
#   python tools/pack.py            # -> dist/HonorSchedulerUnlock-<ver>.zip
import os
import re
import stat
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXEC = {"META-INF/com/google/android/update-binary", "customize.sh", "action.sh",
        "post-fs-data.sh", "service.sh", "dashboard.sh", "webui_ctl.sh",
        "uninstall.sh"}
# Byte-exact payloads: the shipped camera/QR override files must keep their
# original CRLF/encoding, so they are never rewritten by an editor round-trip.
FIXED = ["META-INF/com/google/android/update-binary",
         "META-INF/com/google/android/updater-binary",
         "customize.sh", "module.prop", "action.sh", "post-fs-data.sh",
         "service.sh", "dashboard.sh", "webui_ctl.sh", "uninstall.sh",
         "qrfix/facemaskconfig.xml", "camfix/SmartAE_back_orig.xml",
         "camfix/sharpen.awk", "webroot/index.html"]


def version():
    with open(os.path.join(ROOT, "module.prop"), "rb") as f:
        txt = f.read().decode("utf-8")
    name = re.search(r"^version=(.+)$", txt, re.M).group(1).strip()
    code = int(re.search(r"^versionCode=(\d+)$", txt, re.M).group(1))
    return name, code


def main():
    ver, code = version()
    missing = [p for p in FIXED if not os.path.isfile(os.path.join(ROOT, p.replace("/", os.sep)))]
    if missing:
        raise SystemExit("MISSING: " + ", ".join(missing))
    out = os.path.join(ROOT, "dist", "HonorSchedulerUnlock-%s.zip" % ver)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for rel in FIXED:
            with open(os.path.join(ROOT, rel.replace("/", os.sep)), "rb") as f:
                data = f.read()
            if rel.endswith((".sh", ".awk", "update-binary")) and b"\r\n" in data:
                raise SystemExit("CRLF in %s - module would fail to run" % rel)
            mode = 0o755 if rel in EXEC else 0o644
            zi = zipfile.ZipInfo(rel, date_time=(2026, 1, 1, 0, 0, 0))
            zi.external_attr = stat.S_IMODE(mode) << 16
            zi.compress_type = zipfile.ZIP_DEFLATED if rel.endswith((".sh", ".prop", ".html", ".xml", "update-binary")) else zipfile.ZIP_STORED
            z.writestr(zi, data)
    print("BUILT", out, os.path.getsize(out), "bytes,", len(FIXED), "entries, version=%s (%d)" % (ver, code))


if __name__ == "__main__":
    main()
