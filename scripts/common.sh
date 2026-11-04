# Sourced by the other scripts.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"
IMAGE="${IMAGE:-j1-kit-build}"

fail() { echo "error: $*" >&2; exit 1; }

# Cascadia keeps the A5 tree (the J1 included) under devices/a5.
A5="${CASCADIA:+$CASCADIA/devices/a5}"

# Run a command in the kit's container, with the kit at /work and, if set,
# Cascadia's A5 tree at /cascadia.
indocker() {
    docker image inspect "$IMAGE" >/dev/null 2>&1 \
        || fail "no docker image $IMAGE (docker build -t $IMAGE $ROOT/docker)"
    local vols=(-v "$ROOT:/work")
    [ -n "${CASCADIA:-}" ] && vols+=(-v "$A5:/cascadia")
    docker run --rm -i -u "$(id -u):$(id -g)" -e HOME=/tmp \
        "${vols[@]}" -w /work "$IMAGE" "$@"
}

# check NAME FILE: FILE's SHA-256 must be the one SHA256SUMS lists for NAME.
check() {
    local want got
    want=$(awk -v n="$1" '$2 == n { print $1 }' "$ROOT/SHA256SUMS")
    [ -n "$want" ] || fail "SHA256SUMS has no entry for $1"
    got=$(sha256sum "$2" | cut -d' ' -f1)
    [ "$got" = "$want" ] || fail "$1 is $got, want $want"
    echo "  sha256 ok  $1"
}
