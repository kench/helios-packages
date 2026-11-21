#!/bin/sh
# Builds the helios-srtla-send Debian package: irlserver srtla_send at the pinned upstream commit,
# cross-compiled for arm64 against glibc $GLIBC with cargo zigbuild, as /usr/bin/srtla_send.
#
# Usage: helios-srtla-send/build.sh [OUT_DIR]   (default: out/)
# Needs: git, rustup (upstream pins its toolchain), cargo-zigbuild and zig 0.14.1, readelf,
# dpkg-deb. Sources go in src/ and the staged tree in build/ (both ignored by git).
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/.." && pwd)
# shellcheck source=helios-srtla-send/package.env
. "$HERE/package.env"
OUT=${1:-$TOP/out}
SRC=$TOP/src/$NAME
STAGE=$TOP/build/$NAME

echo "== $NAME $VERSION: $UPSTREAM_REPO $UPSTREAM_TAG"
rm -rf "$SRC" "$STAGE"
mkdir -p "$TOP/src" "$OUT"
git clone --quiet --depth 1 --branch "$UPSTREAM_TAG" "$UPSTREAM_REPO" "$SRC"
commit=$(git -C "$SRC" rev-parse HEAD)
if [ "$commit" != "$UPSTREAM_COMMIT" ]; then
    echo "$UPSTREAM_TAG is $commit, not the pinned $UPSTREAM_COMMIT" >&2
    exit 1
fi

# Upstream's rust-toolchain.toml picks the compiler; add the target to it.
(cd "$SRC" && rustup target add "$TARGET" >/dev/null)
(cd "$SRC" && cargo zigbuild --locked --release --target "$TARGET.$GLIBC")
bin=$SRC/target/$TARGET/release/srtla_send

# Check what's packaged: an aarch64 executable needing no glibc newer than $GLIBC.
readelf -h "$bin" | grep -q 'Machine:.*AArch64' || { echo "srtla_send isn't aarch64" >&2; exit 1; }
newest=$(readelf -V --wide "$bin" | grep -oE 'GLIBC_[0-9.]+' | sed 's/GLIBC_//' | sort -V | tail -1)
if [ "$(printf '%s\n%s\n' "$newest" "$GLIBC" | sort -V | tail -1)" != "$GLIBC" ]; then
    echo "srtla_send needs glibc $newest, newer than $GLIBC" >&2
    exit 1
fi

install -D -m 0755 "$bin" "$STAGE/usr/bin/srtla_send"
doc=$STAGE/usr/share/doc/$NAME
install -d -m 0755 "$doc"
{
    echo "Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/"
    echo "Upstream-Name: srtla_send"
    echo "Source: ${UPSTREAM_REPO%.git} ($UPSTREAM_TAG, $UPSTREAM_COMMIT)"
    echo
    echo "Files: *"
    echo "License: MIT"
    sed 's/^$/./; s/^/ /' "$SRC/LICENSE"
} >"$doc/copyright"
chmod 0644 "$doc/copyright"

size=$(du -sk "$STAGE/usr" | cut -f1)
install -d -m 0755 "$STAGE/DEBIAN"
cat >"$STAGE/DEBIAN/control" <<CONTROL
Package: $NAME
Version: $VERSION
Architecture: $ARCH
Maintainer: Kenley <kench@users.noreply.github.com>
Installed-Size: $size
Depends: libc6 (>= $GLIBC)
Conflicts: srtla
Replaces: srtla
Section: net
Priority: optional
Homepage: ${UPSTREAM_REPO%.git}
Description: SRTLA bonding sender (irlserver srtla_send) for Helios
 Aggregates bandwidth across several network links for SRT streaming, sending
 to an SRTLA receiver. Built by kench/helios-packages from upstream
 $UPSTREAM_TAG ($UPSTREAM_COMMIT). Installs /usr/bin/srtla_send, as upstream's
 srtla package does, which it replaces.
CONTROL
chmod 0644 "$STAGE/DEBIAN/control"

deb=$OUT/${NAME}_${VERSION}_${ARCH}.deb
dpkg-deb --root-owner-group -Zxz --build "$STAGE" "$deb" >/dev/null
echo "built $deb"
