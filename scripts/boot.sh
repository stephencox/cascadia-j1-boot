#!/usr/bin/env bash
# Start Linux from the iPad's jailbroken iOS. Nothing is written to the
# NAND: Linux runs from RAM, and holding power + home goes back to iOS.
#
#   iproxy 2222 22 &
#   scripts/boot.sh
#
# 1. copies kloader and the patched iBSS to iOS and runs kloader;
# 2. the iPad goes dark: tap the top button ONCE (do not hold it), and the
#    patched iBSS comes up as DFU (05ac:1227);
# 3. sends the raw-go iBEC, waits for Recovery (05ac:1281), sets loadaddr,
#    uploads build/j1-staging.bin and sends `go`. The upload is a copy with
#    a fresh /chosen/rng-seed (seed-staging.py), as iBoot gives iOS one.
# Linux's gadget is 0525:a4aa, about 4 s later. Its shell is on
# /dev/ttyACM0. If the iPad is already in DFU, this starts at step 3; if
# this iBEC is already up (Recovery), at the upload.
#
# Set J1_ECID=0x... to refuse any other iPad (irecovery -q prints it).
set -euo pipefail
source "$(dirname "$0")/common.sh"
source "$(dirname "$0")/ios-ssh.sh"
SEEDED=
cleanup() { ios_close; [ -z "$SEEDED" ] || rm -f "$SEEDED"; }
trap cleanup EXIT

IREC="${IRECOVERY:-irecovery}"
KLOADER_URL=https://raw.githubusercontent.com/LukeZGD/Legacy-iOS-Kit/e46f0bd52246630d7a1e1bc8c795c6a86b9025a5/resources/kloader/kloader
IBSS="$BUILD/iBSS.j1.patched"
IBEC="$BUILD/iBEC.j1.rawgo.plain.dfu"
STAGING="$BUILD/j1-staging.bin"

command -v "$IREC" >/dev/null || fail "no irecovery (libirecovery 1.2 or later; IRECOVERY=/path/to/irecovery)"
for f in "$IBSS" "$IBEC" "$STAGING"; do [ -f "$f" ] || fail "no $f"; done
check iBSS.j1.patched "$IBSS"
check iBEC.j1.rawgo.plain.dfu "$IBEC"

field() { printf '%s\n' "$1" | awk -F: -v k="$2" '$1 == k { gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit }'; }
mode_is() {
    local q; q=$("$IREC" -q 2>/dev/null) || return 1
    [ "$(field "$q" MODE)" = "$1" ] && [ "$(field "$q" CPID)" = 0x8945 ] || return 1
    [ -z "${J1_ECID:-}" ] || [ "$(field "$q" ECID)" = "$J1_ECID" ]
}
wait_mode() {
    local i
    for i in $(seq 1 "$2"); do mode_is "$1" && return 0; sleep 1; done
    return 1
}

shell_check() {
    # The gadget can enumerate with its serial port dead (the host logs
    # "device descriptor read/64, error -71" first, and the shell never
    # answers) while Linux itself runs fine. Ask the shell for 6*7.
    set +e
    tty=$(timeout 25 python3 -I - <<'PY'
import glob, os, select, sys, termios, time
end = time.time() + 20
dev = None
while time.time() < end and not dev:
    for d in glob.glob("/sys/bus/usb/devices/*"):
        try:
            if open(d + "/idVendor").read().strip() == "0525" and \
               open(d + "/idProduct").read().strip() == "a4aa":
                t = glob.glob(d + "/*/tty/ttyACM*")
                if t:
                    dev = "/dev/" + os.path.basename(t[0])
        except OSError:
            pass
    time.sleep(0.5)
if not dev:
    print("none"); sys.exit(2)
try:
    fd = os.open(dev, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
except PermissionError:
    print(dev); sys.exit(3)
a = termios.tcgetattr(fd); a[0] = 0; a[1] = 0; a[3] = 0
a[2] |= termios.CLOCAL | termios.CREAD
termios.tcsetattr(fd, termios.TCSANOW, a)
out = b""
while time.time() < end and b"J1-42" not in out:
    try:
        os.write(fd, b"\necho J1-$((6*7))\n")
    except BlockingIOError:
        pass
    t = time.time() + 2
    while time.time() < t:
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            out += os.read(fd, 4096)
print(dev)
sys.exit(0 if b"J1-42" in out else 1)
PY
    )
    rc=$?
    set -e
    case $rc in
    0) echo "$(date +%T) shell answers on $tty: picocom $tty" ;;
    3) echo "$(date +%T) $tty is there but this user cannot open it (README: serial group)" ;;
    *) echo "$(date +%T) the shell on ${tty:-the ACM port} does not answer."
       echo "         Unplug the cable and plug it back in: the serial link sometimes"
       echo "         comes up dead while Linux runs fine." ;;
    esac
}

if lsusb -d 0525:a4aa >/dev/null 2>&1; then
    echo "Linux is already up on USB."
    shell_check
    exit 0
fi

if mode_is Recovery; then
    echo "Recovery already: assuming it is this iBEC"
elif ! mode_is DFU; then
    mkdir -p "$BUILD/dl"
    [ -f "$BUILD/dl/kloader" ] || curl -fsSL -o "$BUILD/dl/kloader" "$KLOADER_URL"
    check kloader "$BUILD/dl/kloader"
    echo "==> iOS (root password, 'alpine' unless changed)"
    model=$(ios uname -m) || fail "ssh to 127.0.0.1:$IOS_PORT failed (iproxy running? iPad unlocked? password?)"
    [ "$model" = iPad3,1 ] || fail "this is a $model, not an iPad3,1"
    ios_put "$BUILD/dl/kloader" /tmp/kloader
    ios_put "$IBSS" /tmp/pwnediBSS
    echo "$(date +%T) kloader"
    ios '/tmp/kloader /tmp/pwnediBSS' || true
    ios_close
    echo "$(date +%T) tap the top button once. Do not hold it."
    wait_mode DFU 180 || fail "no DFU. Tap the top button once, then run this again."
fi

if mode_is DFU; then
    echo "$(date +%T) iBEC"
    "$IREC" -f "$IBEC"
    wait_mode Recovery 30 || fail "iBEC did not come up as Recovery"
fi
echo "$(date +%T) staging"
SEEDED=$(mktemp "${TMPDIR:-/tmp}/j1-staging.XXXXXX")
python3 -I "$ROOT/scripts/seed-staging.py" "$STAGING" "$SEEDED"
"$IREC" -c "setenv auto-boot false"
"$IREC" -c "setenv loadaddr 0x80000000"
"$IREC" -f "$SEEDED"
rm -f "$SEEDED"
echo "$(date +%T) go"
"$IREC" -c go || true
for i in $(seq 1 30); do
    lsusb -d 0525:a4aa >/dev/null 2>&1 && break
    sleep 1
done
lsusb -d 0525:a4aa >/dev/null 2>&1 || fail "no 0525:a4aa after 30 s (README: if it does not boot)"
echo "$(date +%T) Linux is up (0525:a4aa)"
shell_check
