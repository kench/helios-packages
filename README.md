# helios-packages

Debian packages of the third-party software Helios devices need, built for each board's
hardware and published to the Helios APT repository (helios-cloud's `AptRepository` stack),
next to the `helios` package itself.

| Package | Board | Contents |
| --- | --- | --- |
| `helios-ffmpeg-rpi5` | Raspberry Pi 5 (Pi OS Trixie) | FFmpeg with the Raspberry Pi patch set (V4L2 request HEVC decode, DRM/EGL output), libx264, libsrt |
| `helios-ffmpeg-rk3588` | Orange Pi 5 Plus (Armbian Trixie, vendor kernel 6.1) | FFmpeg with Rockchip MPP encode/decode and RGA, libx264, libsrt |
| `helios-srtla-send` | any arm64 | irlserver [srtla_send](https://github.com/irlserver/srtla_send) (MIT), the SRTLA bonding sender, as `/usr/bin/srtla_send`. **Packaged** (`4.1.0-1`) |
| `helios-srtla` | any arm64 | BELABOX srtla (`srtla_send`, `srtla_rec`), if still needed; its `srtla_send` would install aside, under `/usr/lib/helios-srtla/` |

## Status

`helios-srtla-send` is packaged; the FFmpeg builds are next. `AGENTS.md` lists the next steps
for each package.

## Packages and releases

Each package is a folder with `package.env` (name, version, pinned upstream tag and commit,
suite, component, target) and `build.sh`, which fetches the pinned upstream source, checks the
commit, builds it and writes `out/<package>_<version>_<arch>.deb`:

```sh
./helios-srtla-send/build.sh        # needs rustup, cargo-zigbuild and zig 0.14.1, readelf, dpkg-deb
```

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

- Each FFmpeg package installs to `/usr/lib/helios-ffmpeg/{bin,lib}` with an rpath, so it never
  clashes with the distribution's FFmpeg, and both provide `helios-ffmpeg` and conflict with each
  other. Helios's video module uses the same path on every board.
- Builds run in a container of the target's Debian release (Trixie, glibc 2.41), cross-compiling
  with Debian's multiarch toolchain; `dpkg-shlibdeps` sets the runtime dependencies.
- Releases are tagged per package (for example `helios-ffmpeg-rpi5/9.0.2-1`) and published to the
  `trixie` suite, in a component per board (`rpi5`, `rk3588`) plus `main` for board-independent
  packages, signed with this repository's own key (above).
- The FFmpeg builds are GPL (libx264): this public repository holds the scripts and patches,
  and each release also publishes its source.

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
keeps its own licenses (FFmpeg with libx264: GPL-2.0-or-later; srtla: AGPL-3.0).
