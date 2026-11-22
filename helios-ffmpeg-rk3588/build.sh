#!/bin/sh
# Builds the helios-ffmpeg-rk3588 Debian package: FFmpeg $UPSTREAM_TAG with nyanmisaka/ffmpeg-rockchip's
# patches (patches/), Rockchip MPP and librga linked in statically, for the RK3588 (Orange Pi 5
# Plus) on Armbian Trixie with the vendor kernel. Installs ffmpeg and ffprobe in $PREFIX/bin, so
# it never clashes with Debian's ffmpeg, plus udev rules giving the video group the Rockchip
# media devices. Also writes the corresponding source (<package>_<version>_source.tar.xz), which
# is published next to the package (the build is GPLv3).
#
# Usage: helios-ffmpeg-rk3588/build.sh [OUT_DIR]   (default: out/)
# Runs natively on arm64 Debian Trixie, with $BUILD_DEPS installed (see package.env;
# .github/scripts/build-package.sh runs it in the pinned container). Sources go in src/ and the
# build in build/ (both ignored by git).
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/.." && pwd)
# shellcheck source=helios-ffmpeg-rk3588/package.env
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
git clone --quiet --depth 1 --branch "$UPSTREAM_TAG" "$UPSTREAM_REPO" "$SRC/ffmpeg"
commit=$(git -C "$SRC/ffmpeg" rev-parse HEAD)
[ "$commit" = "$UPSTREAM_COMMIT" ] || { echo "$UPSTREAM_TAG is $commit, not $UPSTREAM_COMMIT" >&2; exit 1; }
fetch "$SRC/mpp" "$MPP_REPO" "$MPP_COMMIT"
fetch "$SRC/rga" "$RGA_REPO" "$RGA_COMMIT"
git -C "$SRC/ffmpeg" -c user.name=helios-packages -c user.email=helios-packages@invalid \
    am --quiet "$HERE"/patches/*.patch

# Debian's hardening flags, as Debian builds FFmpeg, tuned for the board's CPU. FFmpeg keeps its
# own -O3; the libraries get Debian's -O2. Binaries are stripped below.
export DEB_BUILD_MAINT_OPTIONS=hardening=+all
cpu_flags="-mcpu=$CPU"
CFLAGS="$(dpkg-buildflags --get CPPFLAGS) $(dpkg-buildflags --get CFLAGS) $cpu_flags"
CXXFLAGS="$(dpkg-buildflags --get CPPFLAGS) $(dpkg-buildflags --get CXXFLAGS) $cpu_flags"
LDFLAGS="$(dpkg-buildflags --get LDFLAGS) -Wl,--as-needed"
export CFLAGS CXXFLAGS LDFLAGS

echo "== Rockchip MPP $MPP_COMMIT (static)"
cmake -S "$SRC/mpp" -B "$WORK/mpp" -G Ninja -Wno-dev \
    -DCMAKE_BUILD_TYPE=None -DCMAKE_INSTALL_PREFIX="$DEPS" -DCMAKE_INSTALL_LIBDIR=lib \
    -DBUILD_TEST=OFF -DBUILD_SHARED_LIBS=OFF >/dev/null
ninja -C "$WORK/mpp" -j "$JOBS" install >/dev/null
# MPP and librga are C++ and static here, so linking them needs libstdc++ (jellyfin-ffmpeg adds it
# to Libs.private and links everything with --static). It goes in Libs instead, so FFmpeg links
# the system libraries (GnuTLS, x264, SRT) normally.
static_libs() { sed -i 's/^Libs: .*/& -lstdc++ -lpthread -lm/' "$1"; grep '^Libs:' "$1"; }
static_libs "$DEPS/lib/pkgconfig/rockchip_mpp.pc"

echo "== librga $RGA_COMMIT (static)"
sed -i 's/shared_library/library/g' "$SRC/rga/meson.build"
CXXFLAGS="$CXXFLAGS -fpermissive" meson setup "$WORK/rga" "$SRC/rga" \
    --prefix="$DEPS" --libdir=lib --buildtype=plain --default-library=static \
    -Dlibdrm=false -Dlibrga_demo=false >/dev/null
ninja -C "$WORK/rga" -j "$JOBS" install >/dev/null
static_libs "$DEPS/lib/pkgconfig/librga.pc"

set -- "$HERE"/patches/*.patch
echo "== FFmpeg $UPSTREAM_TAG + $# patches"
mkdir -p "$WORK/ffmpeg"
ffcflags="$(dpkg-buildflags --get CPPFLAGS) $(DEB_CFLAGS_MAINT_STRIP='-O2 -g' dpkg-buildflags --get CFLAGS)"
ffcxxflags=$CXXFLAGS
ffldflags=$LDFLAGS
(
    cd "$WORK/ffmpeg"
    # --cpu becomes -mcpu; the assembly is chosen at run time. configure would also take CFLAGS
    # and friends from the environment (the libraries' -O2 -g): only the --extra flags here.
    unset CFLAGS CXXFLAGS LDFLAGS
    PKG_CONFIG_PATH=$DEPS/lib/pkgconfig "$SRC/ffmpeg/configure" \
        --prefix="$PREFIX" \
        --arch=aarch64 \
        --cpu="$CPU" \
        --extra-version="helios-${VERSION#*-}" \
        --extra-cflags="$ffcflags" \
        --extra-cxxflags="$ffcxxflags" \
        --extra-ldflags="$ffldflags" \
        --enable-gpl \
        --enable-version3 \
        --disable-shared \
        --enable-static \
        --disable-debug \
        --disable-doc \
        --disable-ffplay \
        --enable-libdrm \
        --enable-rkmpp \
        --enable-rkrga \
        --enable-libx264 \
        --enable-libsrt \
        --enable-gnutls \
        >"$WORK/configure.log" || { tail -40 "$WORK/configure.log"; tail -60 ffbuild/config.log; exit 1; }
    make -j "$JOBS" >/dev/null
    make DESTDIR="$STAGE" install >/dev/null
    # FFmpeg's assembly self-tests, on this CPU.
    make -j "$JOBS" checkasm >/dev/null
    tests/checkasm/checkasm >"$WORK/checkasm.log" 2>&1 || { tail -40 "$WORK/checkasm.log"; exit 1; }
    tail -1 "$WORK/checkasm.log"
)

# Only the programs: the static libraries, headers and examples stay out.
bin=$STAGE$PREFIX/bin
rm -rf "${STAGE:?}$PREFIX/lib" "$STAGE$PREFIX/include" "$STAGE$PREFIX/share/ffmpeg/examples"
strip --strip-unneeded --remove-section=.comment --remove-section=.note "$bin/ffmpeg" "$bin/ffprobe"

echo "== Checks"
check() { printf '%s\n' "$2" | grep -qE "$3" || { echo "$1: missing $3" >&2; exit 1; }; }
encoders=$("$bin/ffmpeg" -hide_banner -encoders)
decoders=$("$bin/ffmpeg" -hide_banner -decoders)
for c in h264_rkmpp hevc_rkmpp libx264 aac; do check encoders "$encoders" " $c "; done
for c in h264_rkmpp hevc_rkmpp vp9_rkmpp av1_rkmpp; do check decoders "$decoders" " $c "; done
for f in scale_rkrga vpp_rkrga overlay_rkrga; do
    check filters "$("$bin/ffmpeg" -hide_banner -filters)" " $f "
done
check hwaccels "$("$bin/ffmpeg" -hide_banner -hwaccels)" '^rkmpp$'
for p in rtmp rtmps srt https; do
    check protocols "$("$bin/ffmpeg" -hide_banner -protocols)" "^ +$p$"
done
check license "$("$bin/ffmpeg" -hide_banner -L)" 'version 3'
needed=$(readelf -d "$bin/ffmpeg" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | tr '\n' ' ')
case $needed in
    *rockchip* | *librga*) echo "MPP or RGA is linked dynamically: $needed" >&2; exit 1 ;;
esac
echo "ffmpeg: $("$bin/ffmpeg" -hide_banner -version | head -1)"
echo "needs: $needed"

# udev rules: the media devices the fork's README lists, for the video group (helios is a
# member on the boards).
install -D -m 0644 /dev/stdin "$STAGE/usr/lib/udev/rules.d/60-helios-rockchip-media.rules" <<'RULES'
# Installed by helios-ffmpeg-rk3588: Rockchip MPP, RGA and DMA heaps for the video group.
KERNEL=="mpp_service|mpp-service|vpu_service|vpu-service|hevc_service|hevc-service|rkvdec|rkvenc|vepu|h265e|iep|rga", GROUP="video", MODE="0660"
SUBSYSTEM=="dma_heap", GROUP="video", MODE="0660"
RULES

# The corresponding source: upstream FFmpeg at the tag, the patches, MPP, librga and this recipe.
srcname=${NAME}_${VERSION}_source
srcdir=$WORK/$srcname
mkdir -p "$srcdir/recipe"
git -C "$SRC/ffmpeg" archive --prefix="ffmpeg-$UPSTREAM_TAG/" "$UPSTREAM_COMMIT" | tar -x -C "$srcdir"
git -C "$SRC/mpp" archive --prefix=rockchip-mpp/ HEAD | tar -x -C "$srcdir"
(cd "$SRC/rga" && git checkout --quiet -- meson.build && git archive --prefix=librga/ HEAD) | tar -x -C "$srcdir"
cp -r "$HERE/package.env" "$HERE/build.sh" "$HERE/patches" "$srcdir/recipe/"
cat >"$srcdir/README" <<README
Corresponding source of $NAME $VERSION, built by kench/helios-packages ($NAME/).
ffmpeg-$UPSTREAM_TAG/  FFmpeg $UPSTREAM_TAG ($UPSTREAM_COMMIT), unmodified
recipe/patches/        applied to it: nyanmisaka/ffmpeg-rockchip $FORK_BRANCH at $FORK_COMMIT
rockchip-mpp/          Rockchip MPP, $MPP_REPO $MPP_COMMIT
librga/                librga, $RGA_REPO $RGA_COMMIT
recipe/build.sh        the build (run on arm64 Debian Trixie)
README
epoch=$(git -C "$SRC/ffmpeg" log -1 --format=%ct "$UPSTREAM_COMMIT")
tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner -C "$WORK" -c "$srcname" \
    | xz -9 -T1 >"$OUT/$srcname.tar.xz"

doc=$STAGE/usr/share/doc/$NAME
install -d -m 0755 "$doc"
cat >"$doc/copyright" <<COPYRIGHT
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: FFmpeg, with nyanmisaka/ffmpeg-rockchip, Rockchip MPP and librga
Source: ${UPSTREAM_REPO%.git} ($UPSTREAM_TAG, $UPSTREAM_COMMIT)
 with ${FORK_REPO%.git} ($FORK_BRANCH, $FORK_COMMIT),
 ${MPP_REPO%.git} ($MPP_COMMIT) and ${RGA_REPO%.git} ($RGA_COMMIT)
Comment: Built with --enable-gpl --enable-version3: the programs as a whole are under
 the GPL, version 3 or later. The corresponding source, $srcname.tar.xz, is
 published next to this package in the Helios APT repository (pool/$SUITE/$COMPONENT/
 $(printf '%.1s' "$NAME")/$NAME/); the recipe is kench/helios-packages, $NAME/.

Files: *
License: GPL-3+
 FFmpeg is LGPL-2.1+ with optional GPL-2+ parts (libx264 and libpostproc here);
 ffmpeg-rockchip's patches are LGPL-2.1+. See /usr/share/common-licenses/GPL-3.

Files: rockchip-mpp/*
License: Apache-2.0 and MIT
 See /usr/share/common-licenses/Apache-2.0. MIT:
$(sed 's/^$/./; s/^/ /' "$SRC/mpp/LICENSES/MIT")

Files: librga/*
License: Apache-2.0
 See /usr/share/common-licenses/Apache-2.0.
COPYRIGHT
chmod 0644 "$doc/copyright"

# Depends from the programs' shared libraries (dpkg-shlibdeps wants a debian/control).
mkdir -p "$WORK/shlibs/debian"
printf 'Source: %s\n\nPackage: %s\nArchitecture: %s\n' "$NAME" "$NAME" "$ARCH" >"$WORK/shlibs/debian/control"
depends=$(cd "$WORK/shlibs" && dpkg-shlibdeps -O -e"$bin/ffmpeg" -e"$bin/ffprobe" 2>/dev/null \
    | sed -n 's/^shlibs:Depends=//p')
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
Recommends: udev
Provides: helios-ffmpeg
Conflicts: helios-ffmpeg
Replaces: helios-ffmpeg
Section: video
Priority: optional
Homepage: ${FORK_REPO%.git}
Description: FFmpeg with Rockchip MPP and RGA hardware acceleration for RK3588
 FFmpeg $UPSTREAM_TAG with nyanmisaka/ffmpeg-rockchip's patches: hardware H.264,
 HEVC, VP9 and AV1 decoding and H.264/HEVC encoding (Rockchip MPP), hardware
 scaling, cropping and overlays (RGA), x264, SRT and RTMP/RTMPS. Tuned for the
 RK3588's Cortex-A76 and Cortex-A55 cores; needs Rockchip's vendor kernel.
 Installs ffmpeg and ffprobe in $PREFIX/bin, next to Debian's ffmpeg, and udev
 rules giving the video group the Rockchip media devices. Built by
 kench/helios-packages.
CONTROL
chmod 0644 "$STAGE/DEBIAN/control"
# Apply the udev rules to devices already present, without a reboot.
cat >"$STAGE/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
set -e
if [ "$1" = configure ] && command -v udevadm >/dev/null && [ -d /run/udev ]; then
    udevadm control --reload-rules || true
    # By name as well as subsystem: /dev/mpp_service is in subsystem mpp_class, not misc
    # (found on the Orange Pi 5 Plus, 2026-11-21), and the other names vary by kernel.
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
