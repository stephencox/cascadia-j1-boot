#!/usr/bin/env bash
# Pack build/j1-staging.bin: [loader][pad][16-byte header][kernel Image at
# 0x80008000][pad to 8][DTB]. The header is "J1IM", the DTB's offset from
# the Image and its size; the loader copies the DTB clear of the kernel's
# BSS and enters the Image directly (loader/j1_boot.S). No decompressor
# runs, so nothing here depends on the compiler. Does not call irecovery.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOADER="$ROOT/build/j1-boot.bin"
KIMAGE="$ROOT/build/j1-Image"
DTB="$ROOT/build/j1ap.dtb"
OUT="$ROOT/build/j1-staging.bin"
PAD=$((0x8000))

fail() { echo "error: $*" >&2; exit 1; }

[ -f "$LOADER" ] || fail "no loader at $LOADER"
[ -f "$KIMAGE" ] || fail "no kernel Image at $KIMAGE"
[ -f "$DTB" ] || fail "no DTB at $DTB"

python3 - "$LOADER" "$KIMAGE" "$DTB" "$OUT" "$PAD" << 'PACK'
import sys
from pathlib import Path

loader, image, dtb = (Path(a).read_bytes() for a in sys.argv[1:4])
out, pad = Path(sys.argv[4]), int(sys.argv[5])
if len(loader) > pad - 16:
    raise SystemExit(f"loader is {len(loader)} bytes, leaves no room for the header")
if dtb[:4] != bytes.fromhex("d00dfeed"):
    raise SystemExit("DTB has no FDT magic")
if image[:4] == bytes.fromhex("d00dfeed"):
    raise SystemExit("the Image starts with an FDT magic")
# The bootargs must start the built-in initramfs's /init.
# rdinit=/bin/busybox is the debug path: busybox runs an applet straight
# from the bootargs after "--", without /init.
idx = dtb.find(b"rdinit=")
if idx < 0 or not any(r in dtb[idx:idx + 320]
                      for r in (b"rdinit=/init ", b"rdinit=/bin/busybox ")):
    raise SystemExit("DTB bootargs have no rdinit=/init")
if b"root=/dev/ram0" in dtb[idx:idx + 240]:
    raise SystemExit("bootargs still name an empty ramdisk")
# The staging must fit iBEC's go window (up to 0x83f00000); the loader
# copies the DTB to 0x84000000, above it and above the kernel's BSS.
dtb_off = len(image) + (8 - len(image) % 8) % 8
end = 0x80008000 + dtb_off + len(dtb)
if end > 0x83f00000:
    raise SystemExit(f"staging ends at {end:#x}, past iBEC's 0x83f00000")
hdr = b"J1IM" + dtb_off.to_bytes(4, "little") + len(dtb).to_bytes(4, "little") + bytes(4)
blob = loader + bytes(pad - 16 - len(loader)) + hdr + image + bytes(dtb_off - len(image)) + dtb
out.write_bytes(blob)
print(f"staging {len(blob)} bytes: loader {len(loader)}, Image at 0x80008000 "
      f"({len(image)} bytes), dtb at {0x80008000 + dtb_off:#x} size {len(dtb):#x}")
PACK
ls -l "$OUT"
echo "ok: $OUT"
