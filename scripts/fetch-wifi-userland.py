#!/usr/bin/env python3
"""Put Alpine's iw and wpa_supplicant (armhf, dynamic musl) into build/initramfs/.

Resolves the packages' so: dependencies from APKINDEX, downloads the .apk
files to build/dl/wifi, and unpacks their binaries and shared libraries.
Does not talk to the iPad.
"""
import io
import shutil
import subprocess
import sys
import tarfile
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MIRROR = "https://dl-cdn.alpinelinux.org/alpine/v3.24/main/armhf"
DL = ROOT / "build/dl/wifi"
DEST = ROOT / "build/initramfs"
WANT = ["iw", "wpa_supplicant"]
# Only these go into the image: the programs, and libraries.
KEEP_PREFIXES = ("lib/", "usr/lib/", "sbin/", "usr/sbin/", "usr/bin/")
SKIP_SUFFIXES = (".a", ".pc", ".h")


def fetch(url, path):
    if not path.exists():
        print(f"==> download {path.name}")
        with urllib.request.urlopen(url) as r:
            data = r.read()
        path.write_bytes(data)
    return path.read_bytes()


def index():
    raw = fetch(f"{MIRROR}/APKINDEX.tar.gz", DL / "APKINDEX.tar.gz")
    with tarfile.open(fileobj=io.BytesIO(raw)) as t:
        text = t.extractfile("APKINDEX").read().decode()
    pkgs, provides = {}, {}
    for block in text.split("\n\n"):
        f = {}
        for line in block.splitlines():
            if len(line) > 2 and line[1] == ":":
                f[line[0]] = line[2:]
        if "P" not in f:
            continue
        pkgs[f["P"]] = f
        for p in f.get("p", "").split():
            provides.setdefault(p.split("=")[0], f["P"])
        provides.setdefault(f["P"], f["P"])
    return pkgs, provides


def resolve(pkgs, provides):
    seen, todo = [], list(WANT)
    while todo:
        name = todo.pop()
        if name.startswith("!"):
            continue
        name = name.split("=")[0].split(">")[0].split("<")[0]
        pkg = provides.get(name)
        if pkg is None:
            if name.startswith("/"):
                continue  # a file path dependency (e.g. /bin/sh): busybox has it
            sys.exit(f"error: nothing provides {name}")
        if pkg in seen:
            continue
        seen.append(pkg)
        todo += pkgs[pkg].get("D", "").split()
    return seen


def unpack(apk):
    n = 0
    # An Alpine v2 apk is concatenated gzip tar streams; tar reads them all.
    with tarfile.open(fileobj=io.BytesIO(apk), mode="r:gz") as t:
        for m in t:
            if not m.name.startswith(KEEP_PREFIXES) or m.name.endswith(SKIP_SUFFIXES):
                continue
            out = DEST / m.name
            if m.isdir():
                out.mkdir(parents=True, exist_ok=True)
            elif m.issym():
                out.parent.mkdir(parents=True, exist_ok=True)
                if out.is_symlink() or out.exists():
                    out.unlink()
                out.symlink_to(m.linkname)
                n += 1
            elif m.isfile():
                out.parent.mkdir(parents=True, exist_ok=True)
                out.write_bytes(t.extractfile(m).read())
                out.chmod(m.mode & 0o755 | 0o644)
                n += 1
    return n


def main():
    DL.mkdir(parents=True, exist_ok=True)
    pkgs, provides = index()
    names = resolve(pkgs, provides)
    for name in names:
        if name == "busybox" or name.startswith("busybox-"):
            continue
        ver = pkgs[name]["V"]
        apk = fetch(f"{MIRROR}/{name}-{ver}.apk", DL / f"{name}-{ver}.apk")
        print(f"  {name}-{ver}: {unpack(apk)} files")
    # Not needed on the iPad: an EAP test tool and OpenSSL's plugin modules.
    for extra in ("sbin/eapol_test", "usr/lib/engines-3", "usr/lib/ossl-modules"):
        p = DEST / extra
        if p.is_dir():
            shutil.rmtree(p)
        elif p.exists():
            p.unlink()
    for prog in ("usr/sbin/iw", "sbin/wpa_supplicant", "sbin/wpa_cli"):
        p = DEST / prog
        if not p.exists():
            sys.exit(f"error: {prog} is not in the image")
        info = subprocess.run(["file", "-L", str(p)], capture_output=True, text=True).stdout
        if "ARM" not in info:
            sys.exit(f"error: {prog} is not ARM: {info}")
    if not (DEST / "lib/ld-musl-armhf.so.1").exists():
        sys.exit("error: no musl loader in the image")
    print("ok: iw, wpa_supplicant and wpa_cli in build/initramfs/")


if __name__ == "__main__":
    main()
