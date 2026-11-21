#!/bin/sh
# Builds one package: runs PACKAGE/build.sh OUT_DIR, inside PACKAGE's BUILD_CONTAINER with its
# BUILD_DEPS installed when package.env sets one (needs docker), otherwise on this computer.
#
# Usage: .github/scripts/build-package.sh PACKAGE [OUT_DIR]   (default: out/)
set -eu

if [ $# -lt 1 ]; then
    echo "usage: $0 PACKAGE [OUT_DIR]" >&2
    exit 2
fi
TOP=$(cd "$(dirname "$0")/../.." && pwd)
package=$1
out=${2:-out}
if [ ! -f "$TOP/$package/package.env" ] || [ ! -x "$TOP/$package/build.sh" ]; then
    echo "no package folder $package with package.env and build.sh" >&2
    exit 1
fi
BUILD_CONTAINER=
BUILD_DEPS=
# shellcheck source=/dev/null
. "$TOP/$package/package.env"

if [ -z "$BUILD_CONTAINER" ]; then
    exec "$TOP/$package/build.sh" "$out"
fi

case $out in
    /*) echo "OUT_DIR must be relative to the repository with a container build" >&2; exit 1 ;;
esac
echo "== $package in $BUILD_CONTAINER"
# The files in OUT_DIR, src/ and build/ are given back to the caller's user afterwards.
docker run --rm -v "$TOP:/work" -w /work \
    -e BUILD_DEPS="$BUILD_DEPS" -e PACKAGE="$package" -e OUT="$out" -e OWNER="$(id -u):$(id -g)" \
    "$BUILD_CONTAINER" sh -euc '
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        # shellcheck disable=SC2086
        apt-get install -y -qq --no-install-recommends $BUILD_DEPS >/dev/null
        status=0
        "./$PACKAGE/build.sh" "$OUT" || status=$?
        mkdir -p "$OUT" src build
        chown -R "$OWNER" "$OUT" src build
        exit $status
    '
