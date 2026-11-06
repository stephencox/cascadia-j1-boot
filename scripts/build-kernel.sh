#!/usr/bin/env bash
# Build the J1 kernel from a Project-Cascadia checkout (main from aa6c5be
# on), embed build/initramfs, append dts/j1ap.dtb, and pack
# build/j1-staging.bin (loader, header, the kernel Image, DTB; see
# build-staging.sh). Does not talk to the iPad.
#
#   CASCADIA=~/src/Project-Cascadia scripts/build-kernel.sh
set -euo pipefail
source "$(dirname "$0")/common.sh"

[ -n "${CASCADIA:-}" ] || fail "set CASCADIA to a Project-Cascadia checkout"
C="$A5"
[ -f "$C/dts/j1ap.dts" ] || fail "$C has no dts/j1ap.dts: use current main (README)"
[ -f "$C/patches/files/arch/arm/mach-apple/j1_earlyfb.c" ] || fail "$C has no j1_earlyfb.c: PR #28 is not merged"
grep -q 'earlycon=j1fb' "$C/dts/j1ap.dts" || fail "j1ap.dts bootargs have no earlycon=j1fb"
[ -d "$BUILD/initramfs" ] || fail "no build/initramfs (scripts/build-initramfs.sh)"
[ -f "$BUILD/j1-boot.bin" ] || fail "no build/j1-boot.bin (scripts/build-loader.sh)"

TREE="$C/build/linux"
[ -f "$TREE/Makefile" ] || bash "$C/scripts/fetch-kernel.sh"
ver=$(awk -F' = ' '/^VERSION/{a=$2} /^PATCHLEVEL/{b=$2} /^SUBLEVEL/{c=$2} END{print a"."b"."c}' "$TREE/Makefile")
[ "$ver" = 6.12.0 ] || fail "kernel tree is $ver, want 6.12.0"

echo "==> Cascadia patches onto $TREE"
python3 "$C/scripts/apply-kernel-patches.py" --tree "$TREE" --files-only
bash "$C/scripts/apply-kernel-edits.sh" --tree "$TREE"
( cd "$C/patches/files-sandcastle-port" && find . -type f -print | while read -r f; do
    mkdir -p "$TREE/$(dirname "$f")"; cp "$f" "$TREE/$f"; done )

# The initramfs is the kit's, owned by whoever builds it.
cat "$ROOT/config/j1ap.config" > "$BUILD/j1ap.config"
cat >> "$BUILD/j1ap.config" <<CFG
CONFIG_INITRAMFS_SOURCE="/work/build/initramfs /work/initramfs.list"
CONFIG_INITRAMFS_ROOT_UID=$(id -u)
CONFIG_INITRAMFS_ROOT_GID=$(id -g)
CFG

mkdir -p "$BUILD/logs"
echo "==> compile (log: build/logs/kernel.log)"
indocker bash -s > "$BUILD/logs/kernel.log" 2>&1 <<'SH' || { tail -30 "$BUILD/logs/kernel.log"; fail "kernel build failed"; }
set -euo pipefail
T=/cascadia/build/linux
make -C $T multi_v7_defconfig
$T/scripts/kconfig/merge_config.sh -m -O $T $T/.config /work/build/j1ap.config
make -C $T olddefconfig
for s in CONFIG_ARCH_APPLE_S5L CONFIG_SERIAL_EARLYCON CONFIG_USB_CDC_COMPOSITE CONFIG_TOUCHSCREEN_APPLE_Z2 CONFIG_BRCMFMAC_USB CONFIG_BATTERY_APPLE_HDQ CONFIG_BACKLIGHT_APPLE_PMU_WLED CONFIG_HOTPLUG_CPU CONFIG_FRAMEBUFFER_CONSOLE_ROTATION CONFIG_FONT_TER16x32 CONFIG_SND_SOC_APPLE_S5L_AUDIO CONFIG_SND_SOC_CS42L63; do
    grep -q "^$s=y" $T/.config || { echo "config: $s is not =y"; exit 1; }
done
make -C $T -j"$(nproc)" Image
dtc -I dts -O dtb -o /work/build/j1ap.dtb /cascadia/dts/j1ap.dts
SH

cp "$TREE/arch/arm/boot/Image" "$BUILD/j1-Image"
bash "$ROOT/scripts/build-staging.sh"
