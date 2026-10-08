# F36 integration and F37 configuration candidate

These are coordinated source submissions to RetroLoft/SideTNFS-Firmware,
RetroLoft/SideTNFS-Gemdrive and RetroLoft/SideTNFS-Config. Firmware and
GEMDRIVE use the native protocol together; use the matching Config changes.
The legacy upstream build remains the default. Historical Falcon names in
build switches also cover the tested Mega STE setup. Native firmware is
restricted to Pico W / RP2040; Pico 2 W is not claimed.

F36 was hardware-tested by the user on Mega STE: HighWire launches from the
TNFS mapping after accepting its 0x17 PRG flags. Earlier checkpoints cover
Falcon/HDDRIVER/BlueSCSI coexistence and Mega STE standalone boot. These are
specific observations, not a claim that every configuration is validated.
F37 embeds Config rebased onto current upstream, retaining upstream's wait
notice and initial Wi-Fi setup alongside our cartridge transport and AES
window fixes. F37 settings/status/edit/save/reopen needs hardware validation.

Historical docs describe individual bring-up stages; this document states
current submission scope. Raw UART captures and old binary kits are excluded.

## Guest scope

Source-built 68000 resident driver and cartridge ROM, late drive/cookie
publication, filesystem routing, settings access, native TOS program handoff,
shared SIDEETH bus gate and diagnostic recorder. PRG loading accepts the four
documented protection modes as metadata on plain TOS; unsupported modes,
shared library/text flags and malformed relocation streams remain rejected.

Build: python3 tools/build_native.py (or make falcon). The offline Docker
image must supply m68k-atari-mint-gcc, vasm, vlink and python3. Set
SIDETNFS_TOOLCHAIN_IMAGE to the cached image; default 304fea9c3e8e is the
historical local toolchain. Output goes to dist/native (not tracked).
Run companion Firmware tools/test_native.py with SIDETNFS_GUEST_DIR pointing
here. It includes tests/native/test_program_loader.c and test_r14_driver.c.
Build tests execute the emitted ROM copy/clear loops and validate relocations.
