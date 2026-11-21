# AGENTS.md

helios-packages builds the board-specific software Helios devices need as Debian packages and
publishes them to the Helios APT repository (helios-cloud's `AptRepository` stack), next to the
`helios` package that kench/helios publishes. `README.md` has the plan: `helios-ffmpeg-rpi5`,
`helios-ffmpeg-rk3588` and `helios-srtla`. Current status is in the Notion page "Helios -
Project Status and Handoff"; the boards are in "Hardware Deployment Information".

## Status (2026-11-21)

Repository created with the plan only; nothing is packaged yet. Next:

1. `helios-ffmpeg-rpi5`: bring over the cross-build from kench/raspberry-pi-5-tools (FFmpeg
   9.0.2 with the Raspberry Pi patches, x264, SRT), installed to `/usr/lib/helios-ffmpeg` with
   an rpath, built in a `debian:trixie` container, `Depends` from `dpkg-shlibdeps`.
2. `helios-ffmpeg-rk3588`: FFmpeg with Rockchip MPP and RGA for the Orange Pi 5 Plus on Armbian
   Trixie with the vendor kernel (6.1). MPP and RGA aren't in Debian, so they're bundled or
   packaged here.
3. `helios-srtla`: BELABOX srtla for arm64.
4. A release workflow on per-package tags that publishes to the `trixie` suite, a component per
   board (`rpi5`, `rk3588`, plus `main`), signed with the Helios APT archive key. That needs
   helios-cloud's `helios-apt-publisher` role to trust this repository's tags (a helios-cloud
   change and deploy, with the owner's OK), the `APT_SIGNING_KEY` secret here, and
   kench/helios's `.github/scripts/build-apt-repo.sh` adapted to one suite and component.

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
