#!/usr/bin/env bash
# Pack build/j1-staging.bin. Does not call irecovery.
#
# Default, the Image layout: [loader][pad][16-byte header][kernel Image at
# 0x80008000][pad to 8][DTB]. The header is "J1IM", the DTB's offset from
# the Image and its size; the loader copies the DTB clear of the kernel's
# BSS and enters the Image directly. No decompressor runs, so nothing here
# depends on the compiler.
#
# J1_ZIMAGE=1, the old layout: [loader][pad to 0x8000][zImage+dtb], with
# the loader's hooks in the decompressor. Their sites are fixed offsets
# that hold for GCC 11.4 only, checked below.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOADER="$ROOT/build/j1-boot.bin"
IMAGE="$ROOT/build/j1-zImage-dtb"
OUT="$ROOT/build/j1-staging.bin"
PAD=$((0x8000))

fail() { echo "error: $*" >&2; exit 1; }

[ -f "$LOADER" ] || fail "no loader at $LOADER"

if [ "${J1_ZIMAGE:-0}" != 1 ]; then
    KIMAGE="$ROOT/build/j1-Image"
    DTB="$ROOT/build/j1ap.dtb"
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
# The staging must fit iBEC's go window (up to 0x83f00000); the loader
# copies the DTB to 0x84000000, above it and above the kernel's BSS.
dtb_off = len(image) + (8 - len(image) % 8) % 8
end = 0x80008000 + dtb_off + len(dtb)
if end > 0x83f00000:
    raise SystemExit(f"staging ends at {end:#x}, past iBEC's 0x83f00000")
hdr = b"J1IM" + dtb_off.to_bytes(4, "little") + len(dtb).to_bytes(4, "little") + bytes(4)
blob = loader + bytes(pad - 16 - len(loader)) + hdr + image + bytes(dtb_off - len(image)) + dtb
out.write_bytes(blob)
print(f"staging {len(blob)} bytes (Image layout): loader {len(loader)}, Image at 0x80008000 "
      f"({len(image)} bytes), dtb at {0x80008000 + dtb_off:#x} size {len(dtb):#x}")
PACK
    ls -l "$OUT"
    exit 0
fi

[ -f "$IMAGE" ] || fail "no zImage at $IMAGE"

python3 - "$LOADER" "$IMAGE" "$OUT" "$PAD" << 'PY'
import sys
from pathlib import Path

loader = Path(sys.argv[1]).read_bytes()
image = Path(sys.argv[2]).read_bytes()
pad = int(sys.argv[4])
if len(loader) > pad:
    raise SystemExit(f"loader is {len(loader)} bytes, pad is {pad}")
if image[:4] == bytes.fromhex("d00dfeed"):
    raise SystemExit("zImage starts with an FDT magic; the loader would jump into a DTB")
# The loader plants branches at these sites. Fail if this zImage moved
# (a different compiler than docker/Dockerfile's GCC 11.4 moves them).
expect = {
    0x04: 0xE2255A4D,    # second instruction, digit 7
    0x20: 0xEA0003F6,    # b to the real head at file 0x1000
    0x1000: 0xE10F9000,  # mrs r9, cpsr, digit 8
    0x1008: 0xE1A07001,  # mov r7, r1, after __hyp_stub_install
    0x10B0: 0x2B0000A2,  # blcs cache_on, digit 9
    0x10B4: 0xE28F0F9A,  # add r0, pc, #616, second-row 2
    0x11FC: 0xE9365C0F,  # ldmdb, relocation copy, second-row 3
    0x1224: 0xE1A0F000,  # mov pc, r0, second-row 4
    0x1340: 0xE3A03008,  # mov r3, #8, cache_on, second-row 1
    0x1510: 0xEE010F10,  # mcr SCTLR, third-row 6, delta 0x45c from restart
    0x1514: 0xEE110F10,  # mrc SCTLR, third-row 7, delta 0x460 from restart
    0x129C: 0xE1A00004,  # mov r0, r4, after cache_on returns
    0x1AE4: 0xE59FC098,  # ldr ip, [pc, #152], third-row 8, delta 0xa30
    0x19A0: 0xE3A00000,  # mov r0, #0, __enter_kernel, third-row 9, delta 0x8ec
    0x12B0: 0xE28F1078,  # add r1, pc, #120, after decompress, delta 0x1fc
    0x1B54: 0xEB00092D,  # bl do_decompress, delta 0xaa0
    0x1A90: 0xE59F3030,  # ldr r3, [pc, #48], error(), delta 0x9dc
    0x4010: 0xE92D47F0,  # push of do_decompress, delta 0x2f5c
    0x41B0: 0xE289300A,  # add r3, r9, #10 after gzip magic, delta 0x30fc
}
for off, want in expect.items():
    got = int.from_bytes(image[off:off + 4], "little")
    if got != want:
        raise SystemExit(f"zImage word at {off:#x} is {got:#x}, want {want:#x}")

blob = loader + bytes(pad - len(loader)) + image
# Same rule as find_dtb: last FDT magic in the zImage window whose
# big-endian totalsize is 64 bytes .. 1 MiB and fits in the window.
base = 0x80008000
end = 0x82008000
magic = 0xEDFE0DD0
region = blob[pad:]
last = None
off = 0
while off + 8 <= len(region) and base + off + 8 <= end:
    word = int.from_bytes(region[off:off + 4], "little")
    if word == magic:
        size = int.from_bytes(region[off + 4:off + 8], "big")
        addr = base + off
        if 0x40 <= size <= 0x100000 and addr + size <= end:
            last = (addr, size)
    off += 4
if last is None:
    raise SystemExit("loader scan would not find a DTB")
dtb_off = last[0] - base
if region[dtb_off:dtb_off + 4] != bytes.fromhex("d00dfeed"):
    raise SystemExit("chosen DTB has no magic")
# The appended tree is the tail of the image. The scan must select it,
# not a compressed-data collision earlier in the zImage.
if dtb_off + last[1] != len(region):
    raise SystemExit(
        f"scan chose {last[0]:#x} size {last[1]:#x}, which is not the appended tail"
    )
text = region[dtb_off:]
# The bootargs string: find it by its rdinit= setting.
idx = text.find(b"rdinit=")
# rdinit=/bin/busybox is the debug path: busybox runs an applet straight
# from the bootargs after "--", without /init.
if idx < 0 or not any(r in text[idx:idx + 320]
                      for r in (b"rdinit=/init ", b"rdinit=/bin/busybox ")):
    raise SystemExit("appended DTB bootargs have no rdinit=/init")
if b"root=/dev/ram0" in text[idx:idx + 240]:
    raise SystemExit("bootargs still name an empty ramdisk")
Path(sys.argv[3]).write_bytes(blob)
print(
    f"staging {len(blob)} bytes, loader {len(loader)}, "
    f"zImage at 0x80008000, dtb at {last[0]:#x} size {last[1]:#x}"
)
PY
ls -l "$OUT"
echo "ok: $OUT"
