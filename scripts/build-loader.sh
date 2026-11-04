#!/usr/bin/env bash
# Assemble the ARM loader that iBEC's `go` enters at 0x80000000.
set -euo pipefail
source "$(dirname "$0")/common.sh"

mkdir -p "$BUILD"
indocker sh -c '
set -e
arm-none-eabi-as -march=armv7-a -mcpu=cortex-a9 -o build/j1-boot.o loader/j1_boot.S
arm-none-eabi-ld -T loader/j1-linux-boot.ld --build-id=none -o build/j1-boot.elf build/j1-boot.o
arm-none-eabi-objcopy -O binary build/j1-boot.elf build/j1-boot.bin
'
check j1-boot.bin "$BUILD/j1-boot.bin"
echo "ok: build/j1-boot.bin"
