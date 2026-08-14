# `.gnw` Package Format

The generator combines MAME program ROMs, artwork, LCD segment geometry, and optional sound data into one streamable package. Byte offsets in this document are absolute package offsets.

The first `0x325240` bytes retain the legacy layout. Version 2 adds feature flags and an optional `GNWX` directory inside the existing 256-byte header; payloads are appended without moving the legacy image, mask, or ROM offsets. Current generated packages preserve those legacy payload bytes, update the header metadata, and add native `360x240` artwork and masks so one package supports both video modes.

## Fixed Layout

| Offset | Size | Contents |
| --- | ---: | --- |
| `0x000000` | `0x100` | Configuration header |
| `0x000100` | `0x2F7600` | Legacy/native `720x720` paired RGB image |
| `0x2F7700` | `0x2DB40` | Legacy `720x720` LCD mask RLE |
| `0x325240` | variable | CPU program ROM |
| `0x326240` | `0x100` | SM511/SM512/SM530/SM511 Tiger melody ROM, when present |
| `0x326340` | `0x10000` | V2 sample-backed voice bank, when present |
| `0x336400` | `0x80` | Star Fox HA1152/HMC effect ROM, when present |
| `0x336500` | `0x7E900` | Native CRT `360x240` paired RGB image |
| `0x3B4E00` | `0x7E900` | Required zero gap retained by the fixed extension ABI |
| `0x433700` | `0xF3C0` | Native CRT LCD mask RLE capacity |
| `0x442AC0` | - | End of every current dual-resolution package |

The reserved image-to-mask gap and the unused tail of the fixed CRT-mask capacity are zero-filled.

## Configuration Header

Versions 1 and 2 share the fixed fields below. Multi-byte size, offset, length, width, and height fields are little-endian.

```text
0x00  format version
0x01  MPU ID
0x02  screen configuration
0x03  legacy screen width[9:0] and height[9:0], packed into 24 bits
0x06  two reserved zero bytes
0x08  input mapping, 36 bytes
      S0.0..S7.3, B, BA, ACL, grounded S-row index
0x2C  four reserved zero bytes
0x30  V2 feature flags
0x31  optional GNWX extension directory
0xF9  generator commit prefix: seven lowercase ASCII hex bytes, or "unknown"
```

The provenance field never contains a build-tool sentinel. If a Git commit cannot be determined, the generator writes the explicit seven-byte value `unknown`. The current regenerated packages contain `2600ff1`, which was the committed `HEAD` while they were generated from a large dirty worktree. It identifies the nearest committed revision only; it does not mean the generator, RTL, or package changes described here are present in commit `2600ff1`.

### Feature Flags

| Bit | Value | Meaning |
| ---: | ---: | --- |
| 0 | `0x01` | Sample-backed MSM6373 voice bank |
| 1 | `0x02` | HA1152/HMC effect ROM |
| 2 | `0x04` | Player-two electrical-cell ownership mask |
| 3 | `0x08` | Native CRT image payload |
| 4 | `0x10` | Native CRT mask payload |
| 7 | `0x80` | `GNWX` extension directory present |

Bits 3 and 4 are a pair. The core enables the native CRT asset bank only when both canonical descriptors and both complete payload streams validate.

Voice-only V2 packages produced before `GNWX` remain compatible. A current dual-resolution package necessarily has a directory; when it also contains voice data, the directory includes a voice descriptor.

### GNWX Extension Directory

```text
0x31  magic "GNWX"
0x35  directory revision 1
0x36  descriptor size 0x10
0x37  descriptor count, 0..11
0x38  player-two ownership mask, 5 bytes
0x3D  three reserved zero bytes
0x40  descriptors, 16 bytes each
```

Each descriptor is:

```text
+0x00  payload kind
+0x01  encoding
+0x02  variant
+0x03  reserved zero
+0x04  absolute package offset, u32
+0x08  payload length, u32
+0x0C  logical width, u16
+0x0E  logical height, u16
```

Canonical descriptors currently emitted by the generator are:

| Kind | Encoding / variant | Offset | Length | Dimensions |
| ---: | --- | ---: | ---: | ---: |
| `0x01` voice | raw / V1 | `0x326340` | `0x10000` | 0 x 0 |
| `0x02` HMC | raw / HA1152 | `0x336400` | `0x80` | 0 x 0 |
| `0x10` CRT image | raw / component-paired RGB | `0x336500` | `0x7E900` | 360 x 240 |
| `0x11` CRT mask | RLE40 / V1 | `0x433700` | used bytes through terminator | 360 x 240 |

Unknown future descriptor kinds do not enable a current payload. At runtime the RTL validates the directory magic/revision/descriptor size/count, the common reserved byte of each in-count descriptor, and the complete canonical fields for the HMC and two CRT descriptor kinds. CRT selection additionally requires both feature bits, complete in-order streams for the fixed image and mask regions, an all-zero image-to-mask gap, valid sorted/in-bounds/non-overlapping mask runs, the explicit terminator, and the zero mask tail. The fixed-offset V2 voice path does not depend on a runtime voice-descriptor validator, and unknown descriptor payloads are not otherwise interpreted. The generator's offline `--validate-packages` pass performs the broader whole-package inventory, header, hash, descriptor, bounds, and padding checks.

## MPU

| MPU | Value |
| --- | ---: |
| SM510 | `0x0` |
| SM511 | `0x1` |
| SM512 | `0x2` |
| SM530 | `0x3` |
| SM5a | `0x4` |
| SM510 + Tiger | `0x5` |
| SM511 + Tiger 1 bit | `0x6` |
| SM511 + Tiger 2 bit | `0x7` |
| KB1013VK12 | `0x8` |

## Screen Configuration

| Screen configuration | Value |
| --- | ---: |
| Single screen | `0x0` |
| Dual vertical | `0x1` |
| Dual horizontal | `0x2` |
| Triple horizontal | `0x3` |

The legacy 24-bit size payload packs screen width in bits 0-9 and screen height in bits 10-19; bits 20-23 are zero. The RTL retains wider decoded fields for compatibility, but rendering uses the actual per-screen SVG bounds. Triple-horizontal packages store the middle screen size in this legacy field.

## Input Mapping

Each electrical input cell has one byte:

```text
[active low: 1 bit][semantic input identifier: 7 bits]
```

The 36 mapped bytes describe eight four-bit `S` rows followed by `B`, `BA`, `ACL`, and the grounded-row index. The grounded index is zero when unset and otherwise stores the one-based `S` row number.

The unused action is `0x7F`. Its active-low form `0xFF` is the established representation for electrically pulled-up B/BA pins. ACL is canonicalized to `0x7F`; the core also accepts legacy `0xFF` ACL as absent and inactive.

| Input name | Value |
| --- | ---: |
| JoyUp | 0 |
| JoyDown | 1 |
| JoyLeft | 2 |
| JoyRight | 3 |
| Button1 | 4 |
| Button2 | 5 |
| Button3 | 6 |
| Button4 | 7 |
| Button5 | 8 |
| Button6 | 9 |
| Button7 | 10 |
| Button8 | 11 |
| Select (typically Time) | 12 |
| Start1 (Game A) | 13 |
| Start2 (Game B) | 14 |
| Service1 | 15 |
| Service2 | 16 |
| Service3 (Service1 alias) | 15 |
| LeftJoyUp | 17 |
| LeftJoyDown | 18 |
| LeftJoyLeft | 19 |
| LeftJoyRight | 20 |
| RightJoyUp | 21 |
| RightJoyDown | 22 |
| RightJoyLeft | 23 |
| RightJoyRight | 24 |
| VolumeDown | 25 |
| PowerOn | 26 |
| PowerOff | 27 |
| Keypad | 28 |
| Custom | 29 |
| CustomUpDown | 30 |
| CustomButtonHour | 31 |
| Dial | 32 |
| Service4 (typically Minute) | 33 |
| Mark unused | `0x7F` |

Generator versions predating the dedicated Service4 value encoded Service4 as 16, making it indistinguishable from Service2/Alarm. Value 16 remains Service2 so old packages retain their established behavior; newly generated packages use 33 when a distinct Service4/Minute input is present.

The capability-filtered 168-title MAME 0.289-derived set, including two retained homebrew entries, fits the core's D-pad plus ten-button resolver. Keyboard/keypad matrices, dial input, and layouts beyond that contract are not emitted by the `supported` filter.

### Player-Two Ownership

The five bytes at `0x38-0x3C` are a little-endian bit-per-cell ownership map: S0.0 through S7.3, then B, BA, ACL, followed by five reserved zero bits. A set bit selects MiSTer's `joystick_1` controls for that electrical cell; a clear bit selects `joystick_0`. This preserves shared wiring while allowing only the original player-two cells to use the second controller.

Current `gnw_boxing`, `gnw_dkong3`, and `gnw_dkhockey` packages all encode `04 0C 0C 00 00`. They are V2 packages with feature bits 2 and 7 set. P2-only packages may legally have a directory count of zero because the ownership map is header metadata rather than an appended payload. Older packages without valid ownership metadata resolve every cell from player one.

## Image Payloads

Both image payloads store six bytes per pixel:

```text
background R, active-LCD R,
background G, active-LCD G,
background B, active-LCD B
```

The background byte is the low byte of each component pair consumed by the FPGA. The native image is `720x720`; the CRT image is `360x240`.

## LCD Mask RLE

Each 40-bit, little-endian entry is:

```text
bits  0.. 9  LCD segment ID
bits 10..19  run start X
bits 20..29  run Y
bits 30..39  run length

segment ID = [row/z:2][column/y:4][line/x:4]
```

The legacy mask region is fixed at `0x2DB40` bytes. The CRT mask region has `0xF3C0` bytes of physical capacity. Its descriptor length includes one explicit all-zero 40-bit terminator; every byte after that terminator is zero. CRT runs must be positive-length, in bounds, row-major sorted, and non-overlapping.

The runtime CRT-mask descriptor check accepts a used length from 5 through `0xF3C0` bytes only when it is divisible by five. The synthesizable test uses the sum of the four hexadecimal digits (`16 mod 5 = 1`) instead of a `% 5` divider; the focused loader regression proves equivalence for all 65,536 possible 16-bit values and completes 65,555 checks overall.

## ROM and Sound Payloads

The CPU program starts at `0x325240`. SM510 and SM5a retain their legacy variable program length. SM511, SM512, SM530, and the SM511 Tiger variants pad the program area to `0x1000` bytes and append the 256-byte melody ROM at `0x326240`.

### Sample-Backed Voice Bank

Feature bit 0 appends a fixed 64 KiB bank at `0x326340`. It models the observable MSM6373 phrase interface used by `ktmnt2`, `kst25`, and `ktopgun2` from preserved sample packs. It is not a dump of any original per-game MSM6373 internal mask ROM.

```text
0x0000  magic "GWAU"
0x0004  bank version 1
0x0005  codec 1: OKI ADPCM4, high nibble first
0x0006  sample rate 8000 Hz, little-endian u16
0x0008  32 directory slots
0x0009  reserved zero
0x000A  payload byte count, little-endian u16
0x000C  four reserved zero bytes
0x0010  32 entries: [payload-relative start u16][ADPCM nibble count u16]
0x0100  encoded payload
```

Slot zero is stop/empty. Slots 1-31 correspond directly to the five-bit phrase command latched from S1-S5. Empty entries are intentional command holes. The FPGA provides active-low busy feedback and mixes decoded voice audio with the normal piezo output.

### Star Fox HA1152/HMC ROM

Feature bit 1 and the canonical HMC descriptor identify the exact 128-byte `ha1152_001a` ROM at `0x336400` (SHA-1 `5dfb15eee3c57bbca80f485f68442e5f7c6bc5e4`). This is the dumped effect program used by Nelsonic Star Fox, not synthesized replacement content. The core interprets it with the trace-derived HA1152 sequencer documented in [SM530 Support Notes](sm530.md).
