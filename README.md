# J1 boot kit: Project Cascadia on the iPad 3 (iPad3,1)

This kit boots Linux 6.12 from RAM on an iPad 3 Wi-Fi (iPad3,1, board
J1AP, A5X) with Project Cascadia (PRs #25-#28, merged 2026-11-03). iOS 9.3.5
stays on the NAND and starts it, and nothing is written to the flash.

The kit has scripts and sources only. It has no Apple firmware, keys or
binaries. Everything Apple's is rebuilt from the IPSW or copied from your
own iPad, and checked against `SHA256SUMS`.

On my iPad3,1 this boot comes up as the USB gadget about 4 s after `go`.
Touch then works as `/dev/input/event0`, and Wi-Fi scans 2.4 and 5 GHz and
joins WPA2. One board has been tested so far.

## What you need

- An iPad3,1 (A1416) on iOS 9.3.5 (13G36). Jailbreak it (EverPwnage works)
  and install OpenSSH from Cydia.
- A Linux host with Docker, git, python3, `usbmuxd` and `iproxy`
  (libusbmuxd), and `irecovery` (libirecovery 1.2 or later). Install
  `picocom` or similar for the shell, and connect a 30-pin USB cable.
- The IPSW, `iPad3,1_9.3.5_13G36_Restore.ipsw` (SHA-256 `ceec5670...5c95`,
  for example from ipsw.me), in `firmware/`, or point `IPSW=` at it.
- A Project Cascadia checkout, main from `aa6c5be` (2026-11-04) on, which
  keeps the A5 tree under `devices/a5`:

  ```sh
  git clone https://github.com/rzxvx/Project-Cascadia && cd Project-Cascadia
  export CASCADIA=$PWD
  ```

## Build

```sh
docker build -t j1-kit-build docker
scripts/build-bootchain.sh     # iBSS and iBEC from the IPSW, every step hashed
scripts/build-loader.sh        # the ARM loader at 0x80000000
iproxy 2222 22 &               # iPad in iOS, unlocked
scripts/get-ios-files.sh       # touch and Wi-Fi firmware, panel calibration
echo aa:bb:cc:dd:ee:ff > ios-files/wifi-mac   # Settings > General > About > Wi-Fi Address
scripts/build-initramfs.sh
scripts/build-kernel.sh        # clones Linux v6.12 into $CASCADIA/devices/a5/build/linux if needed
```

Use the Docker toolchain for the kernel (GCC 11.4, Ubuntu 22.04). The
loader patches the zImage decompressor at fixed offsets (below), and
`build-staging.sh` refuses a zImage whose words there differ, which is
what a different compiler produces.

## Boot

```sh
iproxy 2222 22 &
scripts/boot.sh
```

1. kloader starts the patched iBSS, and the screen goes dark. **Tap the
   top button once. Do not hold it.** iBSS then shows up as DFU
   (`05ac:1227`).
2. The script sends iBEC (Recovery, `05ac:1281`), then
   `setenv loadaddr 0x80000000`, the staging image and `go`.
3. Linux appears as `0525:a4aa`. Its root shell is on `/dev/ttyACM0`
   (`picocom /dev/ttyACM0`), and the kernel log is on the panel.

   `/dev/ttyACM0` belongs to `dialout` (Debian, Ubuntu) or `uucp` (Arch,
   Fedora): be in that group, or open it with sudo.

On the iPad:

```sh
dmesg | grep -iE 'z2|hx-touch'          # touch: z2-boot-j1 runs at boot, log /var/log/touch.log
cat /dev/input/event0 | od | head       # touch the glass
wifi-up 'SSID' 'passphrase'             # powers the BCM4330, joins WPA2, DHCP
cat /var/log/charge.log                 # input-current limit raised (below)
```

To go back to iOS, hold the top button and home until the Apple logo
appears. A kernel panic also reboots after 10 s (`panic=10`). In both cases
iOS boots normally. The kloader step needs the jailbreak active, so after a
reboot run EverPwnage again before the next try.

### Battery

iBEC leaves the D1974's input-current limit (PMU `0x3e`) at about 100 mA,
and the battery drains under Linux. `/bin/charge-up` raises it to 1000 mA
(`0x4a`) at boot. On my iPad that turned about -190 mA into about +210 mA
at idle. It writes that one register and nothing else. Charge in iOS
before a long session anyway: a flat battery fails the boot right after
`go`, and that looks exactly like a kernel hang.

### If it does not boot

- **No DFU after the tap:** run `scripts/boot.sh` again. If kloader killed
  iOS without starting iBSS, rerun EverPwnage first.
- **`go` and then nothing, blank screen, backlight on:** check the battery
  first. If the battery is fine, check that `earlycon=j1fb` is still in
  `dts/j1ap.dts`'s bootargs. Without it the kernel stops in early boot on
  this board, and why is not known yet.
- **The boot log on the panel stops:** a photo of the last lines is the
  most useful report.

## How the boot works

- **iBSS** (`build/iBSS.j1.patched`) is the 13G36 iBSS decrypted with the
  public Genoa keys. iBoot32Patcher (iH8sn0w, commit `77ab155`) patches its
  signature check (`verify_shsh` at file `0x66fe`). It still waits on USB
  for iBEC at `0x9fe00000` (`scripts/ibss-sites.py` checks that site).
  kloader (Legacy-iOS-Kit's armv7 build of axi0mX's ios-kexec-utils
  kloader, pinned by commit and hash in `scripts/boot.sh`) starts it from
  iOS.
- **iBEC** (`build/iBEC.j1.rawgo.plain.dfu`) is decrypted and
  signature-patched the same way (`0x1a08c`). Then
  `scripts/patch-ibec-rawgo.py` changes two places:
  - **File `0x119e`, 8 bytes.** iBoot-2817's `go` bounds-checks
    `[0x80000000, 0x83f00000)`, parses an IMG3 there, and only then calls
    its jump helper. The parser call becomes `mov.w r0, #0x80000000;
    str r0, [sp, #0x18]; b 0xbff011de`, so `go` enters a raw ARM image at
    `0x80000000`.
  - **File `0x1d8b0`, 28 bytes.** These are the jump helper's teardown
    calls before its `blx`, which take USB and the panel down. They become
    NOPs, so iBoot's scanout is still live for the kernel's early console.
    The kernel brings up its own USB gadget.

  The result is packed as a plaintext IMG3 with no KBAG (Cascadia's
  `img3pack.py`).
- **Loader** (`loader/j1_boot.S`, ARM, 2032 bytes at `0x80000000`).
  - It stops the watchdog through iBoot's mapping (`0x0f103020`; the
    physical `0x3f103020` is wrong while iBoot's MMU is on).
  - It finds the DTB appended to the zImage, cleans L1 and the PL310, turns
    the MMU and caches off, and enters the zImage at `0x80008000`.
  - It also plants four hooks in the relocated decompressor:
    - **`cache_on`:** M and C are cleared from its SCTLR write.
    - **`decompress_kernel` entry:** the DTB is copied to `0x84000000`.
    - **`do_decompress`:** DRAM is identity-mapped and the caches turned
      on, with L1 and L2 cleaned first.
    - **After decompression:** L1 and L2 are cleaned, and the MMU and
      caches are turned off before `__enter_kernel`.

  Without them the decompressor did not get through on this board. The
  hook sites are offsets in the decompressor, which is why the compiler is
  pinned.
- **Kernel:** Cascadia's tree and `config/j1ap.config` on
  `multi_v7_defconfig`. The bootargs come from `dts/j1ap.dts`:
  `earlycon=j1fb console=ttyGS0,115200 maxcpus=1`. The DTB is appended to
  the zImage.
- **Initramfs:**
  - a static busybox (Alpine 3.24), which is `/init`;
  - `z2-boot-j1`, which boots the digitizer and hands it to Cascadia's Z2
    driver;
  - `usb1-up`, which brings up the second USB complex's HSIC PHY by hand,
    then REG_ON (no PHY driver yet);
  - Alpine's `iw` and `wpa_supplicant`;
  - `devmem` and `i2creg`.

Cascadia's `docs/research/j1-a5x.md` (PR #28) has the measurements: PMGR,
PMU, touch and Wi-Fi.

## Layout

| path | what |
|---|---|
| `SHA256SUMS` | IPSW, every bootchain stage, loader, kloader, the iOS files |
| `scripts/build-bootchain.sh` | IPSW to `build/iBSS.j1.patched`, `build/iBEC.j1.rawgo.plain.dfu` |
| `scripts/patch-ibec-rawgo.py` | the raw-go patch, checked with capstone before and after |
| `scripts/ibss-sites.py` | checks iBSS's USB load site |
| `scripts/build-loader.sh`, `loader/` | the loader and its linker script |
| `scripts/get-ios-files.sh` | `J1.mtprops`, `mike.trx`/`mike.txt`, the panel calibration (Cascadia's `mtcal`) |
| `scripts/build-initramfs.sh`, `initramfs/`, `tools/` | the userland |
| `scripts/build-kernel.sh`, `config/`, `scripts/build-staging.sh` | the kernel and `build/j1-staging.bin` |
| `scripts/boot.sh` | kloader, DFU, iBEC, staging, `go` |
| `docker/Dockerfile` | the toolchain |

## Not done

- **CPU1:** the kernel runs with `maxcpus=1`.
- **Display:** there is no GPU or display driver; the panel shows iBoot's
  framebuffer.
- **Missing drivers:** there are no drivers for the backlight, audio or
  Bluetooth, and no PHY driver for the Wi-Fi's USB complex.
- **NAND:** writes are not supported.
- **Early fault:** the fault that `earlycon=j1fb` hides is not found.

GPL-2.0, as Project Cascadia.
