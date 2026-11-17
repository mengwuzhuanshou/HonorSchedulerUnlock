# -*- coding: utf-8 -*-
"""One-shot build for the bundled eSIM geofence hook APK (no Android SDK).

Reuses the shared standalone engine (axml_writer / arsc_builder / dalvik-dx /
apksig / build-stub) exactly like BiliTamer, but emits a minimal libxposed module
manifest with NO activities (headless hook, scope = com.hihonor.esimservice).

  python esimhook/build.py

Env overrides:
  ESIMFIX_ENGINE   engine dir (default: <repo>/../../../common, fallback BiliTamer/tools/engine)
  ESIMFIX_LIBXPOSED libxposed classes.jar (default: <repo>/../../../BiliTamer/tools/libxposed/classes.jar)
  BILITAMER_JDK / JAVA_HOME  JDK home (else javac/java on PATH)
  ESIMFIX_KEYSTORE / ESIMFIX_KS_PASS / ESIMFIX_KS_ALIAS  (else esimhook/tools/signing.local)
"""
import os
import shutil
import subprocess
import sys
import zipfile

PROJ = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(PROJ)                      # HonorSchedulerUnlock
TEST = os.path.dirname(os.path.dirname(REPO))     # D:/test


def _engine():
    e = os.environ.get("ESIMFIX_ENGINE")
    if e and os.path.isdir(e):
        return e
    for cand in (os.path.join(TEST, "common"),
                 os.path.join(TEST, "BiliTamer", "tools", "engine")):
        if os.path.isfile(os.path.join(cand, "axml_writer.py")):
            return cand
    raise SystemExit("engine not found (set ESIMFIX_ENGINE)")


ENGINE = _engine()
LIBXPOSED = os.environ.get("ESIMFIX_LIBXPOSED",
                           os.path.join(TEST, "BiliTamer", "tools", "libxposed", "classes.jar"))
sys.path.insert(0, ENGINE)
import axml_writer  # noqa: E402
import arsc_builder  # noqa: E402


def _jdk():
    jdk = os.environ.get("BILITAMER_JDK") or os.environ.get("JAVA_HOME")
    if not jdk:
        cand = os.path.join(TEST, "tools", "jdk17")
        if os.path.exists(os.path.join(cand, "bin", "javac.exe")):
            jdk = cand
    if jdk:
        b = os.path.join(jdk, "bin")
        exe = ".exe" if os.name == "nt" else ""
        return os.path.join(b, "javac" + exe), os.path.join(b, "java" + exe)
    return "javac", "java"


JAVAC, JAVA = _jdk()
DX_JAR = os.path.join(ENGINE, "dalvik-dx-11.0.0_r3.jar")
APKSIG_JAR = os.path.join(ENGINE, "apksig-7.4.1.jar")


def run(cmd, desc):
    print("==>", desc)
    p = subprocess.run(cmd, capture_output=True)
    out = (p.stdout or b"").decode("utf-8", errors="replace")
    err = (p.stderr or b"").decode("utf-8", errors="replace")
    if p.returncode != 0:
        print(out[-4000:])
        print(err[-4000:])
        raise SystemExit("FAILED: " + desc)
    if out.strip():
        print(out.strip()[-1500:])
    if err.strip():
        print(err.strip()[-1500:])


def java_sources(base):
    out = []
    for dp, _dn, fns in os.walk(base):
        for fn in fns:
            if fn.endswith(".java"):
                out.append(os.path.join(dp, fn))
    return out


def keystore():
    ks = os.environ.get("ESIMFIX_KEYSTORE")
    pw = os.environ.get("ESIMFIX_KS_PASS")
    al = os.environ.get("ESIMFIX_KS_ALIAS")
    if ks is None:
        local = os.path.join(PROJ, "tools", "signing.local")
        if os.path.exists(local):
            v = {}
            with open(local, "r", encoding="utf-8", errors="replace") as f:
                for line in f:
                    line = line.strip()
                    if line and not line.startswith("#") and "=" in line:
                        k, val = line.split("=", 1)
                        v[k.strip()] = val.strip()
            ks, pw, al = v.get("KS_PATH"), v.get("KS_PASS"), v.get("KS_ALIAS")
    if ks is None:
        raise SystemExit("no keystore: create esimhook/tools/signing.local "
                         "(KS_PATH/KS_PASS/KS_ALIAS) or export ESIMFIX_KEYSTORE/...")
    return ks, pw or "", al or ""


def main():
    ns = {}
    with open(os.path.join(PROJ, "module_conf.py"), "rb") as f:
        exec(compile(f.read(), "module_conf.py", "exec"), ns)
    cfg = ns["MODULE"]
    pkg = cfg["package"]
    vname, vcode = cfg["version_name"], cfg["version_code"]
    label, desc = cfg["app_label"], cfg["xposed_description"]
    scope, entry = cfg["xposed_scope"], cfg["xposed_entry"]
    dist_name = cfg.get("dist_name", pkg + "-v%s.apk")

    BUILD = os.path.join(PROJ, "build")
    DIST = os.path.join(PROJ, "dist")
    STUB = os.path.join(ENGINE, "build-stub")
    APP = os.path.join(PROJ, "app", "src", "main", "java")
    shutil.rmtree(os.path.join(BUILD, "app_classes"), ignore_errors=True)
    os.makedirs(os.path.join(BUILD, "stub_classes"), exist_ok=True)
    os.makedirs(os.path.join(BUILD, "app_classes"), exist_ok=True)
    os.makedirs(DIST, exist_ok=True)

    run([JAVAC, "--release", "8", "-encoding", "UTF-8", "-nowarn", "-d",
         os.path.join(BUILD, "stub_classes")] + java_sources(STUB), "compile stubs")
    cp = os.path.join(BUILD, "stub_classes") + os.pathsep + LIBXPOSED
    run([JAVAC, "--release", "8", "-encoding", "UTF-8", "-nowarn", "-cp", cp, "-d",
         os.path.join(BUILD, "app_classes")] + java_sources(APP), "compile hook")
    run([JAVA, "-cp", DX_JAR, "com.android.dx.command.Main", "--dex",
         "--min-sdk-version=26", "--output", os.path.join(BUILD, "classes.dex"),
         os.path.join(BUILD, "app_classes")], "dex")

    manifest = axml_writer.build_module_manifest(
        package=pkg, version_code=vcode, version_name=vname,
        min_sdk=26, target_sdk=34, app_label=label,
        activities=[], meta_datas=[], allow_backup=False,
        icon_ref=None, utf16=False, order_std=True)
    man = os.path.join(BUILD, "AndroidManifest.xml")
    with open(man, "wb") as f:
        f.write(manifest)
    arsc = arsc_builder.build_minimal_arsc(pkg, label, icon_path=None)
    arsc_path = os.path.join(BUILD, "resources.arsc")
    with open(arsc_path, "wb") as f:
        f.write(arsc)
    print("manifest bytes:", len(manifest), "arsc bytes:", len(arsc))

    meta = os.path.join(BUILD, "META-INF", "xposed")
    os.makedirs(meta, exist_ok=True)
    with open(os.path.join(meta, "java_init.list"), "w", encoding="utf-8") as f:
        f.write(entry + "\n")
    with open(os.path.join(meta, "module.prop"), "w", encoding="utf-8") as f:
        f.write("minApiVersion=101\ntargetApiVersion=102\nstaticScope=true\n")
    with open(os.path.join(meta, "scope.list"), "w", encoding="utf-8") as f:
        f.write(scope + "\n")

    unsigned = os.path.join(BUILD, "unsigned.apk")
    with zipfile.ZipFile(unsigned, "w", zipfile.ZIP_DEFLATED) as z:
        z.write(arsc_path, "resources.arsc", compress_type=zipfile.ZIP_STORED)
        z.write(man, "AndroidManifest.xml")
        z.write(os.path.join(BUILD, "classes.dex"), "classes.dex")
        for fn in ("java_init.list", "module.prop", "scope.list"):
            z.write(os.path.join(meta, fn), "META-INF/xposed/" + fn)
    with zipfile.ZipFile(unsigned) as z:
        info = z.getinfo("resources.arsc")
        off = info.header_offset + 30 + len("resources.arsc".encode()) + len(info.extra)
        assert info.compress_type == 0 and off % 4 == 0, "arsc alignment failed"

    sign_classes = os.path.join(BUILD, "sign_classes")
    os.makedirs(sign_classes, exist_ok=True)
    run([JAVAC, "--release", "8", "-nowarn", "-cp", APKSIG_JAR, "-d", sign_classes,
         os.path.join(ENGINE, "SignApk.java")], "compile SignApk")
    signed = os.path.join(DIST, dist_name % vname)
    ks, pw, al = keystore()
    print("signing keystore:", ks, "alias:", al)
    run([JAVA, "-cp", APKSIG_JAR + os.pathsep + sign_classes, "SignApk",
         unsigned, signed, ks, pw, al, pw, "true"], "sign apk")
    print("\nSIGNED:", signed, os.path.getsize(signed), "bytes")
    # stage into the KSU module payload dir so pack.py picks it up
    payload = os.path.join(REPO, "esimhook", "esimfix.apk")
    shutil.copyfile(signed, payload)
    print("STAGED:", payload)


if __name__ == "__main__":
    main()