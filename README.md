# helios-packages

Debian packages of the third-party software Helios devices need, built for each board's
hardware and published to the Helios APT repository (helios-cloud's `AptRepository` stack),
next to the `helios` package itself.

| Package | Board | Contents |
| --- | --- | --- |
| `helios-ffmpeg-rpi5` | Raspberry Pi 5 (Pi OS Trixie) | FFmpeg with the Raspberry Pi patch set (V4L2 request HEVC decode, DRM/EGL output), libx264, libsrt |
| `helios-ffmpeg-rk3588` | Orange Pi 5 Plus (Armbian Trixie, vendor kernel 6.1) | FFmpeg 9.0.2 with [nyanmisaka/ffmpeg-rockchip](https://github.com/nyanmisaka/ffmpeg-rockchip)'s patches: Rockchip MPP hardware decode (H.264, HEVC, VP9, AV1) and encode (H.264, HEVC), RGA scale/crop/overlay, libx264, libsrt, RTMP/RTMPS (GnuTLS). **Released** (`9.0.2-1`, component `rk3588`) |
| `helios-gst-rockchip-rk3588` | Orange Pi 5 Plus | [BELABOX/gstreamer-rockchip](https://github.com/BELABOX/gstreamer-rockchip) (LGPL-2.1): the Rockchip MPP GStreamer elements (`mpph264enc`, `mpph265enc` with bitrate changes while running, `mppvideodec`, `mppjpegdec`), MPP and RGA static, in the private plugin directory `/usr/lib/helios-gst/gstreamer-1.0`; plus a GCC 14 build fix. Component `rk3588` |
| `helios-belacoder` | any arm64 | [BELABOX/belacoder](https://github.com/BELABOX/belacoder) (GPL-3.0), the GStreamer SRT encoder with adaptive bitrate, as `/usr/bin/belacoder`; plus `-p` for an SRT passphrase |
| `helios-ceracoder` | any arm64 | [ceralive/ceracoder](https://github.com/ceralive/ceracoder) (GPL-3.0), belacoder's fork with a choice of bitrate algorithms, as `/usr/bin/ceracoder`; plus `-p`, and setting the bitrate through the encoder's `bps` or `bitrate` property (BELABOX's plugin and `x264enc` have `bitrate`) |
| `helios-srtla-send` | any arm64 | irlserver [srtla_send](https://github.com/irlserver/srtla_send) (MIT), the SRTLA bonding sender, as `/usr/bin/srtla_send`. **Packaged** (`4.1.0-1`) |

## Status

`helios-srtla-send` and `helios-ffmpeg-rk3588` are released. The adaptive bitrate encoders
(`helios-gst-rockchip-rk3588`, `helios-belacoder`, `helios-ceracoder`) were proven on the Orange
Pi by a build on the board (Notion: "Helios - Adaptive Bitrate Spike"); their recipes build in CI.
`helios-ffmpeg-rpi5` is next. `AGENTS.md` lists the next steps for each package.

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
- **Tested on the Orange Pi 5 Plus (2026-11-21, Armbian 26.8.2, kernel 6.1.115-vendor):** as a
  `video` user, 10 s of 1080p H.264 in each case, all frames out: decode → `scale_rkrga` 720p →
  `hevc_rkmpp` in 0.59 s (about 17× real time, 0.4 s of CPU); `h264_rkmpp` at 1080p30 in 0.78 s;
  **1080p60 → `hevc_rkmpp` 1080p60 in 1.33 s (7.5× real time)**; software `libx264 veryfast` for
  comparison: 5.7 s and 23 s of CPU. The CPU's features match the build flags (plus the crypto
  extension). Found: `/dev/mpp_service` is in subsystem `mpp_class`, so `postinst` now triggers
  udev by device name too (verified on the board). Not run yet: `checkasm` on the board, and the
  LTO comparison.
- **On the board, before the first release:** the encoder and RGA on real video (for example
  `ffmpeg -hwaccel rkmpp -hwaccel_output_format drm_prime -i in.mp4 -vf scale_rkrga=w=1280:h=720
  -c:v h264_rkmpp out.mp4`), the device permissions as the `helios` user, `checkasm` on the
  RK3588, and the build flags (README: "FFmpeg build flags").

The Raspberry Pi 5 build comes from
[kench/raspberry-pi-5-tools](https://github.com/kench/raspberry-pi-5-tools).

## FFmpeg build flags

Decided 2026-11-21: the FFmpeg packages are built with the optimal flags for each board's CPU.
Checked against FFmpeg n9.0.2's `configure` and Debian Trixie's cross compiler
(`aarch64-linux-gnu-gcc` 14.2):

| | `helios-ffmpeg-rpi5` | `helios-ffmpeg-rk3588` |
| --- | --- | --- |
| CPU | BCM2712: 4× Cortex-A76 | RK3588: 4× Cortex-A76 + 4× Cortex-A55 (threads move between them) |
| `configure` | `--arch=aarch64 --cpu=cortex-a76` | `--arch=aarch64 --cpu=cortex-a76.cortex-a55` |
| Resulting C flags | `-mcpu=cortex-a76 -O3` | `-mcpu=cortex-a76.cortex-a55 -O3` (GCC's big.LITTLE tuning) |
| Instruction set used by C code | Armv8.2-A: LSE atomics, CRC32, dot product, FP16, RDM, RCpc | the same: identical on both core types |

- `--cpu=X` becomes `-mcpu=X` (`-march=X` for `armv*` values); FFmpeg's default optimization is
  `-O3`, kept.
- The hand-written assembly doesn't depend on `--cpu`: NEON, CRC, PMULL, dot product, i8mm and
  SVE/SVE2 code is always assembled, and `libavutil` picks it at run time from the CPU's hwcaps.
  Neither board has i8mm or SVE, so those paths stay unused. `--cpu` tunes and vectorizes the C
  code.
- The crypto extension (AES/SHA) is optional on these cores and isn't implied by `-mcpu`; FFmpeg's
  C code doesn't need it, so it isn't added.
- Debian's hardening flags are kept, as Debian builds FFmpeg (`-fstack-protector-strong`,
  `-D_FORTIFY_SOURCE=2`, `-fstack-clash-protection`, `-mbranch-protection=standard`: PAC/BTI
  instructions are no-ops on these cores), since FFmpeg parses streams from the network.
- `x264` and `libsrt` come from Debian (`libx264-dev`, `libsrt-gnutls-dev`): x264's speed is in
  its NEON assembly, which it selects at run time.
- Before a board's first release: compare its `/proc/cpuinfo` features with the table (expected:
  `asimd atomics crc32 asimddp asimdhp asimdrdm lrcpc`), run FFmpeg's `checkasm` on the board, and
  benchmark a fixed encode (`ffmpeg -benchmark`) with and without `--enable-lto` (keep LTO only if
  it's measurably faster).

## CI

`.github/workflows/ci.yml` checks that each PR title and commit subject follows Conventional
Commits (`.github/scripts/check-conventional-commit.sh`, the same rules as the other Helios
repositories) and runs shellcheck on every shell script. Both are required on `main`, and PRs are
squash-merged with the PR title as the commit title.

## License

The scripts and packaging in this repository are CC0-1.0 (`LICENSE`). The software they build
keeps its own licenses (FFmpeg with libx264: GPL-2.0-or-later; srtla: AGPL-3.0; belacoder and
ceracoder: GPL-3.0; gstreamer-rockchip: LGPL-2.1), and each GPL or LGPL release publishes its
source next to the package.
