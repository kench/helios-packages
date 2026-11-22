#!/bin/sh
# Builds the helios-gst-rockchip-rk3588 Debian package: BELABOX's gstreamer-rockchip at
# $UPSTREAM_COMMIT with patches/, Rockchip MPP and librga linked in statically, for the RK3588 on
# Armbian Trixie with the vendor kernel. Installs the plugin in $PLUGIN_DIR (not GStreamer's own
# directory), plus udev rules giving the video group the Rockchip media devices. Also writes the
# corresponding source (<package>_<version>_source.tar.xz), published next to the package.
#
# Usage: helios-gst-rockchip-rk3588/build.sh [OUT_DIR]   (default: out/)
# Runs natively on arm64 Debian Trixie, with $BUILD_DEPS installed (see package.env;
# .github/scripts/build-package.sh runs it in the pinned container). Sources go in src/ and the
# build in build/ (both ignored by git).
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/.." && pwd)
# shellcheck source=helios-gst-rockchip-rk3588/package.env
. "$HERE/package.env"
OUT=${1:-$TOP/out}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
SRC=$TOP/src/$NAME
WORK=$TOP/build/$NAME
DEPS=$WORK/deps
STAGE=$WORK/stage
JOBS=$(nproc)

[ "$(dpkg --print-architecture)" = "$ARCH" ] || { echo "build $NAME on $ARCH" >&2; exit 1; }
grep -q '^VERSION_CODENAME=trixie$' /etc/os-release || { echo "build $NAME on Debian Trixie" >&2; exit 1; }

echo "== $NAME $VERSION"
rm -rf "$SRC" "$WORK"
mkdir -p "$SRC" "$DEPS" "$STAGE"

# fetch DIR REPO COMMIT: just that commit, checked.
fetch() {
    git init --quiet "$1"
    git -C "$1" fetch --quiet --depth 1 "$2" "$3"
    git -C "$1" -c advice.detachedHead=false checkout --quiet FETCH_HEAD
    [ "$(git -C "$1" rev-parse HEAD)" = "$3" ] || { echo "$2: not $3" >&2; exit 1; }
}
fetch "$SRC/gst" "$UPSTREAM_REPO" "$UPSTREAM_COMMIT"
fetch "$SRC/mpp" "$MPP_REPO" "$MPP_COMMIT"
fetch "$SRC/rga" "$RGA_REPO" "$RGA_COMMIT"
git -C "$SRC/gst" -c user.name=helios-packages -c user.email=helios-packages@invalid \
    am --quiet "$HERE"/patches/*.patch

# Debian's hardening flags, tuned for the board's CPU. Binaries are stripped below.
export DEB_BUILD_MAINT_OPTIONS=hardening=+all
cpu_flags="-mcpu=$CPU"
CFLAGS="$(dpkg-buildflags --get CPPFLAGS) $(dpkg-buildflags --get CFLAGS) $cpu_flags"
CXXFLAGS="$(dpkg-buildflags --get CPPFLAGS) $(dpkg-buildflags --get CXXFLAGS) $cpu_flags"
LDFLAGS="$(dpkg-buildflags --get LDFLAGS) -Wl,--as-needed"
export CFLAGS CXXFLAGS LDFLAGS

# MPP and librga are C++ and static, inside a shared plugin: position-independent, and linking
# them needs libstdc++ (added to Libs, as in helios-ffmpeg-rk3588).
static_libs() { sed -i 's/^Libs: .*/& -lstdc++ -lpthread -lm/' "$1"; grep '^Libs:' "$1"; }
echo "== Rockchip MPP $MPP_COMMIT (static, PIC)"
cmake -S "$SRC/mpp" -B "$WORK/mpp" -G Ninja -Wno-dev \
    -DCMAKE_BUILD_TYPE=None -DCMAKE_INSTALL_PREFIX="$DEPS" -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_TEST=OFF -DBUILD_SHARED_LIBS=OFF >/dev/null
ninja -C "$WORK/mpp" -j "$JOBS" install >/dev/null
static_libs "$DEPS/lib/pkgconfig/rockchip_mpp.pc"

echo "== librga $RGA_COMMIT (static, PIC)"
sed -i 's/shared_library/library/g' "$SRC/rga/meson.build"
CXXFLAGS="$CXXFLAGS -fpermissive" meson setup "$WORK/rga" "$SRC/rga" \
    --prefix="$DEPS" --libdir=lib --buildtype=plain --default-library=static -Db_staticpic=true \
    -Dlibdrm=false -Dlibrga_demo=false >/dev/null
ninja -C "$WORK/rga" -j "$JOBS" install >/dev/null
static_libs "$DEPS/lib/pkgconfig/librga.pc"

set -- "$HERE"/patches/*.patch
echo "== gstreamer-rockchip $UPSTREAM_COMMIT + $# patches"
# --libdir puts the plugin in $PLUGIN_DIR: meson installs plugins in <libdir>/gstreamer-1.0.
PKG_CONFIG_PATH=$DEPS/lib/pkgconfig meson setup "$WORK/gst" "$SRC/gst" \
    --prefix=/usr --libdir="${PLUGIN_DIR%/gstreamer-1.0}" --buildtype=plain \
    -Drockchipmpp=enabled -Drga=enabled -Drkximage=disabled -Dkmssrc=disabled \
    -Dpackage-name="$NAME" -Dpackage-origin="https://github.com/kench/helios-packages" \
    >"$WORK/meson.log" 2>&1 || { tail -40 "$WORK/meson.log"; exit 1; }
ninja -C "$WORK/gst" -j "$JOBS" >"$WORK/ninja.log" 2>&1 || { tail -40 "$WORK/ninja.log"; exit 1; }
DESTDIR=$STAGE ninja -C "$WORK/gst" install >/dev/null
plugin=$STAGE$PLUGIN_DIR/libgstrockchipmpp.so
# Only the MPP plugin (kmssrc and rkximage are off).
find "$STAGE" -type f ! -path "$plugin" -print -delete
find "$STAGE" -depth -type d -empty -delete
strip --strip-unneeded --remove-section=.comment --remove-section=.note "$plugin"

echo "== Checks"
needed=$(readelf -d "$plugin" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | tr '\n' ' ')
case $needed in
    *rockchip* | *librga*) echo "MPP or RGA is linked dynamically: $needed" >&2; exit 1 ;;
esac
echo "needs: $needed"
# The elements belacoder's and ceracoder's pipelines use register without Rockchip hardware.
registry=$WORK/registry.bin
inspect() { GST_REGISTRY=$registry GST_PLUGIN_PATH=$STAGE$PLUGIN_DIR gst-inspect-1.0 "$@"; }
elements=$(inspect rockchipmpp)
for e in mpph264enc mpph265enc mppvideodec mppjpegdec; do
    printf '%s\n' "$elements" | grep -qE "^ +$e:" || { echo "rockchipmpp: no $e" >&2; exit 1; }
done
for p in bitrate bitrate-min bitrate-max gop width height; do
    inspect mpph265enc | grep -qE "^  $p +:" || { echo "mpph265enc: no $p property" >&2; exit 1; }
done
printf '%s\n' "$elements" | grep -E "^ +(Version|mpp)"

# udev rules: the media devices, for the video group (as helios-ffmpeg-rk3588 installs; either
# package alone is enough, and both together are harmless).
install -D -m 0644 /dev/stdin "$STAGE/usr/lib/udev/rules.d/60-helios-gst-rockchip.rules" <<'RULES'
# Installed by helios-gst-rockchip-rk3588: Rockchip MPP, RGA and DMA heaps for the video group.
KERNEL=="mpp_service|mpp-service|vpu_service|vpu-service|hevc_service|hevc-service|rkvdec|rkvenc|vepu|h265e|iep|rga", GROUP="video", MODE="0660"
SUBSYSTEM=="dma_heap", GROUP="video", MODE="0660"
RULES

# The corresponding source: the plugin at the commit, its patches, MPP, librga and this recipe.
srcname=${NAME}_${VERSION}_source
srcdir=$WORK/$srcname
mkdir -p "$srcdir/recipe"
git -C "$SRC/gst" archive --prefix=gstreamer-rockchip/ "$UPSTREAM_COMMIT" | tar -x -C "$srcdir"
git -C "$SRC/mpp" archive --prefix=rockchip-mpp/ HEAD | tar -x -C "$srcdir"
(cd "$SRC/rga" && git checkout --quiet -- meson.build && git archive --prefix=librga/ HEAD) | tar -x -C "$srcdir"
cp -r "$HERE/package.env" "$HERE/build.sh" "$HERE/patches" "$srcdir/recipe/"
cat >"$srcdir/README" <<README
Corresponding source of $NAME $VERSION, built by kench/helios-packages ($NAME/).
gstreamer-rockchip/  $UPSTREAM_REPO $UPSTREAM_COMMIT, unmodified
recipe/patches/      applied to it
rockchip-mpp/        Rockchip MPP, $MPP_REPO $MPP_COMMIT
librga/              librga, $RGA_REPO $RGA_COMMIT
recipe/build.sh      the build (run on arm64 Debian Trixie)
README
epoch=$(git -C "$SRC/gst" log -1 --format=%ct "$UPSTREAM_COMMIT")
tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner -C "$WORK" -c "$srcname" \
    | xz -9 -T1 >"$OUT/$srcname.tar.xz"

doc=$STAGE/usr/share/doc/$NAME
install -d -m 0755 "$doc"
cat >"$doc/copyright" <<COPYRIGHT
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: gstreamer-rockchip (BELABOX), with Rockchip MPP and librga
Source: ${UPSTREAM_REPO%.git} ($UPSTREAM_COMMIT)
 with ${MPP_REPO%.git} ($MPP_COMMIT) and ${RGA_REPO%.git} ($RGA_COMMIT)
Comment: The corresponding source, $srcname.tar.xz, is published next to this
 package in the Helios APT repository (pool/$SUITE/$COMPONENT/
 $(printf '%.1s' "$NAME")/$NAME/); the recipe is kench/helios-packages, $NAME/.

Files: *
License: LGPL-2.1+
 See /usr/share/common-licenses/LGPL-2.1.

Files: rockchip-mpp/*
License: Apache-2.0 and MIT
 See /usr/share/common-licenses/Apache-2.0. MIT:
$(sed 's/^$/./; s/^/ /' "$SRC/mpp/LICENSES/MIT")

Files: librga/*
License: Apache-2.0
 See /usr/share/common-licenses/Apache-2.0.
COPYRIGHT
chmod 0644 "$doc/copyright"

# Depends from the plugin's shared libraries (dpkg-shlibdeps wants a debian/control).
mkdir -p "$WORK/shlibs/debian"
printf 'Source: %s\n\nPackage: %s\nArchitecture: %s\n' "$NAME" "$NAME" "$ARCH" >"$WORK/shlibs/debian/control"
depends=$(cd "$WORK/shlibs" && dpkg-shlibdeps -O -e"$plugin" 2>/dev/null | sed -n 's/^shlibs:Depends=//p')
[ -n "$depends" ] || { echo "dpkg-shlibdeps found no dependencies" >&2; exit 1; }

size=$(du -sk "$STAGE/usr" | cut -f1)
install -d -m 0755 "$STAGE/DEBIAN"
cat >"$STAGE/DEBIAN/control" <<CONTROL
Package: $NAME
Version: $VERSION
Architecture: $ARCH
Maintainer: Kenley <kench@users.noreply.github.com>
Installed-Size: $size
Depends: $depends
Recommends: udev, gstreamer1.0-plugins-base
Section: video
Priority: optional
Homepage: ${UPSTREAM_REPO%.git}
Description: GStreamer elements for Rockchip MPP hardware video on RK3588
 BELABOX's gstreamer-rockchip: hardware H.264 and HEVC encoding (mpph264enc,
 mpph265enc, with bitrate changes while running), video and JPEG decoding
 (mppvideodec, mppjpegdec) and RGA conversion, with Rockchip MPP and librga
 built in. For belacoder and ceracoder (helios-belacoder, helios-ceracoder);
 installed in $PLUGIN_DIR, so set GST_PLUGIN_PATH
 to use it. Needs Rockchip's vendor kernel. Also installs udev rules giving the
 video group the Rockchip media devices. Built by kench/helios-packages.
CONTROL
chmod 0644 "$STAGE/DEBIAN/control"
# Apply the udev rules to devices already present, without a reboot.
cat >"$STAGE/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
set -e
if [ "$1" = configure ] && command -v udevadm >/dev/null && [ -d /run/udev ]; then
    udevadm control --reload-rules || true
    # By name as well as subsystem: /dev/mpp_service is in subsystem mpp_class, not misc.
    for name in mpp_service mpp-service vpu_service vpu-service hevc_service hevc-service \
        rkvdec rkvenc vepu h265e iep rga; do
        udevadm trigger --action=change --sysname-match="$name" || true
    done
    udevadm trigger --action=change --subsystem-match=dma_heap || true
fi
POSTINST
chmod 0755 "$STAGE/DEBIAN/postinst"

deb=$OUT/${NAME}_${VERSION}_${ARCH}.deb
dpkg-deb --root-owner-group -Zxz --build "$STAGE" "$deb" >/dev/null
echo "built $deb and $OUT/$srcname.tar.xz"
