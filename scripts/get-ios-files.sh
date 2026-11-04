#!/usr/bin/env bash
# Copy what the Linux side needs from this iPad's own iOS into ios-files/:
# the digitizer firmware, the panel's calibration and the Wi-Fi firmware
# and NVRAM. These are Apple's files and this panel's data, so they are
# not in the kit.
#
#   iproxy 2222 22 &      (iPad in jailbroken iOS, unlocked, OpenSSH installed)
#   CASCADIA=~/src/Project-Cascadia scripts/get-ios-files.sh
#
# The Wi-Fi MAC is not read here: put it in ios-files/wifi-mac by hand,
# from Settings > General > About > Wi-Fi Address (lower case, colons).
set -euo pipefail
source "$(dirname "$0")/common.sh"
source "$(dirname "$0")/ios-ssh.sh"
trap ios_close EXIT

[ -n "${CASCADIA:-}" ] || fail "set CASCADIA to a Project-Cascadia checkout"
MTCAL="$A5/tools/mtdump/prebuilt/mtcal"
[ -f "$MTCAL" ] || fail "no $MTCAL"
OUT="$ROOT/ios-files"
mkdir -p "$OUT"

echo "==> connecting (iOS root password, 'alpine' unless changed)"
model=$(ios uname -m) || fail "ssh to 127.0.0.1:$IOS_PORT failed (iproxy running? iPad unlocked? password?)"
build=$(ios sysctl -n kern.osversion)
[ "$model" = iPad3,1 ] || fail "this is a $model, not an iPad3,1"
[ "$build" = 13G36 ] || fail "iOS build is $build, not 13G36 (9.3.5)"
echo "    $model $build"

ios cat /usr/share/firmware/multitouch/J1.mtprops > "$OUT/J1.mtprops"
ios cat /usr/share/firmware/wifi/4330b2/mike.trx > "$OUT/mike.trx"
ios cat /usr/share/firmware/wifi/4330b2/mike.txt > "$OUT/mike.txt"

# The calibration is per panel: iBoot copies it out of syscfg (MtCl) into
# the device tree, and Cascadia's mtcal reads it back through IOKit.
ios_put "$MTCAL" /tmp/mtcal
ios /tmp/mtcal > "$OUT/mtcal.bin"
ios rm -f /tmp/mtcal
n=$(wc -c < "$OUT/mtcal.bin")
[ "$n" = 1024 ] || fail "calibration is $n bytes, want 1024"
od -An -tx1 "$OUT/mtcal.bin" | tr -d ' \n' | grep -q '[1-9a-f]' || fail "calibration is all zeros"

check J1.mtprops "$OUT/J1.mtprops"
check mike.trx "$OUT/mike.trx"
check mike.txt "$OUT/mike.txt"
[ -s "$OUT/wifi-mac" ] || echo "next: put the Wi-Fi MAC in ios-files/wifi-mac"
echo "ok: ios-files/"
