#!/usr/bin/env bash
# Decrypt the iPad3,1 13G36 iBSS and iBEC from the IPSW and patch them.
# Every input and output is checked against SHA256SUMS. Does not talk to
# the iPad.
#
#   CASCADIA=~/src/Project-Cascadia scripts/build-bootchain.sh
#
# Wants firmware/iPad3,1_9.3.5_13G36_Restore.ipsw (from Apple, e.g. via
# ipsw.me). Produces:
#   build/iBSS.j1.patched           what kloader starts (signature checks off)
#   build/iBEC.j1.rawgo.plain.dfu   what iBSS loads over USB; its `go` enters
#                                   a raw ARM image at 0x80000000
set -euo pipefail
source "$(dirname "$0")/common.sh"

IPSW="${IPSW:-$ROOT/firmware/iPad3,1_9.3.5_13G36_Restore.ipsw}"
PATCHER_URL=https://github.com/iH8sn0w/iBoot32Patcher
PATCHER_REV=77ab155cb418d67f688e2e85f3e83c77a2431660

# Public keys, The Apple Wiki: Keys:Genoa 13G36 (iPad3,1).
IBSS_IV="7ced82eb8778ca7547610a10414463db"
IBSS_KEY="f18b2d640ac277c41ffd1c611cca7af7f2fc87932980d737cb1701b1c7ff9162"
IBEC_IV="578ef2d32e6a31b68c696d1343592a94"
IBEC_KEY="c35d7184d6b1c5cfc3eb3dc7a74c125b36419c529a69fd6114418d3bad1dc9c9"

[ -n "${CASCADIA:-}" ] || fail "set CASCADIA to a Project-Cascadia checkout"
[ -f "$A5/scripts/img3decrypt.py" ] || fail "no Cascadia A5 tree at $A5"
[ -f "$IPSW" ] || fail "no IPSW at $IPSW"
check iPad3,1_9.3.5_13G36_Restore.ipsw "$IPSW"

mkdir -p "$BUILD/fw"
unzip -o -j "$IPSW" Firmware/dfu/iBSS.j1.RELEASE.dfu Firmware/dfu/iBEC.j1.RELEASE.dfu \
    -d "$BUILD/fw" >/dev/null
check iBSS.j1.RELEASE.dfu "$BUILD/fw/iBSS.j1.RELEASE.dfu"
check iBEC.j1.RELEASE.dfu "$BUILD/fw/iBEC.j1.RELEASE.dfu"

if [ ! -x "$BUILD/iBoot32Patcher/iBoot32Patcher" ]; then
    echo "==> iBoot32Patcher $PATCHER_REV"
    rm -rf "$BUILD/iBoot32Patcher"
    git clone -q "$PATCHER_URL" "$BUILD/iBoot32Patcher"
    git -C "$BUILD/iBoot32Patcher" checkout -q "$PATCHER_REV"
    indocker sh -c 'cd build/iBoot32Patcher && gcc -O2 -w -Wno-multichar -I. -o iBoot32Patcher iBoot32Patcher.c finders.c functions.c patchers.c'
fi

echo "==> decrypt"
indocker python3 /cascadia/scripts/img3decrypt.py build/fw/iBSS.j1.RELEASE.dfu build/fw/iBSS.j1.dec "$IBSS_IV" "$IBSS_KEY"
indocker python3 /cascadia/scripts/img3decrypt.py build/fw/iBEC.j1.RELEASE.dfu build/fw/iBEC.j1.dec "$IBEC_IV" "$IBEC_KEY"
check iBSS.j1.dec "$BUILD/fw/iBSS.j1.dec"
check iBEC.j1.dec "$BUILD/fw/iBEC.j1.dec"

echo "==> signature patch (iBoot32Patcher finds verify_shsh: iBSS 0x66fe, iBEC 0x1a08c)"
indocker build/iBoot32Patcher/iBoot32Patcher build/fw/iBSS.j1.dec build/iBSS.j1.patched -b "cs_enforcement_disable=1 debug=0x14"
indocker build/iBoot32Patcher/iBoot32Patcher build/fw/iBEC.j1.dec build/fw/iBEC.j1.patched -b "cs_enforcement_disable=1 debug=0x14"
check iBSS.j1.patched "$BUILD/iBSS.j1.patched"
check iBEC.j1.patched "$BUILD/fw/iBEC.j1.patched"

echo "==> iBSS load site (left as is: it has to keep waiting on USB)"
indocker python3 scripts/ibss-sites.py build/iBSS.j1.patched

echo "==> raw go (iBEC file 0x119e, and the jump helper's teardown)"
indocker python3 scripts/patch-ibec-rawgo.py build/fw/iBEC.j1.patched build/fw/iBEC.j1.rawgo
check iBEC.j1.rawgo "$BUILD/fw/iBEC.j1.rawgo"

echo "==> plaintext IMG3, no KBAG"
indocker python3 /cascadia/scripts/img3pack.py build/fw/iBEC.j1.RELEASE.dfu build/fw/iBEC.j1.rawgo build/iBEC.j1.rawgo.plain.dfu
check iBEC.j1.rawgo.plain.dfu "$BUILD/iBEC.j1.rawgo.plain.dfu"

echo "ok: build/iBSS.j1.patched"
echo "ok: build/iBEC.j1.rawgo.plain.dfu"
