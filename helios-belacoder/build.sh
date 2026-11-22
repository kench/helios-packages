#!/bin/sh
# Builds a GStreamer SRT encoder's Debian package (helios-belacoder or helios-ceracoder, from
# package.env): $PROGRAM at $UPSTREAM_COMMIT with patches/, installed as /usr/bin/$PROGRAM. A smoke
# test sends a test pattern through it to a local SRT listener that requires a passphrase, and
# reloads its bitrate range with SIGHUP. Also writes the corresponding source
# (<package>_<version>_source.tar.xz), published next to the package (it's GPL-3.0).
#
# This file is helios-belacoder/build.sh and helios-ceracoder/build.sh: keep them identical.
#
# Usage: <package>/build.sh [OUT_DIR]   (default: out/)
# Runs natively on arm64 Debian Trixie, with $BUILD_DEPS installed (see package.env;
# .github/scripts/build-package.sh runs it in the pinned container). Sources go in src/ and the
# build in build/ (both ignored by git).
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/.." && pwd)
# shellcheck source=helios-belacoder/package.env
. "$HERE/package.env"
OUT=${1:-$TOP/out}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
SRC=$TOP/src/$NAME
WORK=$TOP/build/$NAME
STAGE=$WORK/stage
JOBS=$(nproc)

[ "$(dpkg --print-architecture)" = "$ARCH" ] || { echo "build $NAME on $ARCH" >&2; exit 1; }
grep -q '^VERSION_CODENAME=trixie$' /etc/os-release || { echo "build $NAME on Debian Trixie" >&2; exit 1; }

echo "== $NAME $VERSION"
rm -rf "$SRC" "$WORK"
mkdir -p "$SRC" "$STAGE"

# fetch DIR REPO COMMIT: just that commit, checked.
fetch() {
    git init --quiet "$1"
    git -C "$1" fetch --quiet --depth 1 "$2" "$3"
    git -C "$1" -c advice.detachedHead=false checkout --quiet FETCH_HEAD
    [ "$(git -C "$1" rev-parse HEAD)" = "$3" ] || { echo "$2: not $3" >&2; exit 1; }
}
code=$SRC/$PROGRAM
fetch "$code" "$UPSTREAM_REPO" "$UPSTREAM_COMMIT"
pinned=$(git -C "$code" ls-tree HEAD camlink_workaround | awk '{print $3}')
[ "$pinned" = "$CAMLINK_COMMIT" ] || { echo "$PROGRAM pins camlink $pinned, not $CAMLINK_COMMIT" >&2; exit 1; }
fetch "$code/camlink_workaround" "$CAMLINK_REPO" "$CAMLINK_COMMIT"
set -- "$HERE"/patches/*.patch
git -C "$code" -c user.name=helios-packages -c user.email=helios-packages@invalid am --quiet "$@"

echo "== $PROGRAM $UPSTREAM_COMMIT + $# patches"
# Debian's hardening flags (generic arm64: the Pi 5 and the RK3588 run it). The Makefile sets its
# own CFLAGS and LDFLAGS (pkg-config's), so the flags go in through CC and CPPFLAGS.
export DEB_BUILD_MAINT_OPTIONS=hardening=+all
cc="cc $(dpkg-buildflags --get CFLAGS) $(dpkg-buildflags --get LDFLAGS) -Wl,--as-needed"
make -C "$code" -j "$JOBS" "$PROGRAM" VERSION="$VERSION" CC="$cc" \
    CPPFLAGS="$(dpkg-buildflags --get CPPFLAGS)" >"$WORK/make.log" 2>&1 \
    || { tail -30 "$WORK/make.log"; exit 1; }
bin=$STAGE/usr/bin/$PROGRAM
install -D -m 0755 "$code/$PROGRAM" "$bin"
strip --strip-unneeded --remove-section=.comment --remove-section=.note "$bin"
[ "$("$bin" -v)" = "$VERSION" ] || { echo "$PROGRAM -v: $("$bin" -v)" >&2; exit 1; }

echo "== Smoke test: SRT with a passphrase, and a SIGHUP"
smoke=$WORK/smoke
mkdir -p "$smoke"
passphrase=helios-packages-smoke
port=19350
srt-live-transmit -q "srt://:$port?mode=listener&passphrase=$passphrase" file://con \
    >"$smoke/received.ts" 2>"$smoke/listener.log" &
listener=$!
cat >"$smoke/pipeline" <<'PIPELINE'
videotestsrc is-live=true ! video/x-raw,width=320,height=240,framerate=30/1 ! videoconvert !
queue ! x264enc name=venc_kbps speed-preset=ultrafast tune=zerolatency key-int-max=30 ! h264parse config-interval=-1 ! queue ! mux.

audiotestsrc is-live=true ! audioconvert ! audioresample ! voaacenc bitrate=64000 ! aacparse ! queue ! mux.

mpegtsmux name=mux ! appsink name=appsink
PIPELINE
range() {
    if [ "$RANGE" = ini ]; then
        printf '[general]\nmin_bitrate = %s\nmax_bitrate = %s\nbalancer = adaptive\n' "$1" "$2"
    else
        printf '%s\n%s\n' $(($1 * 1000)) $(($2 * 1000))
    fi >"$smoke/range"
}
option=-b
[ "$RANGE" = ini ] && option=-c
range 300 1000
sleep 1
"$bin" -s publish/live/smoke -l 1000 -p "$passphrase" "$option" "$smoke/range" \
    "$smoke/pipeline" 127.0.0.1 "$port" >"$smoke/encoder.log" 2>&1 &
encoder=$!
sleep 5
range 300 500
kill -HUP "$encoder"
sleep 3
kill "$encoder" 2>/dev/null || true
wait "$encoder" 2>/dev/null || true
kill "$listener" 2>/dev/null || true
wait "$listener" 2>/dev/null || true
fail() { echo "smoke test: $1" >&2; sed 's/^/  encoder: /' "$smoke/encoder.log" >&2; sed 's/^/  listener: /' "$smoke/listener.log" >&2; exit 1; }
grep -q '^SRT connected to 127.0.0.1' "$smoke/encoder.log" || fail "no SRT connection"
size=$(wc -c <"$smoke/received.ts")
[ "$size" -ge 50000 ] || fail "the listener got only $size bytes"
[ "$(od -An -tx1 -N1 "$smoke/received.ts" | tr -d ' ')" = 47 ] || fail "not MPEG-TS"
if [ "$RANGE" = ini ]; then
    grep -q 'Config reloaded: 300 - 500 Kbps' "$smoke/encoder.log" || fail "no reload on SIGHUP"
fi
echo "received $size bytes of MPEG-TS through SRT with a passphrase"
# The passphrase option refuses what libsrt would.
if "$bin" -p short "$smoke/pipeline" 127.0.0.1 "$port" >/dev/null 2>&1; then
    fail "-p accepted a 5-character passphrase"
fi

# The corresponding source: upstream at the commit, camlink, the patches and this recipe.
srcname=${NAME}_${VERSION}_source
srcdir=$WORK/$srcname
mkdir -p "$srcdir/recipe"
git -C "$code" archive --prefix="$PROGRAM/" "$UPSTREAM_COMMIT" | tar -x -C "$srcdir"
git -C "$code/camlink_workaround" archive --prefix="$PROGRAM/camlink_workaround/" HEAD | tar -x -C "$srcdir"
cp -r "$HERE/package.env" "$HERE/build.sh" "$HERE/patches" "$srcdir/recipe/"
cat >"$srcdir/README" <<README
Corresponding source of $NAME $VERSION, built by kench/helios-packages ($NAME/).
$PROGRAM/                     $UPSTREAM_REPO $UPSTREAM_COMMIT, unmodified
$PROGRAM/camlink_workaround/  $CAMLINK_REPO $CAMLINK_COMMIT (its submodule)
recipe/patches/               applied to it
recipe/build.sh               the build (run on arm64 Debian Trixie)
README
epoch=$(git -C "$code" log -1 --format=%ct "$UPSTREAM_COMMIT")
tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner -C "$WORK" -c "$srcname" \
    | xz -9 -T1 >"$OUT/$srcname.tar.xz"

doc=$STAGE/usr/share/doc/$NAME
install -d -m 0755 "$doc"
cat >"$doc/copyright" <<COPYRIGHT
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: $PROGRAM
Source: ${UPSTREAM_REPO%.git} ($UPSTREAM_COMMIT)
 with ${CAMLINK_REPO%.git} ($CAMLINK_COMMIT)
Comment: The corresponding source, $srcname.tar.xz, is published next to this
 package in the Helios APT repository (pool/$SUITE/$COMPONENT/
 $(printf '%.1s' "$NAME")/$NAME/); the recipe is kench/helios-packages, $NAME/.

Files: *
License: GPL-3+
 See /usr/share/common-licenses/GPL-3.
COPYRIGHT
chmod 0644 "$doc/copyright"

# Depends from the program's shared libraries (dpkg-shlibdeps wants a debian/control), plus the
# GStreamer elements Helios's pipelines use: base (test sources, conversion, appsink), good
# (flvdemux, v4l2src, jpegdec), bad (rtmpsrc, h264parse/h265parse, mpegtsmux, voaacenc);
# ugly (x264enc), libav (avdec_h264, avdec_aac) and alsa (alsasrc) for some.
mkdir -p "$WORK/shlibs/debian"
printf 'Source: %s\n\nPackage: %s\nArchitecture: %s\n' "$NAME" "$NAME" "$ARCH" >"$WORK/shlibs/debian/control"
depends=$(cd "$WORK/shlibs" && dpkg-shlibdeps -O -e"$bin" 2>/dev/null | sed -n 's/^shlibs:Depends=//p')
[ -n "$depends" ] || { echo "dpkg-shlibdeps found no dependencies" >&2; exit 1; }

size=$(du -sk "$STAGE/usr" | cut -f1)
install -d -m 0755 "$STAGE/DEBIAN"
cat >"$STAGE/DEBIAN/control" <<CONTROL
Package: $NAME
Version: $VERSION
Architecture: $ARCH
Maintainer: Kenley <kench@users.noreply.github.com>
Installed-Size: $size
Depends: $depends, gstreamer1.0-plugins-base, gstreamer1.0-plugins-good, gstreamer1.0-plugins-bad
Recommends: gstreamer1.0-plugins-ugly, gstreamer1.0-libav, gstreamer1.0-alsa
Suggests: helios-gst-rockchip-rk3588
Section: video
Priority: optional
Homepage: ${UPSTREAM_REPO%.git}
Description: Live video encoder with SRT and adaptive bitrate ($PROGRAM)
 $PROGRAM runs a GStreamer pipeline from a file and sends its MPEG-TS over SRT,
 adapting the video encoder's bitrate to what the link carries, within a range
 it rereads on SIGHUP. With -p to set an SRT passphrase (a helios-packages
 patch). Helios's stream module drives it for adaptive bitrate; on the RK3588,
 helios-gst-rockchip-rk3588 provides the hardware encoders. Built by
 kench/helios-packages.
CONTROL
chmod 0644 "$STAGE/DEBIAN/control"

deb=$OUT/${NAME}_${VERSION}_${ARCH}.deb
dpkg-deb --root-owner-group -Zxz --build "$STAGE" "$deb" >/dev/null
echo "built $deb and $OUT/$srcname.tar.xz"
