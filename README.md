# helios-packages

Debian packages of the third-party software Helios devices need, built for each board's
hardware and published to the Helios APT repository (helios-cloud's `AptRepository` stack),
next to the `helios` package itself.

| Package | Board | Contents |
| --- | --- | --- |
| `helios-ffmpeg-rpi5` | Raspberry Pi 5 (Pi OS Trixie) | FFmpeg with the Raspberry Pi patch set (V4L2 request HEVC decode, DRM/EGL output), libx264, libsrt |
| `helios-ffmpeg-rk3588` | Orange Pi 5 Plus (Armbian Trixie, vendor kernel 6.1) | FFmpeg 9.0.2 with [nyanmisaka/ffmpeg-rockchip](https://github.com/nyanmisaka/ffmpeg-rockchip)'s patches: Rockchip MPP hardware decode (H.264, HEVC, VP9, AV1) and encode (H.264, HEVC), RGA scale/crop/overlay, libx264, libsrt, RTMP/RTMPS (GnuTLS). **Recipe ready; to verify on the board** |
| `helios-srtla-send` | any arm64 | irlserver [srtla_send](https://github.com/irlserver/srtla_send) (MIT), the SRTLA bonding sender, as `/usr/bin/srtla_send`. **Packaged** (`4.1.0-1`) |
| `helios-srtla` | any arm64 | BELABOX srtla (`srtla_send`, `srtla_rec`), if still needed; its `srtla_send` would install aside, under `/usr/lib/helios-srtla/` |

## Status

`helios-srtla-send` is packaged; `helios-ffmpeg-rk3588`'s recipe builds in CI and waits for the
Orange Pi; `helios-ffmpeg-rpi5` is next. `AGENTS.md` lists the next steps for each package.

## Packages and releases

Each package is a folder with `package.env` (name, version, pinned upstream tag and commit,
suite, component, target, and optionally `BUILD_RUNNER`, `BUILD_CONTAINER`, `BUILD_DEPS`) and
`build.sh`, which fetches the pinned upstream source, checks the commit, builds it and writes
`out/<package>_<version>_<arch>.deb` (and, for GPL packages, `<package>_<version>_source.tar.xz`).
`.github/scripts/build-package.sh` runs it, in the package's container when it names one:

```sh
.github/scripts/build-package.sh helios-srtla-send     # on the host: rustup, cargo-zigbuild, zig 0.14.1
.github/scripts/build-package.sh helios-ffmpeg-rk3588  # on an arm64 host with docker (debian:trixie)
```

`.github/workflows/build-package.yml` is the build in GitHub Actions, on the runner `package.env`
asks for (`ubuntu-24.04-arm` for native arm64 builds). CI runs it on every PR for each package
whose folder changed, and the release workflow runs it before publishing.

To release, merge the version change to `main`, then tag that commit `<package>/<version>` (for
example `helios-srtla-send/4.1.0-1`) and push the tag. `.github/workflows/release.yml` checks the
tag against `package.env` and that it's on `main`, builds the package, and publishes it with
`.github/scripts/build-apt-repo.sh` to this repository's suite of the Helios APT repository:

| | |
| --- | --- |
| Suite | `trixie` (Origin `Helios`, Label `Helios packages`), components `main`, `rpi5`, `rk3588` |
| Pool | `pool/trixie/<component>/<p>/<package>/` |
| Signing key | "Helios packages archive", ED25519, fingerprint `328F 19E1 F0AA A7B1 43E1 017F 7135 FAE9 F8FE 4181`, published at `/keys/helios-packages-archive-keyring.asc`. The private key is only this repository's `APT_SIGNING_KEY` secret |
| Publisher | helios-cloud's `helios-packages-publisher` role, assumed through GitHub OIDC only by this repository's release tags, and allowed to write only this suite and its key |

A board lists it next to Helios's suite, each with its own key:

```
deb [arch=arm64 signed-by=/usr/share/keyrings/helios-archive-keyring.gpg] <repo> stable main
deb [arch=arm64 signed-by=/usr/share/keyrings/helios-packages-archive-keyring.gpg] <repo> trixie main <board>
```

## Plan

- Each FFmpeg package installs `ffmpeg` and `ffprobe` to `/usr/lib/helios-ffmpeg/bin`, so it
  never clashes with the distribution's FFmpeg, and both provide `helios-ffmpeg` and conflict
  with each other. Helios's video module uses the same path on every board.
- Builds run natively on GitHub's arm64 runners in a pinned `debian:trixie` container (glibc
  2.41); `dpkg-shlibdeps` sets the runtime dependencies. FFmpeg's own libraries are linked
  statically, so there's no rpath.
- Releases are tagged per package (for example `helios-ffmpeg-rpi5/9.0.2-1`) and published to the
  `trixie` suite, in a component per board (`rpi5`, `rk3588`) plus `main` for board-independent
  packages, signed with this repository's own key (above).
- The FFmpeg builds are GPL (libx264): this public repository holds the scripts and patches,
  and each release also publishes its corresponding source next to the package in the pool
  (`<package>_<version>_source.tar.xz`).

## helios-ffmpeg-rk3588

- **FFmpeg n9.0.2 + `patches/`:** nyanmisaka/ffmpeg-rockchip's 19 commits on FFmpeg's
  `release/9.0` (branch `9.0` at `FORK_COMMIT`), exported with `git format-patch`; they apply
  unchanged to n9.0.2. To update: fetch the fork's branch and `release/9.0`, then
  `git format-patch --zero-commit --no-signature -o patches/ <release/9.0>..<fork>` and bump
  `FORK_COMMIT` and the version.
- **Rockchip MPP and librga, linked statically,** at the commits jellyfin-ffmpeg builds with
  (`nyanmisaka/rk-mirrors`, `jellyfin-mpp-next` and `jellyfin-rga-next`). Neither is in Debian;
  linking them in means nothing else to install, and no clash with Armbian's own packages.
- **Configured with** `--enable-gpl --enable-version3` (required for MPP; the result is GPLv3),
  `--enable-rkmpp --enable-rkrga --enable-libdrm --enable-libx264 --enable-libsrt --enable-gnutls`
  (RTMPS and HTTPS), static FFmpeg libraries, no ffplay or docs. FFmpeg's native RTMP covers
  `rtmp://` and Enhanced RTMP.
- **Checked when built:** the MPP encoders and decoders, the RGA filters, the `rkmpp` hwaccel,
  the `rtmp`, `rtmps`, `srt` and `https` protocols, GPLv3, MPP/RGA not linked dynamically, and
  FFmpeg's `checkasm` (on the runner's CPU).
- **udev rules** (`/usr/lib/udev/rules.d/60-helios-rockchip-media.rules`) give the `video` group
  `/dev/mpp_service`, `/dev/rga`, `/dev/dma_heap/*` and the older device names; Helios's user
  must be in `video`.
- **On the board, before the first release:** the encoder and RGA on real video (for example
  `ffmpeg -hwaccel rkmpp -hwaccel_output_format drm_prime -i in.mp4 -vf scale_rkrga=w=1280:h=720
  -c:v h264_rkmpp out.mp4`), the device permissions as the `helios` user, `checkasm` on the
  RK3588, and the build flags (README: "FFmpeg build flags").

The Raspberry Pi 5 build comes from
[kench/raspberry-pi-5-tools](https://github.com/kench/raspberry-pi-5-tools).

## CI

`.github/workflows/ci.yml` checks that each PR title and commit subject follows Conventional
Commits (`.github/scripts/check-conventional-commit.sh`, the same rules as the other Helios
repositories) and runs shellcheck on every shell script. Both are required on `main`, and PRs are
squash-merged with the PR title as the commit title.

## License

The scripts and packaging in this repository are CC0-1.0 (`LICENSE`). The software they build
keeps its own licenses (FFmpeg with libx264: GPL-2.0-or-later; srtla: AGPL-3.0).
