# SideTNFS GEMDRIVE

> **This repository is part of [SideTNFS-Firmware](https://github.com/RetroLoft/SideTNFS-Firmware).** It is not a standalone product: it builds `GEMDRIVE.BIN`, and the firmware repository embeds that exact binary into the Pico's own flash memory as a C word array, so it can hand it to the Atari as the boot-time GEMDOS hard-disk driver. See [How this gets into the firmware](#how-this-gets-into-the-firmware) below for the full picture.

## What this is

GEMDRIVE is the 68000 assembly ROM that turns a SideTNFS Raspberry Pi Pico cartridge into a **GEMDOS hard-disk emulator** for the Atari ST family. It's what makes drives like `C:`, `N:`, or the read-only Settings disk `S:` show up as ordinary GEMDOS drives at all — every `Fopen`, `Fread`, `Dsetpath`, directory listing, and so on that an Atari program issues against one of those drives is intercepted here and relayed to the Pico over the cartridge's own ROM3 bus, which then serves it from whichever backend that drive is configured for (a TNFS network share, a microSD card, or the built-in Settings disk). Any unmodified GEMDOS software just sees a hard disk.

This is a different kind of component from [SideTNFS-Config](https://github.com/RetroLoft/SideTNFS-Config): that repository builds `SIDETNFS.PRG`, an ordinary GEM application you launch from the desktop to *configure* drives. This repository builds the driver that makes configured drives *work* in the first place, and it runs automatically at boot — there is nothing to launch.

The source in `src/` is split into:

- **`gemdrive.s`** — the driver itself: the GEMDOS hard-disk emulation logic and the calls to the Multi-device over the cartridge bus.
- **`main.s`** — the bootstrap ROM: a standard SidecarTridge cartridge header (magic number `$abcdef42` at `$FA0000`, name, timestamp, entry point, ...) that embeds the driver and starts it after GEMDOS init, before the Atari boots from disk. This is what actually gets linked into `GEMDRIVE.BIN`.
- **`gemdrive_prg.s`** — a normal GEMDOS `.PRG` wrapper around the same driver, used only to test the driver's logic in an emulator (e.g. Hatari) without needing real SidecarTridge hardware. See [Testing without hardware](#testing-without-hardware) below.
- **`inc/`** — shared TOS constants, SidecarTridge hardware macros (`send_sync` and friends, for talking to the Multi-device), and debug helpers (Hatari Natfeats logging) used by the files above.

**A cartridge ROM image, not a `.PRG`:** building `main.s` + `gemdrive.s` produces `GEMDRIVE.BIN`, a raw 68000 ROM binary (linked with vlink's `-brawbin1` format) containing the cartridge header and driver code back to back. It is not a GEMDOS executable and can't be copied to a disk and run — it only makes sense mapped into the Pico's cartridge-ROM emulation address space, which is exactly what `SideTNFS-Firmware` does with it.

## Requirements

Building `GEMDRIVE.BIN` needs a 68000 **assembler and linker**, not a C compiler — this repository is pure 68000 assembly, so the `m68k-atari-mint-gcc` cross-compiler that [SideTNFS-Config](https://github.com/RetroLoft/SideTNFS-Config) needs for its C code is not involved here at all.

- **Toolchain: `vasm`/`vasmm68k_mot` (a Devpac-compatible 68000 assembler) and `vlink` (its matching linker)**, invoked as `vasm`/`vlink` from the `Makefile`s. Neither has a native Debian/Ubuntu package with 68000 support — the practical way to get them is:

  **[`atarist-toolkit-docker`](https://github.com/sidecartridge/atarist-toolkit-docker)** — a Docker image bundling `vasm`/`vlink` (plus `m68k-atari-mint-gcc`, unused by this repo) for Atari ST development, from the same `sidecartridge`/RetroLoft project family. It's driven through a small `stcmd` wrapper that runs commands inside the container:
  ```
  # Linux/macOS installer
  curl -sL https://github.com/sidecartridge/atarist-toolkit-docker/releases/download/latest/install_atarist_toolkit_docker.sh | bash

  # Windows: download and run from the releases page
  # https://github.com/sidecartridge/atarist-toolkit-docker/releases/latest
  #   install_atarist_toolkit_docker.cmd
  ```
  `stcmd` needs `ST_WORKING_FOLDER` set to the absolute path of this repository's checkout — it's the folder mounted into the container:
  ```
  cd path/to/SideTNFS-Gemdrive
  export ST_WORKING_FOLDER=`pwd`
  ```
  From there, every build command below is run as `stcmd <command>` instead of bare `<command>`.

- An Atari ST/STE/MegaST/MegaSTE, or an emulator such as [Hatari](https://hatari.tuxfamily.org/) for the assembly-level testing described in [Testing without hardware](#testing-without-hardware) — GEMDRIVE's actual drive emulation can only be exercised with real (or SidecarTridge-emulated) firmware behind it, so an emulator alone can't test the full round trip.

- A `git` client and a Makefile-compatible `make`.

## Build

```
./build.sh <ST_WORKING_FOLDER> release
```

It builds via `stcmd`, then produces two files in `dist/`:

- **`GEMDRIVE.BIN`** — the ROM image that gets embedded into `SideTNFS-Firmware` (see below).
- **`GEMDRIVE.IMG`** — the same bytes, padded/truncated to a flat 64 KB, for loading directly in an emulator instead of through real SidecarTridge hardware.

Equivalent by hand, without the wrapper script:
```
export ST_WORKING_FOLDER=`pwd`
stcmd make DEBUG_MODE=0 RELEASE_MODE=1
```

> **Note:** the top-level `Makefile` also has a `DEBUG_MODE=1` route (`Makefile.debug`), but that file is leftover from a different SidecarTridge sub-project and references source files (`rtc.s`, `rtc_prg.s`) that don't exist in this repository — don't pass `DEBUG_MODE=1`. The two combinations documented on this page are the ones that actually build.

## Testing without hardware

For iterating on the driver logic itself without a real Atari or SidecarTridge cartridge, `gemdrive_prg.s` links the same `gemdrive.s` driver into an ordinary `.TOS` program instead of a cartridge ROM, runnable directly in an emulator:

```
export ST_WORKING_FOLDER=`pwd`
stcmd make
```

(no `DEBUG_MODE`/`RELEASE_MODE` given routes to `Makefile.tos`, which links `gemdrive_prg.s` + `gemdrive.s`.) The result is `dist/BOOT.TOS`. In Hatari:

```
hatari --fast-boot true --tos-res med dist/BOOT.TOS
```

This still needs a running Multi-device to talk to for any actual drive emulation to succeed — it saves you the cartridge-boot cycle while working on the driver, not a full offline test.

## How this gets into the firmware

`SideTNFS-Firmware`'s `romemul/download_gemdrvemul.py` turns `GEMDRIVE.BIN` into `romemul/firmware_gemdrvemul.c` — a `const uint16_t gemdrvemulROM[]` array, 16 bits per entry to match the 68000's word bus, compiled straight into the Pico firmware image (wired in via `romemul/CMakeLists.txt`). That generated file is committed to the firmware repo directly — the script isn't run automatically by CI — so offline builds of the firmware stay reproducible.

Unlike `SideTNFS-Config`'s generator, this script's `--input` doesn't default to pulling from this repository's own GitHub releases; it still points at the original upstream project's release asset. In practice, regenerating it means building locally and pointing `--input` at that local file.

### Getting your own modified `GEMDRIVE.BIN` into the firmware

1. **Build your modified ROM** in this repository (see [Build](#build) above) — you need `dist/GEMDRIVE.BIN`.

2. **Regenerate the embedded C array** from a checkout of `SideTNFS-Firmware`, pointing the generator at your local build:

   ```
   cd SideTNFS-Firmware/romemul
   python3 download_gemdrvemul.py --input ../../SideTNFS-Gemdrive/dist/GEMDRIVE.BIN
   ```

   (Adjust the relative path if the two repositories aren't checked out next to each other.) This overwrites `romemul/firmware_gemdrvemul.c` with your build.

3. **Rebuild and flash the firmware** as usual — see `SideTNFS-Firmware`'s own `build.sh`/README. The new GEMDRIVE ROM is now part of that firmware image.

## Releases

There is no CI for this repository — releases are cut manually. After bumping `version.txt` and building (see [Build](#build) above), tag the commit and publish `dist/GEMDRIVE.BIN` and `dist/GEMDRIVE.IMG` as release assets, e.g.:

```
git tag vX.Y.Z && git push origin vX.Y.Z
gh release create vX.Y.Z dist/GEMDRIVE.BIN dist/GEMDRIVE.IMG
```

See the [Releases page](https://github.com/RetroLoft/SideTNFS-Gemdrive/releases).

## Acknowledgements

This repository is a continuation of Diego Parrilla's original [`atarist-sidecart-gemdrive`](https://github.com/sidecartridge/atarist-sidecart-gemdrive), part of the wider [SidecarTridge](https://sidecartridge.com) project that SideTNFS builds on.

## License

The project is licensed under the GNU General Public License v3.0. The full license is accessible in the [LICENSE](LICENSE) file.
