#!/bin/sh
# Builds helios-packages' suite of the Helios APT repository in REPO_DIR, from the packages already
# published there (REPO_DIR/pool/SUITE, synced from S3) and the new .deb files, and signs it with
# the GPG key KEY_ID. Adapted from kench/helios's script, which publishes Helios to "stable".
#
# Usage: build-apt-repo.sh REPO_DIR KEY_ID SUITE COMPONENT DEB...
#
# Layout (helios-packages owns everything under its suite):
#   pool/SUITE/COMPONENT/<p>/<package>/<package>_<version>_<arch>.deb   never changed once published
#   dists/SUITE/COMPONENT/binary-<arch>/Packages[.gz]                     every package in the pool
#   dists/SUITE/{Release,Release.gpg,InRelease}                           the signed release file
#   keys/helios-packages-archive-keyring.asc                              the public key (signed-by)
#
# The Release file says Origin "Helios" and Label "Helios packages", for unattended-upgrades'
# origin patterns. Needs apt-ftparchive (apt-utils), gpg, gzip and dpkg-deb. Publishing order
# (packages first, InRelease last) is the caller's job.
set -eu

if [ $# -lt 5 ]; then
    echo "usage: $0 REPO_DIR KEY_ID SUITE COMPONENT DEB..." >&2
    exit 2
fi
repo=$1
key=$2
suite=$3
component=$4
shift 4

for deb in "$@"; do
    package=$(dpkg-deb -f "$deb" Package)
    dir=$repo/pool/$suite/$component/$(printf '%.1s' "$package")/$package
    name=$(basename "$deb")
    mkdir -p "$dir"
    if [ -e "$dir/$name" ] && ! cmp -s "$deb" "$dir/$name"; then
        echo "$name is already published with different contents; bump the version" >&2
        exit 1
    fi
    cp "$deb" "$dir/$name"
done

cd "$repo"
mkdir -p keys
rm -rf "dists/$suite"
components=
archs_all=
for dir in "pool/$suite"/*/; do
    comp=$(basename "$dir")
    components="$components $comp"
    archs=$(find "$dir" -name '*.deb' -exec dpkg-deb -f {} Architecture \; | sort -u)
    for arch in $archs; do
        out=dists/$suite/$comp/binary-$arch
        mkdir -p "$out"
        apt-ftparchive --arch "$arch" packages "pool/$suite/$comp" >"$out/Packages"
        gzip -9 -n -k "$out/Packages"
        archs_all="$archs_all $arch"
    done
done
components=$(echo "$components" | xargs -n1 | sort -u | xargs)
archs_all=$(echo "$archs_all" | xargs -n1 | sort -u | xargs)

apt-ftparchive \
    -o APT::FTPArchive::Release::Origin=Helios \
    -o "APT::FTPArchive::Release::Label=Helios packages" \
    -o "APT::FTPArchive::Release::Suite=$suite" \
    -o "APT::FTPArchive::Release::Codename=$suite" \
    -o "APT::FTPArchive::Release::Architectures=$archs_all" \
    -o "APT::FTPArchive::Release::Components=$components" \
    -o "APT::FTPArchive::Release::Description=Helios board packages" \
    release "dists/$suite" >"dists/$suite/Release.new"
mv "dists/$suite/Release.new" "dists/$suite/Release"

gpg --batch --yes --local-user "$key" --armor --detach-sign \
    --output "dists/$suite/Release.gpg" "dists/$suite/Release"
gpg --batch --yes --local-user "$key" --clearsign \
    --output "dists/$suite/InRelease" "dists/$suite/Release"
gpg --batch --yes --armor --export "$key" >keys/helios-packages-archive-keyring.asc

echo "built $repo: suite $suite, components $components, architectures $archs_all"
