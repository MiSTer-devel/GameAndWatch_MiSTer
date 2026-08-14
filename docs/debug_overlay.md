# Debug Overlay

The core has an optional OSD-controlled debug overlay for hardware testing without SignalTap.
It is modeled after the bring-up grid used in the Raizing/Toaplan debug passes, but all logic lives in Game & Watch-owned files. Normal and release builds leave `CORE_ENABLE_DEBUG_OVERLAY` undefined, so the debug menu entries, capture registers, and pixel-overlay logic are not synthesized.

To make a development build, temporarily enable the commented `CORE_ENABLE_DEBUG_OVERLAY=1` Verilog-macro assignment in `GameAndWatch.qsf`. Do not enable it in a release artifact.

## OSD Controls

- `Debug Video`: replaces normal video with the diagnostic panel.
- `Debug View`: selects which 8x8 grid to show.
  - `Events`: sticky package/load and CPU event flags.
  - `CPU`: live CPU state bits.
  - `Melody`: live SM511/SM512/SM530 melody-generator state.
  - `Core`: live core/package state.
- `Debug Freeze`: freezes the current debug grid values for manual transcription. Turn it off to resume live updates, then on again to capture a new snapshot.

In 720x720 mode, the panel uses the top-left 512x512 pixels and each cell is 64x64. In 360x240 CRT mode it uses the top-left 256x240 pixels and cells are 32x32; the eighth row is 16 pixels high because the active raster ends at line 239. Report lit cells as `row:column`, with rows and columns counted from 1 at the top left. For live CPU/Core snapshots, enable `Debug Freeze` before transcribing so the cells stay stable. Rows are drawn left-to-right as bit 0 through bit 7, so reverse a written row before treating it as a normal binary byte.

## Events View

Rows 1-2 are core/package sticky events from `rtl/gameandwatch.sv`.
Rows 3-8 are SM510-family CPU sticky events from `rtl/sm510.sv`.

| Cell | Meaning |
| --- | --- |
| 1:1 | Core reset released |
| 1:2 | IOCTL download active |
| 1:3 | Byte unpacker wrote a byte |
| 1:4 | Artwork/image write seen |
| 1:5 | Mask-config write seen |
| 1:6 | ROM-region write seen |
| 1:7 | Main program ROM write seen |
| 1:8 | Melody ROM write seen at appended `0x1000-0x10ff` ROM offset |
| 2:1 | CPU ID was SM511 |
| 2:2 | CPU ID was SM512 |
| 2:3 | CPU ID was SM530 |
| 2:4 | CPU ID was SM511 Tiger 1-bit or 2-bit |
| 2:5 | Nonzero program ROM data was read |
| 2:6 | Nonzero melody ROM data was read |
| 2:7 | Melody address changed |
| 2:8 | Audio bit toggled |
| 3:1 | CPU `clk_en` ticked |
| 3:2 | SM511-family decode path selected |
| 3:3 | CPU ID was SM511 |
| 3:4 | CPU ID was SM512 |
| 3:5 | CPU ID was SM511 Tiger 1-bit |
| 3:6 | CPU ID was SM511 Tiger 2-bit |
| 3:7 | Instruction clock enable ticked |
| 3:8 | PC changed |
| 4:1 | Stage `LOAD_PC` seen |
| 4:2 | Stage `DECODE_PERF_1` seen |
| 4:3 | Stage `LOAD_2` seen |
| 4:4 | Stage `PERF_3` seen |
| 4:5 | Stage `IDX_FETCH` seen |
| 4:6 | Stage `IDX_PERF` seen |
| 4:7 | Stage `HALT` seen |
| 4:8 | Halt wake condition seen |
| 5:1 | Opcode `0x60` seen |
| 5:2 | Opcode `0x61` seen |
| 5:3 | SM511 extended prefix reached second stage |
| 5:4 | SM511 `PRE` prefix reached second stage |
| 5:5 | `SME` executed |
| 5:6 | `RME` executed |
| 5:7 | `TMEL` executed |
| 5:8 | `PRE` executed |
| 6:1 | Melody enable flag set |
| 6:2 | Melody stop flag set |
| 6:3 | Melody address changed |
| 6:4 | Melody data was nonzero |
| 6:5 | `output_r` was nonzero |
| 6:6 | Audio bit toggled inside CPU |
| 6:7 | SM511 high-speed clock mode seen |
| 6:8 | SM511 low-speed clock mode seen |
| 7:1 | Input K was nonzero |
| 7:2 | BA input seen high |
| 7:3 | Beta input seen high |
| 7:4 | S shifter output was nonzero |
| 7:5 | Segment L was nonzero |
| 7:6 | Segment X was nonzero |
| 7:7 | Segment Y was nonzero |
| 7:8 | RAM write seen |
| 8:1 | `KTA` read the K input into Acc |
| 8:2 | `TB` tested the Beta input |
| 8:3 | `TAL` tested the BA input |
| 8:4 | `TIS` tested the one-second divider flag |
| 8:5 | `WR` shifted a zero into W |
| 8:6 | `WS` shifted a one into W |
| 8:7 | SM511-family `PTW` latched W to S |
| 8:8 | W shift register was nonzero |

## CPU View

This is live state. The value bits are displayed left-to-right as the packed row byte bit 0 through bit 7.

| Row | Packed Value |
| --- | --- |
| 1 | `{cpu_id[3:0], stage[3:0]}` |
| 2 | `PC[11:4]` |
| 3 | `{PC[3:0], opcode[7:4]}` |
| 4 | `{opcode[3:0], Acc[3:0]}` |
| 5 | `{carry, Bm[2:0], Bl[3:0]}` |
| 6 | Normal: `{input_k[3:0], output_r[3:0]}`. SM530: `input_k[7:0]` |
| 7 | Normal: `shifter_s[7:0]`. SM530: `{ram_wr, last_ram_write_addr[6:0]}` |
| 8 | Normal: `{instr_clk_en, halt, reset_halt, gamma, divider_4hz, divider_32hz, divider_64hz, divider_1s_tick}`. SM530: `{last_ram_write_data[3:0], last_ram_read_data[3:0]}` |

## Melody View

This is live state for SM511/SM512/SM530 melody debugging.

| Row | Packed Value |
| --- | --- |
| 1 | `melody_address[7:0]` |
| 2 | `melody_data[7:0]` |
| 3 | `{melody_rd[1:0], melody_step_count[4:0], melody_rd[0]}` |
| 4 | `{melody_duty_index[1:0], melody_duty_count[4:0], sm511_slow_clock}` |
| 5 | `{output_r[3:0], stored_output_r[3:0]}` |
| 6 | `{melody_active_tone_next, melody_target_cycles_next[4:0], melody_rd[0], output_r[0]}` |
| 7 | `divider[14:7]` |
| 8 | `{divider[6:0], gamma}` |

## Core View

This is live state from the wrapper around the CPU and loader.

| Row | Packed Value |
| --- | --- |
| 1 | `{cpu_id[3:0], input_k[3:0]}` |
| 2 | Normal: `output_shifter_s[7:0]`. SM530: `input_k[7:0]` |
| 3 | `{output_r[3:0], input_ba, input_beta, image_download, rom_download}` |
| 4 | Normal: `rom_addr[11:4]`. SM530: `{current_w_prime[4], current_w_main[4]}` |
| 5 | Normal: `{rom_addr[3:0], rom_data[7:4]}`. SM530: `{current_w_prime[5], current_w_main[5]}` |
| 6 | Normal: `{rom_data[3:0], melody_addr[7:4]}`. SM530: `{current_w_prime[6], current_w_main[6]}` |
| 7 | Normal: `{melody_addr[3:0], melody_data[7:4]}`. SM530: `{current_w_prime[7], current_w_main[7]}` |
| 8 | Normal: `{melody_data[3:0], current_segment_a[3:0]}`. SM530: `{current_w_prime[8], current_w_main[8]}` |

For a V2 voice package, Core rows 3-8 are replaced with voice state:

| Row | Packed Value |
| --- | --- |
| 3 | `{bank_valid, busy, command[4:0], beta}` |
| 4 | Current voice-bank byte address `[15:8]` |
| 5 | Current voice-bank byte address `[7:0]` |
| 6 | Signed decoded voice sample `[15:8]` |
| 7 | ADPCM nibbles remaining `[15:8]` |
| 8 | ADPCM nibbles remaining `[7:0]` |

After loading a voice title, `bank_valid` should be 1. A phrase trigger should make `busy` 1, show its nonzero command, advance the byte address, and count the remaining nibbles down to zero. This proves the package bank and digital playback path; audible output still needs listening or an audio capture.

For the Star Fox V2 HA1152/HMC package, Core rows 3-8 are replaced with HMC state:

| Row | Packed value |
| --- | --- |
| 3 | `{1'b0, rom_valid, busy, trigger[1:0], oscillator_tick, output, S2}` |
| 4 | `{effect_ROM_address[6:0], command[7]}` |
| 5 | Current effect-ROM command byte |
| 6 | Command dwell remaining `[11:4]` |
| 7 | `{dwell_remaining[3:0], startup_remaining[8:5]}` |
| 8 | `{pitch_divider[6:0], noise_state[0]}` |

Trigger encoding is 0 = none, 1 = S2, 2 = S3, and 3 = S4. After Star Fox loads, `rom_valid` should be 1. Gameplay effect edges should set `busy`, select a nonzero trigger, move the ROM address through its program, and reduce dwell. The oscillator cell is only a one-system-clock pulse at the RTL's deterministic nominal 312.5 kHz rate, so it may not appear in a frozen manual snapshot. The original chip uses a drifting analog RC oscillator. As with voice playback, this view proves the digital package/sequencer path but not the sound heard from the connected speakers.

## First Test Pass

For an SM511/SM512 game that shows the initial LCD art but does not start:

1. Load the game normally and press the expected `Game A` or `Game B` input.
2. Turn on `Debug Video` and start with `Debug View = Events`.
3. Report lit cells as `row:column`, or send a photo.
4. Switch to `CPU`, then `Melody`, and send photos if the Events view shows main and melody ROM writes.

The first split to look for is whether `1:8`, `2:6`, `5:5`, `6:1`, and `6:6` ever light. Together those say: melody ROM loaded, melody data read, SME executed, melody enabled, and audio toggled.

For SM511/SM512 input bring-up, also watch `7:1`, `7:4`, and `8:1-8:8`. These say whether the firmware is polling K/BA/Beta or waiting on the one-second flag, whether K ever goes active, whether S was latched nonzero, whether W is being built by `WR`/`WS`, and whether `PTW` ever copies W to the S output row scanner.

## SM530 Bring-up Pass

For a Nelsonic SM530 package that loads artwork but does not start, collect frozen snapshots from `CPU` and `Core` views:

1. Load the package and let its power-on display settle. For `nsmb3`, wait at least five seconds; Mode is ignored during its approximately five-second all-segment test.
2. Freeze `CPU` view and record rows 1-8.
3. Freeze `Core` view and record rows 1-8.
4. Unfreeze, press Mode, freeze `CPU` and `Core` again. On `nsmb3`, Mode is MiSTer Button 1/Xbox-style B.
5. For `nsmb3`, unfreeze and press D-pad Down after Mode; this is the original bottom-button start sequence. For other titles, repeat with Set and directions if Mode/Set do not change row 6 in CPU view.

The first split is whether CPU row 1 leaves stage `6` (`HALT`) and whether CPU rows 7-8 show RAM writes. Core rows 4-8 expose SM530 LCD groups 4-8, which contain stable gameplay display state in `nsmb3`. Its firmware tests RAM `0x37` bit 3 before executing `SME`: the default-clear state makes a normal game start silent, while the authentic alarm-setting UI sets the bit and enables melody. On Star Fox, the HMC feature replaces Core rows 3-8 with the table above; use CPU view for the normal SM530 execution state.
