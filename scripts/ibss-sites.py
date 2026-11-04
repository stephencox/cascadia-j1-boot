#!/usr/bin/env python3
"""Locate the J1 iOS 9.3.5 iBSS image-load sites.

iBoot-2817.60.2's iBSS has no "iBSS ready" string, so Cascadia's
patch-ibss-a5.py cannot anchor. The init function is the same shape.
Sites below were taken from a linear Thumb disassembly of
firmware/plain/iBSS.j1.dec (link address 0x34000000):

  0x962  movs r0, #1          wipe flag into memclr (2 MiB at the load address)
  0x964  bl   memclr
  0x968  ldr  r0, [pc, #0x94] -> pool 0xa00 = 0x9FE00000
  0x96a  mov.w r1, #0x200000  buffer length
  0x974  bl   usb_wait_for_image
  0x978  mov  r5, r0
  0x97a  cmp  r5, #0
  0x97c  blt  0x962           retry

The signature-patched iBSS used for kDFU must keep the USB wait. Changing
the pool word is only for a kloader that has already copied iBEC to
0xBFD00000. iBEC then relocates itself to its link address, 0xBFF00000.
"""

from __future__ import annotations

import argparse
import struct
import subprocess
import tempfile
from pathlib import Path

from capstone import CS_ARCH_ARM, CS_MODE_THUMB, Cs

LINK = 0x34000000
LOAD_POOL = 0xA00
STOCK_LOAD = 0x9FE00000
KLOADER_LOAD = 0xBFD00000
WIPE_MOV = 0x962
USB_WAIT = 0x974
RETRY = 0x97C
MAXLEN = 0x200000


def expect(data: bytes, off: int, mnemonic: str, op_substr: str) -> str:
    md = Cs(CS_ARCH_ARM, CS_MODE_THUMB)
    insns = list(md.disasm(data[off : off + 4], LINK + off))
    if not insns:
        raise SystemExit(f"no instruction at {off:#x}")
    ins = insns[0]
    if ins.mnemonic != mnemonic or op_substr not in ins.op_str:
        raise SystemExit(
            f"site {off:#x} is {ins.mnemonic} {ins.op_str}, "
            f"expected {mnemonic} {op_substr}"
        )
    return f"{ins.address:#x}  {ins.mnemonic} {ins.op_str}"


def movw_r0(value: int) -> bytes:
    """4-byte Thumb mov.w r0, #value. The 2 MiB length fits a modified immediate."""
    asm = f".syntax unified\n.thumb\nmov.w r0, #{value}\n"
    with tempfile.TemporaryDirectory() as td:
        src = Path(td) / "x.S"
        obj = Path(td) / "x.o"
        src.write_text(asm)
        subprocess.run(
            ["arm-none-eabi-as", "-mthumb", "-o", str(obj), str(src)],
            check=True,
            capture_output=True,
        )
        raw = subprocess.run(
            ["arm-none-eabi-objcopy", "-O", "binary", "-j", ".text", str(obj), "/dev/stdout"],
            check=True,
            capture_output=True,
        ).stdout
    if len(raw) != 4:
        raise SystemExit(f"mov.w encoded to {len(raw)} bytes, wanted 4")
    return raw


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("input", type=Path)
    ap.add_argument("output", nargs="?", type=Path)
    ap.add_argument("--kloader", action="store_true",
                    help="retarget the preplaced-iBEC path (not the USB kDFU iBSS)")
    args = ap.parse_args()

    data = bytearray(args.input.read_bytes())
    if len(data) != 81920:
        raise SystemExit(f"unexpected iBSS length {len(data)}")

    load = struct.unpack_from("<I", data, LOAD_POOL)[0]
    print(f"link          {LINK:#x}")
    print(f"load pool     {LOAD_POOL:#x} = {load:#x}")
    print("wipe          " + expect(data, WIPE_MOV, "movs", "r0, #1"))
    print("usb_wait      " + expect(data, USB_WAIT, "bl", "#"))
    print("retry         " + expect(data, RETRY, "blt", "#"))
    if load not in (STOCK_LOAD, KLOADER_LOAD):
        raise SystemExit(f"load address {load:#x} is neither stock nor kloader")

    if not args.kloader:
        print("usb kDFU iBSS left unchanged (USB wait stays)")
        return 0

    if args.output is None:
        raise SystemExit("--kloader needs an output path")

    struct.pack_into("<I", data, LOAD_POOL, KLOADER_LOAD)
    if data[WIPE_MOV : WIPE_MOV + 2] != bytes.fromhex("0120"):
        raise SystemExit("wipe site is not movs r0, #1")
    data[WIPE_MOV : WIPE_MOV + 2] = bytes.fromhex("0020")
    data[USB_WAIT : USB_WAIT + 4] = movw_r0(MAXLEN)
    data[RETRY : RETRY + 2] = bytes.fromhex("00bf")

    print(f"load address  {STOCK_LOAD:#x} -> {KLOADER_LOAD:#x}")
    print("wipe          movs r0, #1 -> movs r0, #0")
    print(f"usb_wait      bl -> mov.w r0, #{MAXLEN:#x}")
    print("retry         blt -> nop")
    print("execute path  cmp/mov r5 left in place")
    args.output.write_bytes(data)
    print(f"wrote {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
