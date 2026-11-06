#!/usr/bin/env bash
# Lay out build/initramfs: the kit's initramfs/ skeleton, a static busybox,
# the helper tools, Alpine's iw and wpa_supplicant, and the firmware taken
# from this iPad's own iOS (scripts/get-ios-files.sh). Does not talk to the
# iPad.
set -euo pipefail
source "$(dirname "$0")/common.sh"

BB_APK="busybox-static-1.37.0-r31.apk"
BB_URL="https://dl-cdn.alpinelinux.org/alpine/v3.24/main/armhf/$BB_APK"
IOS="$ROOT/ios-files"
OUT="$BUILD/initramfs"

[ -n "${CASCADIA:-}" ] || fail "set CASCADIA to a Project-Cascadia checkout"
for f in J1.mtprops mike.trx mike.txt mtcal.bin wifi-mac; do
    [ -s "$IOS/$f" ] || fail "no ios-files/$f (scripts/get-ios-files.sh)"
done
mac=$(tr -d ' \n' < "$IOS/wifi-mac")
echo "$mac" | grep -Eq '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' || fail "ios-files/wifi-mac is not aa:bb:cc:dd:ee:ff"

rm -rf "$OUT"
mkdir -p "$OUT" "$BUILD/dl"
cp -a "$ROOT/initramfs/." "$OUT/"
mkdir -p "$OUT"/{dev,proc,sys,tmp,root,var/log,lib/firmware/brcm}
ln -sf bin/busybox "$OUT/init"

if [ ! -f "$BUILD/dl/$BB_APK" ]; then
    curl -fsSL --retry 3 -o "$BUILD/dl/$BB_APK.partial" "$BB_URL"
    mv "$BUILD/dl/$BB_APK.partial" "$BUILD/dl/$BB_APK"
fi
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
tar -xzf "$BUILD/dl/$BB_APK" -C "$tmp" 2>/dev/null
cp "$tmp/bin/busybox.static" "$OUT/bin/busybox" 2>/dev/null || cp "$tmp/bin/busybox" "$OUT/bin/busybox"
chmod 755 "$OUT/bin/busybox"

echo "==> tools (static, armhf)"
indocker sh -c '
set -e
for t in z2-boot-j1 devmem i2creg; do
    arm-linux-gnueabihf-gcc -static -O2 -Wall -o build/initramfs/bin/$t tools/$t.c
done
'

echo "==> iw, wpa_supplicant"
indocker python3 scripts/fetch-wifi-userland.py

echo "==> firmware from this iPad"
cp "$IOS/J1.mtprops" "$OUT/lib/firmware/J1.mtprops"
cp "$IOS/mtcal.bin" "$OUT/lib/firmware/j1-mtcal.bin"
python3 "$A5/scripts/trx-add-nvram.py" "$IOS/mike.trx" "$IOS/mike.txt" \
    "$OUT/lib/firmware/brcm/brcmfmac4330.bin" "$mac"
# Bluetooth: the BCM4330's patchram, out of iOS's BlueTool ("Mike" is the
# J1's module, as in the Wi-Fi firmware's name). btbcm asks for this name.
if [ -s "$IOS/BlueTool" ]; then
    python3 "$A5/scripts/extract-bt-firmware.py" "$IOS/BlueTool" \
        "Olympic Mike Module" "$OUT/lib/firmware/brcm/BCM4330B1.hcd"
    check BCM4330B1.hcd "$OUT/lib/firmware/brcm/BCM4330B1.hcd"
else
    echo "    no ios-files/BlueTool: no Bluetooth firmware (scripts/get-ios-files.sh)"
fi
echo "ok: build/initramfs"
