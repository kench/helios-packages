# AGENTS.md

helios-packages builds the board-specific software Helios devices need as Debian packages and
publishes them to the Helios APT repository (helios-cloud's `AptRepository` stack), next to the
`helios` package that kench/helios publishes. `README.md` has the plan: `helios-ffmpeg-rpi5`,
`helios-ffmpeg-rk3588` and `helios-srtla`. Current status is in the Notion page "Helios -
Project Status and Handoff"; the boards are in "Hardware Deployment Information".

## Status (2026-11-21)

- `helios-srtla-send` (irlserver srtla_send 4.1.0, MIT) is packaged: `helios-srtla-send/build.sh`.
- Publishing works end to end in local tests: `.github/workflows/release.yml` on tags
  `<package>/<version>`, `.github/scripts/build-apt-repo.sh` for the `trixie` suite, signed with
  this repository's own key (`APT_SIGNING_KEY`, fingerprint
  `328F19E1F0AAA7B143E1017F7135FAE9F8FE4181`). It needs helios-cloud's
  `helios-packages-publisher` role deployed; the repository variables are set.

Next:

1. `helios-ffmpeg-rpi5`: bring over the cross-build from kench/raspberry-pi-5-tools (FFmpeg
   9.0.2 with the Raspberry Pi patches, x264, SRT), installed to `/usr/lib/helios-ffmpeg` with
   an rpath, built in a `debian:trixie` container, `Depends` from `dpkg-shlibdeps`.
2. `helios-ffmpeg-rk3588`: FFmpeg with Rockchip MPP and RGA for the Orange Pi 5 Plus on Armbian
   Trixie with the vendor kernel (6.1). MPP and RGA aren't in Debian, so they're bundled or
   packaged here.
3. BELABOX srtla (`helios-srtla`) only if it's still wanted next to irlserver's sender.

## FFmpeg build flags

Use the per-board flags in the README's "FFmpeg build flags" section (`--cpu=cortex-a76` for the
Pi 5, `--cpu=cortex-a76.cortex-a55` for the RK3588, default `-O3`, Debian's hardening flags).
Never target a newer CPU than the board's, and don't add `+crypto`, `i8mm` or SVE to the C
flags: FFmpeg's assembly picks those at run time. Verify on the board before the first release
(`/proc/cpuinfo`, `checkasm`, a benchmark with and without LTO).

## Adding a package

A folder named after the package with `package.env` (`NAME`, `VERSION`, the pinned upstream tag
and commit, `SUITE`, `COMPONENT`, target) and an executable `build.sh [OUT_DIR]` that verifies
the upstream commit, builds, checks the result and writes `<package>_<version>_<arch>.deb`. The
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
