#!/usr/bin/env python3
"""Make iBoot-2817's `go` enter a raw ARM image at 0x80000000.

`go` (file 0x1170, Thumb) is not a raw jump. After the stack canary it:

  1. bounds-checks [0x80000000, 0x80000000+0x3f00000) via bl 0xbff1ebc8
  2. on failure, prints and returns -1          (beq at file 0x119c)
  3. on success, parses an IMG3/memory image    (bl 0xbff221f8)
  4. on parse success, prints "jumping into image at %p" and
     bl 0xbff1d89c with r0=0, r1=entry, r2=0

The jump helper quiesces the machine and blx's r1. An even entry is ARM.
A raw staging loader is not an image container, so step 3 fails and `go`
returns. irecovery -c go after a finished bulk upload therefore does nothing
useful until this edge is rewritten.

This replaces the eight bytes at file 0x119e (the start of step 3) with:

  mov.w r0, #0x80000000
  str   r0, [sp, #0x18]     # the entry slot the jump path already loads
  b     jump path           # file 0x11de, unchanged

The bounds-check failure return is left alone. The image parser is not
called. The jump helper's teardown (USB and the panel) is replaced with nops.
It still blx's 0x80000000. The loader must be ARM. Leaving the panel
scanning is how a paint in the loader can be seen.

This is not the mini's ep4 short-packet hook. In this iBEC the cmp #0x8000
cluster around 0xbff2cc00 is the NAND driver, and the three "set a flag and
return" helpers are task wakeups. Neither is a USB completion.

Does not talk to the device. A failed kDFU reboot drops the jailbreak.
"""

from __future__ import annotations

import argparse
import subprocess
import tempfile
from pathlib import Path

from capstone import CS_ARCH_ARM, CS_MODE_THUMB, Cs

LINK = 0xBFF00000
# First instruction of the IMG3 parser call. Only reached when the
# bounds check returned non-zero.
PATCH_OFF = 0x119E
PATCH_LEN = 8
# ldr r0,[pc,#0x70]; movs r3,#6; add r2,sp,#0x10; movs r1,#9
ORIG = bytes.fromhex("1c48062304aa0921")
JUMP_PATH = LINK + 0x11DE
JUMP_HELPER = 0xBFF1D89C
ENTRY = 0x80000000
FAIL_RETURN = LINK + 0x11C6
# Six calls inside the helper, from the first teardown bl through the
# last one. The cbz/blx that follows is left alone.
TEAR_OFF = 0x1D8B0
TEAR_LEN = 0x1C
TEAR_ORIG = bytes.fromhex(
    "fff70cff2046fef7adfe2046fef77efe17f09efa00f0defa02f020f8"
)
TEAR_NOP = b"\x00\xbf" * (TEAR_LEN // 2)


def assemble(at: int) -> bytes:
    # 0x80000000 is a Thumb modified immediate only as its bitwise
    # negation. b.n stays 16-bit; a plain b to an absolute symbol widens.
    asm = f"""\
.syntax unified
.cpu cortex-a9
.thumb
.equ jump_path, {JUMP_PATH}
.global rawgo
rawgo:
    mov.w r0, #-{ENTRY:#x}
    str r0, [sp, #0x18]
    b.n jump_path
"""
    ld = f"SECTIONS {{ . = {at:#x}; .text : {{ *(.text) }} }}\n"
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        (root / "p.S").write_text(asm)
        (root / "p.ld").write_text(ld)
        elf = root / "p.elf"
        subprocess.run(
            [
                "arm-none-eabi-gcc",
                "-nostdlib",
                "-mthumb",
                "-mcpu=cortex-a9",
                "-Wl,--build-id=none",
                "-T",
                str(root / "p.ld"),
                "-o",
                str(elf),
                str(root / "p.S"),
            ],
            check=True,
            capture_output=True,
        )
        raw = subprocess.run(
            ["arm-none-eabi-objcopy", "-O", "binary", "-j", ".text", str(elf), "/dev/stdout"],
            check=True,
            capture_output=True,
        ).stdout
    if len(raw) != PATCH_LEN:
        raise SystemExit(f"patch encoded to {len(raw)} bytes, wanted {PATCH_LEN}")
    return raw


def disasm(data: bytes, off: int, n: int) -> list:
    md = Cs(CS_ARCH_ARM, CS_MODE_THUMB)
    return list(md.disasm(data[off : off + n], LINK + off))


def verify(data: bytes) -> None:
    ins = disasm(data, PATCH_OFF, PATCH_LEN)
    text = [(i.mnemonic, i.op_str, i.address) for i in ins]
    if len(text) != 3:
        raise SystemExit(f"patch did not decode as 3 insns: {text}")
    if text[0][0] != "mov.w" or text[0][1] not in ("r0, #-0x80000000", "r0, #0x80000000"):
        raise SystemExit(f"entry load wrong: {text[0]}")
    if text[1] != ("str", "r0, [sp, #0x18]", LINK + PATCH_OFF + 4):
        raise SystemExit(f"entry store wrong: {text[1]}")
    if text[2][0] != "b" or f"#{JUMP_PATH:#x}" not in text[2][1]:
        raise SystemExit(f"branch wrong: {text[2]}")

    # Bounds-check failure must still return. beq at file 0x119c.
    beq = disasm(data, 0x119C, 2)
    if not beq or beq[0].mnemonic != "beq" or f"#{FAIL_RETURN:#x}" not in beq[0].op_str:
        raise SystemExit(f"bounds failure was disturbed: {beq}")

    # Jump path still loads the entry slot and calls the stock helper.
    # Linear disassembly from 0x11de stays in sync; stop at the helper call.
    path = disasm(data, 0x11DE, 0x30)
    saw_load = False
    saw_r0 = False
    saw_r2 = False
    helper = None
    for insn in path:
        if insn.mnemonic == "ldr" and insn.op_str == "r1, [sp, #0x18]":
            saw_load = True
        if insn.mnemonic == "movs" and insn.op_str == "r0, #0":
            saw_r0 = True
        if insn.mnemonic == "movs" and insn.op_str == "r2, #0":
            saw_r2 = True
        if insn.mnemonic == "bl" and f"#{JUMP_HELPER:#x}" in insn.op_str:
            helper = insn.address
            break
    if helper is None or not (saw_load and saw_r0 and saw_r2):
        raise SystemExit(
            "jump path lost the helper call "
            f"(load={saw_load} r0={saw_r0} r2={saw_r2} helper={helper})"
        )
    tear = disasm(data, TEAR_OFF, TEAR_LEN + 0x16)
    nops = [i for i in tear if i.address < LINK + TEAR_OFF + TEAR_LEN]
    if len(nops) != TEAR_LEN // 2 or any(i.mnemonic != "nop" for i in nops):
        raise SystemExit(f"teardown was not nop'd: {[(i.mnemonic, i.op_str) for i in nops]}")
    blx = [i for i in tear if i.mnemonic == "blx" and i.op_str == "r8"]
    if not blx:
        raise SystemExit("helper no longer blx r8")
    print("  raw go:")
    for mnemonic, op, addr in text:
        print(f"    {addr:#010x}  {mnemonic} {op}")
    print(f"    -> {JUMP_PATH:#010x} loads [sp,#0x18], bl {JUMP_HELPER:#x}")
    print(f"    helper teardown nop'd, blx r8 at {blx[0].address:#x}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("input", type=Path)
    ap.add_argument("output", nargs="?", type=Path)
    args = ap.parse_args()

    data = bytearray(args.input.read_bytes())
    if len(data) != 290816:
        raise SystemExit(f"unexpected iBEC length {len(data)}")
    if b"iBEC for j1" not in data or b"iBoot-2817.60.2" not in data:
        raise SystemExit("input is not the j1 iBoot-2817.60.2 iBEC")

    cur = bytes(data[PATCH_OFF : PATCH_OFF + PATCH_LEN])
    patch = assemble(LINK + PATCH_OFF)
    if cur != ORIG and cur != patch:
        raise SystemExit(
            f"unexpected bytes @ {PATCH_OFF:#x}: {cur.hex()} (expected {ORIG.hex()})"
        )
    data[PATCH_OFF : PATCH_OFF + PATCH_LEN] = patch
    tear = bytes(data[TEAR_OFF : TEAR_OFF + TEAR_LEN])
    if tear != TEAR_ORIG and tear != TEAR_NOP:
        raise SystemExit(
            f"unexpected teardown @ {TEAR_OFF:#x}: {tear.hex()}"
        )
    data[TEAR_OFF : TEAR_OFF + TEAR_LEN] = TEAR_NOP
    verify(data)
    if args.output is None:
        print("verified, no output written")
        return 0
    args.output.write_bytes(data)
    print(f"wrote {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
