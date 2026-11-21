# helios-packages

Debian packages of the third-party software Helios devices need, built for each board's
hardware and published to the Helios APT repository (helios-cloud's `AptRepository` stack),
next to the `helios` package itself.

| Package | Board | Contents |
| --- | --- | --- |
| `helios-ffmpeg-rpi5` | Raspberry Pi 5 (Pi OS Trixie) | FFmpeg with the Raspberry Pi patch set (V4L2 request HEVC decode, DRM/EGL output), libx264, libsrt |
| `helios-ffmpeg-rk3588` | Orange Pi 5 Plus (Armbian Trixie, vendor kernel 6.1) | FFmpeg with Rockchip MPP encode/decode and RGA, libx264, libsrt |
| `helios-srtla` | any arm64 | BELABOX srtla (`srtla_send`, `srtla_rec`) |

## Plan

- Each FFmpeg package installs to `/usr/lib/helios-ffmpeg/{bin,lib}` with an rpath, so it never
  clashes with the distribution's FFmpeg, and both provide `helios-ffmpeg` and conflict with each
  other. Helios's video module uses the same path on every board.
- Builds run in a container of the target's Debian release (Trixie, glibc 2.41), cross-compiling
  with Debian's multiarch toolchain; `dpkg-shlibdeps` sets the runtime dependencies.
- Releases are tagged per package (for example `ffmpeg-rpi5/9.0.2-1`) and published to the
  `trixie` suite, in a component per board (`rpi5`, `rk3588`) plus `main` for board-independent
  packages, signed with the Helios APT archive key. A board's APT sources list `stable main`
  (Helios) and `trixie main <board>`.
- The FFmpeg builds are GPL (libx264): this public repository holds the scripts and patches,
  and each release also publishes its source.

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
