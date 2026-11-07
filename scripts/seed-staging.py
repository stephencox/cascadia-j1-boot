#!/usr/bin/env python3
"""seed-staging.py STAGING OUT: copy a j1-staging.bin with a fresh RNG seed.

The J1 has no hardware RNG that Linux can use, so without a seed its CRNG
is ready only after a minute or more (or once touch input has been fed in).
iOS gets a 64-byte /chosen/random-seed from iBoot at each boot; this gives
Linux the same thing, as /chosen/rng-seed. The kernel credits it
(random.trust_bootloader, on by default) and wipes it from the tree.

The seed goes into a copy that is uploaded and then deleted: the staging
file on disk never has one, so no seed is used twice. Layout as
build-staging.sh writes it: [loader][pad][16-byte J1IM header at PAD-16]
[Image][pad to 8][DTB], with the DTB last.
"""
import os
import struct
import sys

PAD = 0x8000
SEED_LEN = 64
GO_END = 0x83F00000            # iBEC's go window, as in build-staging.sh

FDT_MAGIC = 0xD00DFEED
FDT_BEGIN_NODE, FDT_END_NODE, FDT_PROP, FDT_NOP, FDT_END = 1, 2, 3, 4, 9


def align4(n):
    return (n + 3) & ~3


def add_chosen_prop(dtb, name, value):
    """Return dtb with property NAME = VALUE added to /chosen."""
    (magic, _total, off_struct, off_strings, off_rsv, version, last_comp,
     cpuid, size_strings, size_struct) = struct.unpack_from(">10I", dtb, 0)
    if magic != FDT_MAGIC:
        raise SystemExit("DTB has no FDT magic")
    if version < 17:
        raise SystemExit(f"FDT version {version}, want 17")
    if not off_rsv < off_struct < off_strings:
        raise SystemExit("unexpected FDT block order")
    st = bytearray(dtb[off_struct:off_struct + size_struct])
    strings = bytes(dtb[off_strings:off_strings + size_strings])

    # Walk the structure block for the root's child "chosen".
    pos, depth, insert_at = 0, 0, None
    while pos < len(st):
        tok = struct.unpack_from(">I", st, pos)[0]
        pos += 4
        if tok == FDT_BEGIN_NODE:
            end = st.index(0, pos)
            node = st[pos:end].decode()
            pos = align4(end + 1)
            depth += 1
            if depth == 2 and node == "chosen":
                insert_at = pos
        elif tok == FDT_END_NODE:
            depth -= 1
        elif tok == FDT_PROP:
            plen, nameoff = struct.unpack_from(">II", st, pos)
            pos += 8
            pname = strings[nameoff:strings.index(b"\0", nameoff)].decode()
            if depth == 2 and insert_at is not None and pname == name:
                raise SystemExit(f"/chosen already has {name}: the DTB should not")
            pos = align4(pos + plen)
        elif tok == FDT_NOP:
            pass
        elif tok == FDT_END:
            break
        else:
            raise SystemExit(f"bad FDT token {tok:#x}")
        if insert_at is not None and depth < 2:
            break
    if insert_at is None:
        raise SystemExit("DTB has no /chosen")

    nameoff = len(strings)
    strings += name.encode() + b"\0"
    prop = struct.pack(">III", FDT_PROP, len(value), nameoff) + value
    prop += bytes(align4(len(prop)) - len(prop))
    st[insert_at:insert_at] = prop

    head = bytearray(dtb[:off_struct])     # header + memory reservation map
    out = head + st + strings
    struct.pack_into(">10I", out, 0, magic, len(out), off_struct,
                     off_struct + len(st), off_rsv, version, last_comp, cpuid,
                     len(strings), len(st))
    return bytes(out)


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__.splitlines()[0])
    blob = open(sys.argv[1], "rb").read()
    hdr = PAD - 16
    if blob[hdr:hdr + 4] != b"J1IM":
        raise SystemExit("no J1IM header: not a j1-staging.bin")
    dtb_off, dtb_len = struct.unpack_from("<II", blob, hdr + 4)
    start = PAD + dtb_off
    if start + dtb_len != len(blob):
        raise SystemExit("the DTB is not the last thing in the staging")
    dtb = add_chosen_prop(blob[start:], "rng-seed", os.urandom(SEED_LEN))
    if 0x80008000 + dtb_off + len(dtb) > GO_END:
        raise SystemExit("seeded staging runs past iBEC's go window")
    out = bytearray(blob[:start]) + dtb
    struct.pack_into("<I", out, hdr + 8, len(dtb))
    fd = os.open(sys.argv[2], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(out)


if __name__ == "__main__":
    main()
