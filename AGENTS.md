# AGENTS.md

helios-packages builds the board-specific software Helios devices need as Debian packages and
publishes them to the Helios APT repository (helios-cloud's `AptRepository` stack), next to the
`helios` package that kench/helios publishes. `README.md` has the plan: `helios-ffmpeg-rpi5`,
`helios-ffmpeg-rk3588` and `helios-srtla`. Current status is in the Notion page "Helios -
Project Status and Handoff"; the boards are in "Hardware Deployment Information".

## Status (2026-11-21)

- `helios-srtla-send` (irlserver srtla_send 4.1.0, MIT) is packaged and published (`4.1.0-1`).
- `helios-ffmpeg-rk3588` (FFmpeg 9.0.2 + ffmpeg-rockchip, MPP and RGA static, x264, SRT,
  RTMPS): the recipe builds in CI on `ubuntu-24.04-arm`; not released until it's verified on the
  Orange Pi (README: "helios-ffmpeg-rk3588").
- Publishing works end to end in local tests: `.github/workflows/release.yml` on tags
  `<package>/<version>`, `.github/scripts/build-apt-repo.sh` for the `trixie` suite, signed with
  this repository's own key (`APT_SIGNING_KEY`, fingerprint
  `328F19E1F0AAA7B143E1017F7135FAE9F8FE4181`). It needs helios-cloud's
  `helios-packages-publisher` role deployed; the repository variables are set.

Next:

1. `helios-ffmpeg-rpi5`: bring over the build from kench/raspberry-pi-5-tools (FFmpeg 9.0.2
   with the Raspberry Pi patches, x264, SRT, plus GnuTLS for RTMPS like the RK3588 build) the
   same way as `helios-ffmpeg-rk3588`: native arm64 in `debian:trixie`, `/usr/lib/helios-ffmpeg`.
2. `helios-ffmpeg-rk3588`: verify on the Orange Pi, then release `helios-ffmpeg-rk3588/9.0.2-1`;
   boards with an RK3588 add the `rk3588` component.
3. BELABOX srtla (`helios-srtla`) only if it's still wanted next to irlserver's sender.

## FFmpeg build flags

Use the per-board flags in the README's "FFmpeg build flags" section (`--cpu=cortex-a76` for the
Pi 5, `--cpu=cortex-a76.cortex-a55` for the RK3588, default `-O3`, Debian's hardening flags).
Never target a newer CPU than the board's, and don't add `+crypto`, `i8mm` or SVE to the C
flags: FFmpeg's assembly picks those at run time. Verify on the board before the first release
(`/proc/cpuinfo`, `checkasm`, a benchmark with and without LTO).

## Adding a package

A folder named after the package with `package.env` (`NAME`, `VERSION`, the pinned upstream tag
and commit, `SUITE`, `COMPONENT`, target; `BUILD_RUNNER`, `BUILD_CONTAINER` (pinned by digest)
and `BUILD_DEPS` for container builds; `BUILD_TOOLS=zigbuild` for host Rust builds) and an
executable `build.sh [OUT_DIR]` that verifies every upstream commit, builds, checks the result
and writes `<package>_<version>_<arch>.deb`, plus `<package>_<version>_source.tar.xz` for GPL
packages (published next to it). Build with `.github/scripts/build-package.sh <package>`. The
release tag is `<package>/<version>`. Never publish a version twice with different contents.

## Targets

| Board | OS | glibc | Notes |
| --- | --- | --- | --- |
| Raspberry Pi 5 (relay) | Raspberry Pi OS Trixie, arm64 | 2.41 | Cortex-A76; no hardware H.264 encoder (x264) |
| Orange Pi 5 Plus (transcoder) | Armbian 26.8.2 Trixie, vendor kernel 6.1.115, arm64 | 2.41 | RK3588; MPP hardware encode/decode needs the vendor kernel |

## Rules

- Conventional Commits for commits and PR titles; squash merges; branch first.
- This repository is public: never add keys, tokens, licensed fonts or vendor files.
- FFmpeg with libx264 is GPL and srtla is AGPL-3.0: every release publishes its source (upstream
  refs, patches, build scripts).
- Packages never restart services on upgrade; Helios's video module decides when streams start.
