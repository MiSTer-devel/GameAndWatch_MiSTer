# MiSTer Migration Log

Date: 2026-05-09

## Goal

Split the MiSTer build out of the former multi-target layout and reshape the active project around the MiSTer template structure:

- `sys/` is the MiSTer framework, copied from upstream and kept unmodified.
- `rtl/` contains the Game & Watch core RTL plus MiSTer-only PLL/IP/vendor dependencies.
- Root project files (`GameAndWatch.qpf`, `GameAndWatch.qsf`, `GameAndWatch.srf`, `GameAndWatch.sv`, `files.qip`) follow the template convention.
- `releases/` is present for MiSTer release RBFs.

## Upstream Sources

- MiSTer template: https://github.com/MiSTer-devel/Template_MiSTer
- Template commit used for local copy: `cce023f4ea34a5088a5ce5b45c90ad2a4493c6ac`
- Existing SDRAM controller dependency: https://github.com/agg23/sdram-controller
- SDRAM controller commit vendored locally: `eb2afab0f54aa2f08399defe4e74d3c685efb3b2`

## Initial Findings

- The existing workspace is not a git checkout, so changes are recorded here rather than as git commits.
- The current MiSTer-like target was under `target/mimic`; `target/mimic/core_top.sv` was the old framework adapter.
- The old framework lived under `platform/mimic` and used OpenGateware/MiMiC-style `core_top` plumbing.
- The upstream MiSTer template expects the framework in `sys/` and a core adapter module named `emu`.
- The old build referenced `target/vendor/sdram-controller/sdram_burst.sv`, but that submodule directory was empty in this workspace.

## Changes Made

1. Copied upstream Template_MiSTer `sys/` into the repo root as `sys/`.
   - This folder is intended to remain byte-for-byte identical to upstream.
   - Core-specific logic is not placed in `sys/`.

2. Added MiSTer root project files:
   - `GameAndWatch.qpf`
   - `GameAndWatch.qsf`
   - `GameAndWatch.srf`
   - `GameAndWatch.sv`
   - `files.qip`
   - `clean.bat`

3. Migrated MiSTer-only support files into `rtl/`:
   - `target/mimic/pll/` -> MiSTer-template PLL layout (`rtl/pll.qip`, `rtl/pll.v`, generated files under `rtl/pll/`)
   - `target/shared/` -> `rtl/ip/`
   - `sdram-controller` -> `rtl/vendor/sdram-controller/`

4. Converted the old MiSTer wrapper:
   - Old module: `core_top` in `target/mimic/core_top.sv`
   - New module: `emu` in `GameAndWatch.sv`
   - Replaced OpenGateware `NSX_*` framework macros with MiSTer `MISTER_*` macros.
   - Added modern MiSTer framework ports `HDMI_BLACKOUT` and `HDMI_BOB_DEINT`.
   - Switched build date include from `build_id.vh` to template-generated `build_id.v`.
   - Kept the core hookup to `rtl/gameandwatch.sv` and the same OSD/menu options.

5. Removed legacy multi-target folders after confirming they were not referenced by the root MiSTer build:
   - `projects/`
   - `target/`
   - `platform/`
   - `pkg/`
   - `support/`
   - `.github/`
   - `.vscode/`

6. Removed stale root metadata from the old multi-target project:
   - `.gitmodules`
   - `gateware.json`

7. Trimmed unused RTL collateral that was not referenced by `files.qip`:
   - `rtl/gameandwatch.qip`
   - `rtl/test/`
   - `rtl/ip/shared.qip`
   - `rtl/pll/pll.ppf`
   - unused SDRAM controller examples/tests, keeping `rtl/vendor/sdram-controller/sdram_burst.sv` and its `LICENSE`

## Active Build Entry

Use the root-level project:

```sh
quartus_sh --flow compile GameAndWatch.qpf
```

The resulting release artifact should follow MiSTer naming convention:

```text
GameAndWatch_YYYYMMDD.rbf
```

## Verification Log

Completed:

- `sys/` was compared against a freshly fetched Template_MiSTer checkout and matched byte-for-byte.
- `find sys -type f | wc -l` returned `56`, matching the fetched template copy.
- `files.qip` path check found no missing files.
- Active project references were checked in `GameAndWatch.qsf` and `files.qip`; the build sources `sys/sys.tcl`, `sys/sys_analog.tcl`, `files.qip`, `GameAndWatch.sv`, and files under `rtl/`.
- Removed the redundant root `GameAndWatch.sdc`. The MiSTer framework SDC is already included by untouched `sys/sys.qip`, and the root SDC only duplicated `derive_pll_clocks`/`derive_clock_uncertainty` without adding core-specific constraints.
- The remaining top-level folders are `docs/`, `releases/`, `rtl/`, and `sys/`.
- Active root/build files were checked for stale references to removed folders and old project files; none were found.
- No `.DS_Store` files remain in the workspace.
- During build testing, Quartus expanded `GameAndWatch.qsf` and added a stale `set_global_assignment -name QIP_FILE rtl/pll/pll.qip`. Restored the clean local QSF; do not save generated/expanded assignments back into `GameAndWatch.qsf`.

Not completed locally:

- Quartus compile or analysis pass. `quartus_sh` is not available on PATH in this workspace.
- Verilator/Icarus syntax pass. `verilator` and `iverilog` are not available on PATH in this workspace.

Recommended external compile command:

```sh
quartus_sh --flow compile GameAndWatch.qpf
```

## Build Review - 2026-05-09
Key findings:

- Build completed and emitted `GameAndWatch.rbf`, but TimeQuest reported large negative setup/hold slack.
- The worst timing paths were mostly between unrelated framework/core clocks. The template SDC expects the core PLL instance to be named `pll`, but the migrated wrapper had instantiated it as `pll_core`, so `sys/sys_top.sdc` could not match the core PLL clock group.
- `sys/` was not changed. The core wrapper was changed to instantiate `pll pll (...)` so the untouched template SDC can recognize the core PLL clocks.
- The generated PLL outputs are `98.304 MHz` and `32.768 MHz`; the SDRAM controller had still been parameterized as `99.28704 MHz`. Updated the SDRAM controller parameter to `98.304`.
- Fixed several high-signal RTL warnings from the build report:
  - Explicitly sized small counter decrements and alpha constants.
  - Made `clock_melody` automatic and widened divider index expressions.
  - Initialized the SM5a `PDTW` temporary W-prime array from the current W-prime state before modifying it.
  - Added initial zero values for `normalize` output segment entries that are intentionally unused for some CPU families.

Not changed:

- `sys/` warnings from untouched MiSTer framework files.
- Optional resource-saving framework macros such as `MISTER_DISABLE_YC`, `MISTER_DISABLE_ALSA`, and `MISTER_DISABLE_ADAPTIVE`; those remove framework features and should be a deliberate project choice.

## Build Review - 2026-05-09, second build

Findings:

- The previous core PLL naming/timing-constraint issue is fixed; the framework SDC now recognizes the core PLL clocks.
- Setup timing is much closer but still not fully closed: worst setup slack is `-0.184 ns` on the core `98.304 MHz` clock, with all hold/recovery/removal checks passing.
- The core SDRAM controller's `SDRAM_nCS` output was still exposed by `rtl/gameandwatch.sv` but left unconnected in the MiSTer wrapper, while the board pin was tied low. Hooked the wrapper's `SDRAM_nCS` port directly to the core controller output.
- Cleaned the remaining `clock_melody` divider selection warnings by replacing the dynamic divider bit index with an explicit selector function and moving task temporaries to the task scope with defaults.
- Remaining framework warnings around `ascal`, `sys_top.sdc`, and open-drain/tri-state conversions are from untouched template/framework code or expected unused interfaces.
- Remaining core warnings are mostly cleanup candidates rather than obvious test blockers: `instructions.sv` interface warnings and vendor SDRAM controller truncation/unused-register warnings.

## Build Review - 2026-05-09, post video alignment fix

Findings:

- The Quartus flow completed successfully and emitted `GameAndWatch.rbf`.
- Timing is closed. Worst setup slack is `0.123 ns`, worst hold slack is `0.253 ns`, and all reported TNS values are `0.000`.
- Resource use remains comfortable: `9,968 / 41,910` ALMs (`24%`), `2,057,829 / 5,662,720` block memory bits (`36%`), `283 / 553` RAM blocks (`51%`), `36 / 112` DSP blocks (`32%`), and `3 / 6` PLLs (`50%`).
- The wrapper's audio outputs are wired through the normal MiSTer framework path: `GameAndWatch.sv` drives `AUDIO_L`, `AUDIO_R`, `AUDIO_S`, and `AUDIO_MIX`, and `sys/sys_top.v` feeds those into `audio_out`.
- No project macro is disabling ALSA/framework audio support; `MISTER_DISABLE_ALSA` remains commented out.
- The main report noise is still framework/generated-IP or vendor noise: `ascal` width/connectivity warnings inside untouched `sys/`, ignored `sys_top.sdc` filters for optional framework paths, generated IP notices, and SDRAM controller unused/truncation warnings.
- Remaining core cleanup candidates are informational rather than functional blockers: `instructions.sv` interface bidirectional-port warnings and mixed blocking/non-blocking assignment notices in several clocked blocks.

No code change was made from this review beyond documenting the findings.

## Build Review - 2026-05-09, after SDC cleanup

Findings:

- The Quartus flow completed successfully and emitted `GameAndWatch.rbf`.
- TimeQuest now reads only `sys/sys_top.sdc`, confirming the root SDC removal was picked up.
- Timing remains closed. Worst setup slack is `0.123 ns`, worst hold slack is `0.253 ns`, and all reported TNS values are `0.000`.
- Resource use is unchanged: `9,968 / 41,910` ALMs (`24%`), `2,057,829 / 5,662,720` block memory bits (`36%`), `283 / 553` RAM blocks (`51%`), `36 / 112` DSP blocks (`32%`), and `3 / 6` PLLs (`50%`).
- Remaining warnings are the same categories as the prior build: framework/generated-IP notices, untouched `sys/` scaler/SDC warnings, vendor SDRAM controller warnings, and core RTL hygiene warnings around interfaces or mixed blocking/non-blocking temporaries.

No additional code change was made from this review.

## Native 720 Timing Restore - 2026-05-09

The 360x240 15 kHz transport experiment was superseded after hardware review showed that the core's preservation-critical output should remain the original 720x720 cadence.

Changes made:

- Restored the native video counters to a 720x720 active image with 756 total horizontal pixels and 730 total vertical lines.
- Kept the current 32.768 MHz video PLL output as the canonical pixel clock, producing approximately 59.375 Hz refresh.
- Removed the `/5` pixel-enable divider from the main video path; `CE_PIXEL` is now asserted every video clock.
- Restored the core/video relationship to `CLOCK_RATIO(3)`, matching the 98.304 MHz system clock to 32.768 MHz video clock relationship.
- Updated the SM510 clock divider to `3000 - 1`, giving a 32.768 kHz CPU enable from the 98.304 MHz system clock.
- Restored the SDRAM image reader and LCD mask walker to consume the full 720x720 source image rather than sampling a 360x240 point grid.
- Updated the MiSTer `arcade_video` wrapper width from 360 to 720 so the framework receives the accurate native stream.

CRT note:

- 720x720 progressive at approximately 59.4 Hz is not a 15 kHz TV/PVM mode; its horizontal rate is about 43.3 kHz. A 15 kHz analog/direct-video path will need to be a derived/downsampled transport path, not the master video timing.

No `sys/` framework files were changed.

## Video Pipeline Revert - 2026-05-09

Reverted the post-CRT video pipeline experiments after hardware testing showed the analog output was broken.

Changes made:

- Removed the `arcade_video` helper from the active wrapper path and restored the refactor-era direct native video hookup: `CLK_VIDEO = clk_vid_33_095`, `CE_PIXEL = ce_pix`, raw RGB to `VGA_R/G/B`, raw syncs to `VGA_HS/VGA_VS`, and raw `de` to `VGA_DE`.
- Kept the restored old-core 720x720 source reader, counters, and LCD mask walker rather than the 360x240 CRT sampling path.
- Reverted the SM510 clock-divider tweak from `3000 - 1` back to the prior refactor value `12'hBF4 - 1`.
- Updated the README feature text back to the old-core style `720 x 720 pixel resolution`.

The earlier `Native 720 Timing Restore` section above is retained as history, but its wrapper-level `arcade_video #(720)` path is no longer active.

No `sys/` framework files were changed.

## Dual Video Path - 2026-05-10

- Snapshotted the restored native-video state under `releases/snapshots/pre_dual_video_20260510/` before changing the pipeline.
- Enabled `MISTER_FB=1` in `GameAndWatch.qsf` so the MiSTer framework can receive a 720x720 framebuffer from the core without modifying `sys/`.
- Added `rtl/video/fb_writer.sv`, a local DDRAM framebuffer writer for the canonical 720x720 RGB stream. This keeps the HDMI/scaler-facing image at the preservation target resolution.
- Added `rtl/video/analog_15khz.sv`, a separate VGA-port stream that downsamples the canonical 720x720 image to 360x240 and emits 416x262 timing at the existing 32.768 MHz video clock divided by 5. This produces an approximately 15.754 kHz analog line rate while leaving the native stream intact.
- Routed top-level `VGA_*` to the analog stream and routed the native stream only into the framebuffer writer under `MISTER_FB`. The Template_MiSTer `sys/` folder remains untouched.

## Dual Video Path Revert - 2026-05-10

- Reverted the failed dual-path framebuffer/VGA experiment after hardware testing reported no analog video and a `0x0 @ 0 kHz` analog mode.
- Restored the main project to the pre-dual-video native 720x720 direct stream: `CLK_VIDEO = clk_vid_33_095`, `CE_PIXEL = ce_pix`, raw RGB/sync/DE to `VGA_*`, and `MISTER_FB` disabled again.
- Removed `rtl/video/fb_writer.sv` and `rtl/video/analog_15khz.sv` from the main project and from `files.qip`.
- Kept the snapshot under `releases/snapshots/pre_dual_video_20260510/` as the known marker for the restored state.

No `sys/` framework files were changed.

## Button-Up Warning Cleanup - 2026-05-10

- Cleaned the remaining local `rtl/mask.sv` truncation warning by replacing the unsized decrement literal with a sized `1'b1`.
- This is a warning-only cleanup; no video, audio, ROM, or MiSTer framework plumbing was changed.

No `sys/` framework files were changed.


## Game & Watch Sound Path Restore - 2026-05-10

- Hardware testing found that Tiger titles still make sound, while normal Game & Watch titles do not.
- That split points at the CPU-type-specific `clock_melody()` path: Tiger uses the direct `R` path, while normal SM510 Game & Watch titles use the divider-gated path.
- Reverted `rtl/cpu/instructions.sv` `clock_melody()` to the upstream `agg23/fpga-gameandwatch` behavior, including the direct `divider[output_r_mask]` indexing and task-local temporaries.
- This intentionally backs out the earlier warning-cleanup helper in this area so the preservation-critical sound behavior matches the old working core first.

No `sys/` framework files were changed.

## SM511/SM512 Support Work - 2026-05-11

Started implementation on branch `SM511+12` after a read-only feasibility pass against the local RTL and current MAME SM511/SM512 references.

ROM generator changes:

- Kept the existing `.gnw` layout compatible for SM510/SM5a packages.
- Added SM511/SM512 to the generator's normal `supported` filter.
- Added melody ROM packaging for SM511-family packages: the program ROM is padded to `0x1000` bytes and the 256 byte melody ROM is appended at package byte offset `0x326240` (`ROM_DATA_ADDR + 0x1000`).
- Added optional `melodyHash` manifest plumbing so shared/parent melody ROMs can be found by SHA when a filename lookup is not enough.
- Left SM511 Tiger IDs out of the normal `supported` filter for now, but the packaging helper recognizes them as melody-ROM CPUs if generated explicitly.

RTL changes:

- Added a 256 byte melody ROM RAM in `rtl/gameandwatch.sv`, loaded from the appended ROM area at byte offsets `0x1000-0x10FF` after the main program ROM.
- Added SM511/SM512 melody address/data signals into `rtl/sm510.sv` and `rtl/cpu/instructions.sv`.
- Added the SM511/SM512 melody generator state, tone-cycle table, and `PRE`, `SME`, `RME`, and `TMEL` operations following MAME's phase/reset behavior.
- Added SM511/SM512 clock select handling: reset starts at the slower 8.192 kHz instruction rate and `CLKHI`/`CLKLO` switch between 16.384 kHz and 8.192 kHz.
- Added an SM511-family decode path for CPU IDs `1`, `2`, `6`, and `7`, including the moved/expanded opcode map (`ROT`, `DTA`, `KTA`, `ATX`, `PTW`, `TL`, `TML`, and the `0x60` extended opcodes).
- Split the W shift register from the S output latch so SM510 still updates S directly on `WR`/`WS`, while SM511/SM512 latch W to S via `PTW`.
- Added SM512 segment C RAM caching for addresses `0x50-0x5F` and propagated segment C through the LCD/video normalization path as mask line `x=3`.
- Changed BS from a single replicated bit to a 16-bit vector: SM510 still mirrors the single BS behavior across all mask columns, while SM511/SM512 expose BS column 0 from L/Y blinking and column 1 from X.

Documentation changes:

- Documented the appended SM511/SM512 melody ROM location in `docs/format.md`.
- Updated `docs/graphics.md` so the SVG segment-plane documentation includes SM512 `seg_c` as mask line `x=3`.
- Updated generator docs to reference the actual `rom generator/` folder instead of the earlier `support/` name and describe the SM511/SM512 melody packaging behavior.

Verification notes:

- `git diff --check` passed.
- `cargo`, `quartus_sh`, `verilator`, and `iverilog` were not available in this local tool environment, so Rust and HDL compile checks still need to be run on the build machine.

No `sys/` framework files were changed.

## 2026-05-13 hardware debug overlay for SM511/SM512 bring-up

- Read the Raizing/Demon's World debug notes as reference only. The useful pattern was an OSD-controlled 8x8 video grid driven by sticky/live core signals, allowing hardware debugging without SignalTap.
- Added Game & Watch-owned OSD controls: `Debug Video` on `status[6]` and `Debug View` on `status[8:7]`. The MiSTer `sys/` framework remains untouched.
- Added `sm510` debug outputs for sticky CPU/melody events plus live CPU and melody state rows. These expose the exact SM511/SM512 questions for the current failure: CPU ID, ROM/melody loading, instruction-stage progress, halt/wake state, `PRE`/`SME`/`RME`/`TMEL`, melody ROM address/data, and audio toggles.
- Added a core-level event collector in `rtl/gameandwatch.sv` for IOCTL/package load state, main ROM writes, appended melody ROM writes, CPU type, melody-data reads, melody-address changes, and sound bit toggles. It intentionally keeps loader flags through `ioctl_download`, since the normal core reset is asserted while a ROM package is loading.
- Added the diagnostic video overlay in `rtl/video/video.sv`, replacing normal RGB only when `Debug Video` is enabled. Normal video and audio paths are unchanged when the option is off.
- Documented the view maps and first hardware test flow in `docs/debug_overlay.md`.

## 2026-05-13 SM511/SM512 input debug refinement

- Audited the Zelda BA/Beta-high observation against the ROM generator before keeping any polarity change. The generator intentionally defaults absent B/BA ports to active-low unused entries because those pins have pull-up resistors, so the input mux behavior was left unchanged.
- Added a separate `debug_clear` pulse for the core/package debug collector so loader events survive the normal post-download reset but still clear on MiSTer reset or at the start of the next ROM download.
- Replaced the least useful divider sticky cells in the Events debug view with SM511/SM512 row-scanner cells for `WR`, `WS`, `PTW`, and nonzero W-register state.
- After Zelda showed no W/S activity, repurposed the first half of Events row 8 to sticky `KTA`, `TB`, `TAL`, and `TIS` opcode sightings so the next hardware pass can tell whether execution is trapped in the input/timer gate before display scanning starts.
- Added `Debug Freeze` on `status[9]` to latch the current debug buses for stable manual CPU/Core transcription without changing core execution.

## 2026-05-13 SM511/SM512 program ROM fetch fix

- Frozen CPU debug snapshots showed Zelda executing in the `0x44x` ROM page while never reaching input polling or W/S scan opcodes.
- Audited the SM511/SM512 slow-clock path and found that `rom_data` was being refreshed on every 32.768 kHz `clk_en`, while SM511/SM512 instruction stages advance only on `instr_clk_en`. During the idle half-cycle, the program ROM register could be overwritten with the post-increment PC byte before decode.
- Added `rom_rd_en` from `rtl/sm510.sv` and changed `rtl/gameandwatch.sv` so program ROM data only updates on the CPU instruction clock. Melody ROM still updates on `clk_en`, since the melody sequencer is clocked independently of instruction execution.


## 2026-05-13 SM511/SM512 melody timing follow-up

- Decoded Zelda Melody debug rows from the on-screen bit grid. Because cells are displayed left-to-right as bit 0 through bit 7, user-transcribed rows must be bit-reversed before reading them as packed byte values.
- The captured Zelda melody state showed a valid SM511 melody command (`0x19`) at melody address `0x22`, melody enable set, and `output_r[0]` active. That makes missing melody ROM data unlikely for the observed popping sound.
- Corrected the core clock enable divider after the PLL change to `98.304 MHz`: `98.304 MHz / 3000 = 32.768 kHz`. The previous divider value was still based on the older clocking and produced roughly `32.125 kHz` for CPU/divider/melody timing.


## 2026-05-13 SM511/SM512 melody duty-counter fix

- Decoded additional Zelda Melody snapshots. The melody ROM commands around the bad sounds were valid, and `output_r[0]` did go high, but every captured row showed `melody_duty_count == 0` while `melody_duty_index` changed.
- That points at the tone phase counter advancing without holding each phase for the SM511 table's target cycle count, which would produce audible clicks/pops rather than sustained beeps.
- Reworked the SM511/SM512 melody timing code to compute target cycles through an explicit helper, use an automatic `clock_melody` task, and carry a named `next_duty_count` through the compare/update. This preserves the MAME timing model but avoids the previous nested temporary expression in the interface task.
- Changed Melody debug row 6 to show `{melody_active_tone, melody_target_cycles[4:0], melody_rd[0], output_r[0]}` so the next hardware pass can confirm active tones have nonzero target cycle counts.


## 2026-05-13 SM511/SM512 melody target-cycle lookup fix

- Hardware after the duty-counter patch still popped. New Melody debug row 6 showed active tone/output/enabled bits, but no `melody_target_cycles` bits. Row 4 still showed only duty-index bits, confirming the target cycle count was zero and the duty counter reset every tick.
- Replaced the SM511 target-cycle helper function path with a direct combinational lookup table keyed by `{melody_duty_index, melody_data[3:0]}`. The melody task now consumes that precomputed `melody_target_cycles_next` value instead of asking a nested helper during the interface task.
- Pointed Melody debug row 6 at the direct combinational lookup (`melody_active_tone_next`, `melody_target_cycles_next`) so the next hardware build can tell immediately whether the lookup produces nonzero tone lengths.


## 2026-05-13 Balloon Fight LCD package contrast

- Confirmed `Balloon Fight (New Wide Screen).gnw` is packaged as CPU ID `1` / SM511. The package contains non-empty artwork, mask entries, program ROM, and melody ROM.
- Decoded the generated `.gnw` image layers and found the foreground LCD layer is effectively identical to the background: only 4 of 518,400 pixels differed, and only 4 of 124,628 segment-mapped pixels had any RGB delta. With the core's normal background/foreground blend, active LCD segments therefore have almost no visible effect even if the SM511 CPU is driving them correctly.
- Added a ROM-generator contrast fallback in `render.rs`: after composing the normal LCD foreground layer, the generator measures RGB delta over segment-mapped pixels. If the active layer has near-zero contrast, it darkens only those segment pixels in the foreground layer so regenerated packages still preserve the mask geometry while producing visible LCD artwork.
- This is intentionally generator-side rather than a MiSTer core workaround, because the core's video path already receives separate background and active-LCD image planes from the `.gnw` package. Existing packages with normal foreground/background contrast are left unchanged by the threshold.


## 2026-05-14 single-start handheld input mapping

- Investigated `Bill Elliott's NASCAR Racing (handheld)` / `knascar`, which packages as SM511 with valid program/melody hashes and healthy LCD mask/artwork data.
- Found the manifest maps only `start1` for this game; there is no `start2`/Game B action. The core's MiSTer wrapper had been treating `start1` strictly as Game A on controller Select, while controller Start only drove `start2`. That is preservation-friendly for Nintendo Game & Watch A/B titles but awkward for non-Nintendo handhelds with a single Start input.
- Updated `rtl/input_config.sv` to detect whether the loaded package contains any `start2` mapping. If not, controller Start also drives `start1`. Packages that do define `start2` keep the existing split: Select = `start1` / Game A, Start = `start2` / Game B.

## 2026-05-14 SM511/SM512 halt wake input path

- Decoded the `Bill Elliott's NASCAR Racing (handheld)` CPU debug snapshot as SM511 at stage `HALT`, with `PC=0x400`, no active `S` row scanner, and no `KTA`/`PTW` activity. That makes the failure a CPU wake problem rather than a ROM, LCD mask, or artwork problem.
- Added a separate `input_wake` signal in `rtl/input_config.sv` that ORs the currently pressed mapped K controls across all configured S rows while ignoring unused `0x7f` entries.
- Changed the SM511/SM512 halt wake condition in `rtl/sm510.sv` to use that ungated wake signal, because those chips can wake from K input before firmware has latched an S row with `PTW`.
- Kept SM510/SM5a halt wake on the existing row-scanned `input_k != 0` path so already-working games stay on their previous behavior.
- Wired `input_wake` through `rtl/gameandwatch.sv`; no MiSTer `sys/` framework files were touched.

## 2026-05-14 piezo output attenuation

- Audited the MiSTer audio path after SM511/SM512 games sounded louder than expected. The CPU emulation still exposes a single logical piezo bit on `sound`, and the top-level MiSTer wrapper converts that bit into signed 16-bit samples.
- Reduced the wrapper-level square-wave amplitude from `+/-0x4000` to `+/-0x2000`, roughly matching MAME's 0.25 speaker route gain for the shared Game & Watch piezo path.
- Kept the change at the MiSTer output level rather than inside the SM511/SM512 melody generator, so melody timing, duty-cycle generation, and R-pin behavior remain unchanged.

## 2026-05-14 keyboard/keypad input scope decision

- Reverted the experimental `ps2_key`/calculator-keypad plumbing from the Space Adventure investigation.
- Left the core on its intended MiSTer controller-oriented input scheme. Packages whose original hardware requires a keyboard/calculator keypad matrix remain unsupported for now rather than being partially mapped to arbitrary keyboard controls.
- Documented that limitation in the README so keyboard-style games are not mistaken for broken SM511/SM512 emulation.

## 2026-05-14 Vinni-Pukh LCD package contrast

- Investigated `Vinni-Pukh.gnw`, which packages as SM511 with matching program and melody SHA-1 hashes and a normal controller-style input map.
- Confirmed the LCD mask is populated: 9,404 mask runs, 132 segment IDs, and about 128k mapped segment pixels. This makes missing graphics unlikely to be a CPU or mask-addressing failure.
- Found the generated active LCD image plane is effectively invisible: most mapped segment pixels are identical to the background, and the remaining changed pixels differ by only one RGB count.
- Raised the ROM generator's contrast fallback threshold so packages whose active LCD plane has only near-zero average RGB delta over mapped segment pixels are regenerated with the same mask geometry but a visibly darker active LCD layer.
- Existing `.gnw` files need to be regenerated to pick up this generator-side fix.

### 2026-05-14 Tiger grounded row manifest fix
- Found that `inp_fixed_last()` handling in the ROM generator stored the array position of the last `S` port rather than the actual `S` line index. This only diverged for Tiger games with skipped S rows.
- Updated `rom generator/extraction/src/extract.ts` to write `port.index`, matching the package format and `rtl/input_config.sv` expectation that the stored value is the 0-based S line number before encoding.
- Corrected the checked-in manifest entries whose grounded row pointed at the wrong S line: `tbatmana`, `tflash`, `tgargnf`, `tmigmax`, `tsuperman`, and `tvindictr`. Existing `.gnw` packages for those games need to be regenerated to pick up the fix.

### 2026-05-14 manifest extractor coverage for skipped MAME titles
- Added `tripleHorizontal` screen metadata so `sm511_tripleh(...)` titles such as Tronica Treasure Island can be represented by the ROM generator manifest.
- Taught the extractor to handle Konami `ktmnt2`-derived constructors that call `ktmnt2(config)` and then replace the SVG screen size with `mcfg_svg_screen(...)`, covering `kst25` and `ktopgun2`.
- Documented format value `0x3` for triple-horizontal packages. Konami external sample/ADPCM audio and MAME `IPT_CUSTOM` shared-button behavior remain separate core/input-scope issues; these changes make the titles representable in the manifest and generator.

### 2026-05-14 non-keypad IPT_CUSTOM input mappings
- Split known non-keypad MAME `IPT_CUSTOM` lines into explicit package actions instead of treating every custom condition as one generic input.
- Added `CustomUpDown` for Konami Star Trek's shared Up/Down input and `CustomButtonHour` for Tronica Treasure Island's shared Start/Jump/Pick or Hour line.
- Updated `rtl/input_config.sv` so `CustomUpDown` maps to D-pad Up or Down and `CustomButtonHour` maps to Button1 on the existing controller layout. Generic `Custom` and keypad-derived custom inputs remain intentionally unhandled.
- Updated the local ignored `rom generator/manifest.json`; existing `.gnw` packages for affected games must be regenerated to carry the new action IDs.

## MiSTer Framework Refresh - 2026-05-15

- Replaced the MiSTer framework folder with a byte-for-byte copy from the local Template_MiSTer checkout at template commit `f35083f3b40d24853abea4cd3f77caccbd71d5de`.
- The refreshed framework replaces `sys/audio_out.v` with `sys/audio_out.sv`, adds `sys/emu_ports.vh`, and moves the scaler/framebuffer scanline status plumbing out of the core-facing HPS bus extension.
- Updated `GameAndWatch.sv` to include `sys/emu_ports.vh` for the `emu` module port list, matching the modern Template_MiSTer convention and the refreshed framework `HPS_BUS[45:0]` width.
- Verified the refreshed framework matched the local Template_MiSTer checkout after the refresh.

No core video, audio, ROM loader, CPU, or LCD behavior was changed as part of this framework refresh.

## Local Path Cleanup - 2026-05-15

- Removed machine-specific absolute directory references from project documentation.
- Removed `.DS_Store` files from the project tree so Finder metadata is not carried with the source.

## 2026-05-18 SM530 Super Mario Bros. 3 LCD bring-up

- Inspected the generated `nsmb3` package and confirmed it contains a valid SM530 program ROM, melody ROM, populated artwork, and mask IDs in the expected 12 output groups by 4 segment bits by 2 LCD rows shape.
- Cross-checked the SM530 LCD mapping against MAME: display RAM lives at `0x40-0x4b` and `0x50-0x5b`, with mirrors at `0x60/0x70`, and the LCD callback emits those two RAM banks as the two SM530 LCD rows.
- Reset the RAM/display caches with the CPU reset and changed the SM530 LCD latch to read the canonical LCD RAM banks directly. This removes any dependency on stale cache state when a package boots and keeps mirror writes flowing through the same canonical RAM addresses.
- Updated Core debug row 8 for SM530 packages so it exposes the first latched A/B LCD nibbles (`current_w_prime[0]` and `current_w_main[0]`) instead of the SM510-style segment A nibble.

## Deferred CRT/direct-video presentation plan - 2026-05-19

- Original Game & Watch hardware has no native raster resolution; the preservation target is LCD segment geometry, artwork placement, timing, and per-title aspect rather than a universal pixel grid.
- MAME defines each title as an SVG screen with per-game dimensions, commonly 1080 pixels tall with width chosen for the source artwork. Those dimensions should guide aspect/presentation, but they should not be treated as mandatory MiSTer video timings.
- The current `720x720` output is a convenient fixed package and video canvas, not a hardware-accurate native mode. A CRT/direct-video-friendly path should decouple the logical artwork canvas from the raw output timing.
- Preferred future approach: make the raw `VGA_*` stream a real 15 kHz mode, probably `720x480i` if matching the old core's direction or `720x240p` if stable progressive CRT output is preferred, then letterbox/pillarbox the game into that raster using MAME-derived source aspect.
- Direct video and analog VGA should share that same raw 15 kHz stream. Normal HDMI can then use the MiSTer scaler from the same source; keeping high-res HDMI while simultaneously outputting 15 kHz analog/direct would be a larger dual-path/framebuffer design.
- The ROM generator likely needs at least metadata updates for source aspect/layout bounds, and ideally a package-versioned CRT render/mask target so the core does not need to do fragile real-time mask downscaling.

## 2026-05-19 SM530 hardware debug overlay expansion

- Added SM530-specific CPU debug rows: row 6 now shows all eight `K/KE` input bits, row 7 shows `{ram_wr, last_ram_write_addr}`, and row 8 shows `{last_ram_write_data, last_ram_read_data}`.
- Changed Core debug rows for SM530 packages to show LCD output groups 0, 1, 2, 3, and 11 from the latched SM530 A/B LCD RAM path. Group 11 is useful for `nsmb3` because the boot code writes that display group almost immediately.
- Updated the debug overlay notes with a short SM530 bring-up capture procedure so hardware snapshots can distinguish CPU execution/halt/input problems from LCD normalization problems.

## 2026-06-04 selectable CRT native video mode

- Added `Native Video` to the MiSTer OSD with the new `720x240 CRT` path as the default and the existing `720x720` path as a selectable compatibility mode.
- Moved the core-facing video handoff to the 99.287 MHz core clock and made both modes explicit `CE_PIXEL` modes. The old 720x720 path uses `/3`, preserving its effective 33.095 MHz cadence. The CRT path uses `/6`, producing an effective 16.55 MHz pixel cadence.
- Added dynamic timing in `rtl/video/counts.sv`: the CRT path outputs 720 active pixels by 240 active lines inside a 1052x263 total raster, which lands near 15.73 kHz horizontal and 59.8 Hz vertical.
- Kept existing 720x720 `.gnw` packages compatible by sampling source row `output_y * 3 + 1` for SDRAM image reads in CRT mode.
- Updated the LCD mask path to use a single original-style reader against the sampled 720p source row. During CRT-mode horizontal blanking the reader advances to the next sampled source row; otherwise it can stall on a skipped 720p row and active LCD segments disappear.
- Allowed `CE_PIXEL` to free-run while the core is reset before ROM load. Holding the pixel enable reset made the default CRT timing run at the full video clock and prevented the OSD from syncing on a CRT until a game was loaded.
- Documented the limitation: this is a bridge for hardware testing. A generator-native 720x240 package path is still the better long-term presentation solution because it can render masks directly at the CRT target and simplify the real-time mask bridge.

## 2026-06-04 CRT mask rollback

- Reverted the experimental three-row/time-sliced LCD mask merge after hardware testing showed the CRT mode only displayed part of the loaded game and lost active LCD graphics.
- Restored the simple single-reader CRT bridge: existing 720x720 packages are still reduced to 720x240 by sampling one source row per output row, and the LCD mask walker advances during horizontal blanking to the next sampled source row.
- Kept `Native Video = 720x240 CRT` as the default and kept the free-running `CE_PIXEL` fix so the OSD remains visible before ROM load.
- The remaining corruption risk is the known point-sampling limitation of using 720x720 packages on a 240p output. The better long-term fix remains generator-native 720x240 artwork/mask packages, rather than more real-time mask reconstruction in RTL.

## 2026-06-04 May 9 360x240 CRT retry

- Revisited the early May 9 hardware result where the simple 360x240 15 kHz transport was reported working on CRT before later preservation/timing reverts.
- Changed the default `Native Video` mode from the failed 720x240 experiment to `360x240 CRT`, while keeping `720x720` selectable for comparison.
- Restored the raw MiSTer video clock to the 32.768 MHz PLL output. In 720x720 mode `CE_PIXEL` is asserted every video clock; in CRT mode it is divided by 5, yielding a 6.5536 MHz pixel cadence.
- Changed CRT counters to 360 active pixels by 240 active lines inside a 416x262 total raster, for approximately 15.75 kHz horizontal scan.
- Kept existing 720x720 `.gnw` packages compatible by point-sampling the packed image layers at `source_x = output_x * 2` and `source_y = output_y * 3`.
- Restored a core-clocked LCD mask walker cadence instead of consuming `CE_PIXEL` directly across clock domains. The mask reader advances once every 3 core clocks in 720x720 mode and once every 15 core clocks in CRT mode.
- Updated the mask walker to compare sampled output pixels against the original 720x720 source coordinate range, so segments whose RLE spans a sampled point can still light even when the segment start coordinate itself is skipped.

## 2026-08-12 SM530 hardware completion

- Corrected the SM530 instruction cadence to execute its two internal phases across three oscillator clocks, matching the device's three-clock machine cycle without halving CPU speed relative to its divider and gamma timers.
- Corrected SM530 two-byte `LBL 6B` dispatch. It was previously shadowed by the SM511 `TML` opcode range, so the immediate address never reached `Bm`/`Bl`.
- Verified `nsmb3`, `nsmw`, and `nstarfox` against MAME reference behavior and on the dedicated USB-2 MiSTer. Each title reaches its clock display, accepts Mode, enters its gameplay display, and responds to live controls.
- Updated the SM530 Core debug view to expose LCD groups 4-8, which provide useful stable gameplay state for the Nelsonic titles.
- Star Fox's separate HMC sound effects remain outside the SM530 core; its SM530 program, LCD, input, and melody paths are working.
- Left `sys/` untouched.

## 2026-08-12 MAME 0.289 package refresh and sample-backed voice support

- Reworked manifest extraction around MAME system declarations and parent inheritance. The 0.289 source yields 175 MAME systems plus two existing homebrew entries; capability filtering selects 168 controller-oriented packages and excludes nine keyboard/keypad, dial, excessive-control, or non-LCD display cases.
- Added the previously omitted clone systems, SM511 Tiger variants, inherited Elektronika inputs, parent artwork fallback, real layout image filenames including JPEG, prefixed-view selection, and symbolic MAME screen-bound resolution.
- Generated `roms/` with 168 packages. The validator checks every program and melody SHA-1, fixed padding and tails, package sizes, and exact voice command slots.
- Added a V2 package extension for `ktmnt2`, `kst25`, and `ktopgun2`. MAME sample WAV files are band-limited to 8 kHz, encoded as high-nibble-first OKI ADPCM4, and placed in a fixed 64 KiB bank after the existing ROM/melody data.
- Added a private dual-port M10K voice bank and phrase player in `rtl/msm6373_sample.sv`. It implements the documented S1-S5 command latch, falling-S7 start, active-low S8 reset, command-zero stop, active-low busy feedback, bounded phrase lookup, 8 kHz ADPCM playback, and signed saturated mixing with the normal piezo path.
- This is functionally complete sample-backed support, not bit-identical MSM6373 preservation. The three internal 32 KiB mask ROMs remain undumped; a true chip/content implementation still requires recovery of each game-specific mask ROM.
- Focused ModelSim tests pass with zero errors or warnings. The full Quartus 17 build infers the 64 KiB bank in M10K memory; final timing and hardware results are recorded with the delivered artifact after verification.

### Voice baseline release and USB-2 verification (superseded)

This artifact remains the verified voice-support milestone. The seam-fixed
coherent release recorded on 2026-08-13 supersedes it for current testing.

- Regenerated and validated all 168 selected packages. The final validator result is `Validated 168 packages (voice banks: kst25:12, ktmnt2:11, ktopgun2:10)`.
- Reran the focused MSM6373 sample-player and V2 ROM-loader simulations from the cleaned production source. Both completed with zero errors and zero warnings.
- Ran one coherent Quartus 17.0.2 full compile after removing the hardware-test harness. The release RBF is 3,358,416 bytes with SHA-256 `4790ee46e628a563198a15c11f0611bcd5225bbc2bb468ef011e45aff44fded7`.
- Final fit uses 12,555 ALMs (30%), 17,674 registers, 2,490,149 block-memory bits, 332 RAM blocks, and 36 DSP blocks. The voice bank is inferred as a 65,536 x 8 on-chip RAM.
- Final TimeQuest results are worst setup slack `-0.542 ns` (TNS `-1.211 ns`) and worst hold slack `+0.238 ns`, within the accepted one-nanosecond setup tolerance for this branch.
- On the dedicated USB-2 MiSTer, a temporary debug-only strobe drove phrase command 1 through each final package. `kst25`, `ktmnt2`, and `ktopgun2` each showed a valid bank, asserted busy, latched command 1, active-low beta, a changing sample address, nonzero decoded output, and a decreasing remaining count. The debug-only logic was then removed before the release compile.
- Loaded each of those three games with the production core and captured its normal 720x720 presentation. Artwork, framing, and LCD layers rendered correctly for all three.
- Deployed the hash-verified release to `/media/fat/_Dev/GameAndWatch.rbf` on USB-2 and left Star Trek loaded for user listening/control testing. No JTAG programming was used and USB-1 was not accessed.
- The remaining user-facing check is subjective audio output and volume through the MiSTer audio path; screenshots and the digital debug trace prove playback state but cannot verify what the connected speakers sound like.

## 2026-08-12 ten-button input resolver

- Audited every input action in the 168-package MAME 0.289 supported set. All titles fit a four-direction D-pad plus ten buttons without collapsing distinct actions; the twelve largest Tiger layouts use nine buttons.
- Kept the legacy first eight button positions and appended `Sound/Minute` and `ACL`. The six system positions are now `Time/Pause/Status`, `Alarm`, `Game A/Power On`, `Game B/Power Off`, `Sound/Minute`, and `ACL`.
- Made package actions select the electrical function of each stable position. This exposes previously unreachable Sound, Power Off, and All Clear inputs while preserving the four gameplay/right-joystick positions.
- Stopped the old single-start convenience alias whenever the package declares Power Off, so a Power Off press cannot start or restart a game. Single-start packages without a dedicated function retain the Game-B-to-Game-A convenience.
- Gated controller presses while the MiSTer OSD owns input, before applying active-low package polarity.
- Fixed manifest `PORT_NAME` extraction and assigned Service4/Minute its own action ID 33. Older packages that encoded Minute as Service2 remain compatible but cannot distinguish Minute from Alarm; regenerate `trtreisl` for the corrected mapping.
- Added exhaustive input resolver simulation and a generator regression proving the supported-set allocation. The three Micro Vs. two-player titles remain a separate package-format limitation because player identity is not yet encoded.
- Canonicalized absent ACL to inactive `0x7f` while preserving the documented `0xff` electrical-high default for pulled-up B/BA pins. The RTL suppresses legacy action-127 ACL bytes regardless of polarity, but retains normal polarity for B, BA, and S; otherwise an old absent ACL byte could hold the CPU in reset.
- Added a header-only refresh mode and strengthened package validation to compare the complete semantic config area against the current manifest before checking ROM, melody, and voice payloads.

## 2026-08-13 720-wide video seam fix and coherent release

- Diagnosed the universal vertical black line as a core video-timing defect rather than an artwork or package-rendering problem. Before the fix, package pixels were correct through output X=510; output X=511 and X=512 were black; output X=513 resumed at package X=528; the rest of the row remained shifted by a net 15 pixels before a black right edge.
- The binary X counter's 511-to-512 transition could momentarily make the combinational `x >= width` comparison true. Raw `hblank_int` crossed into the 98.304 MHz `rgb_controller` domain, where the resulting false blank edge asserted `fifo_clear` and emptied both dual-clock image FIFOs.
- Registered `hblank`, `vblank`, and `de` in `rtl/video/counts.sv` at the `ce_pix` boundary, deriving them from `next_x` and `next_y` alongside the counter update. This retains the original stable post-edge behavior while removing glitches from multi-bit counter transitions.
- Added `sim/counts_tb.sv`. It injects a 511-to-512 transient while pixel enable is low and checks that blanking remains registered, then checks the native 720x720 and CRT 360x240 counter boundaries. All 14 checks pass with zero errors or warnings.
- Focused regressions also pass with zero errors or warnings: the ten-button resolver completed 4,194,723 checks, the MSM6373 player and V2 loader passed, SM510 opcode `0x78` decode passed 6 checks, and ACL behavior passed 39 checks. The Rust generator passes all 12 tests; all 168 packages validate with voice command counts `kst25:12`, `ktmnt2:11`, and `ktopgun2:10`.
- The video correction is entirely core-side and does not require package regeneration. The 168 refreshed packages carry generator provenance `2600ff1`, and their ROM, melody, artwork, mask, and voice payloads are unchanged.
- Ran one fresh Quartus 17.0.2 production compile, which completed with zero errors and 130 warnings. `output_files/GameAndWatch.rbf` is 3,355,848 bytes with SHA-256 `77d4b81ce60c769a6ccf2c145dfb52bcacc3ba25f8ffc504d60e2a52e3e2c478`.
- Final fit uses 12,714 ALMs (30%), 17,802 registers, 2,490,149 block-memory bits (44%), 332 RAM blocks (60%), and 36 DSP blocks (32%). Final TimeQuest results are worst setup `-0.746 ns` with TNS `-9.503 ns`, and worst hold `+0.244 ns`, within the branch's accepted one-nanosecond setup tolerance. The seam-specific `hblank` to image-reader transfer reports setup `+6.743 ns` and hold `+0.555 ns`, with no violation. Existing incomplete-project constraint and Template_MiSTer/ascal warnings remain and predate this fix.
- Deployed and hash-verified the artifact on the dedicated USB-2 MiSTer as `/media/fat/_Dev/GameAndWatch-seamfix-77d4b81ce60c.rbf`. USB-1 and JTAG were not accessed.
- A fresh TMNT II native capture matched the package background at all 518,400 pixels after normalizing the core's intentional one-code-level alpha blend: maximum and mean channel error were zero. The formerly broken X=511, X=512, X=513 and right-edge sample columns all matched; package X=719 is intentionally black.
- A temporary 360x240 CRT-mode capture was clean. The configuration was then restored to native 720x720. This is a transport smoke test only; it does not supersede the generator-native CRT-package plan or establish the current point-sampled CRT presentation as complete.
- Native production regression exercised TMNT II startup/gameplay, Star Trek battle controls and fire, both Treasure Island start modes, and The Flash gameplay/run/button state changes. A fresh NSMB3 run accepted Mode and showed the expected delayed gameplay-state change after Down, with the controller map and MiSTer configuration unchanged. The earlier verified SM530 hardware baseline remains documented above; the seam change is isolated to registered video timing.

## 2026-08-13 Star Fox HA1152/HMC completion

- Identified the Star Fox auxiliary sound device as the Hitachi HA1152 custom generator represented by MAME's `hmc` device. Unlike the undumped MSM6373 content, its external 128-byte `ha1152_001a` effect ROM is available with SHA-1 `5dfb15eee3c57bbca80f485f68442e5f7c6bc5e4`.
- Extended extraction and manifest data with a typed HA1152 `sfx` auxiliary ROM. The generator requires the canonical type, region, `0x80` size, and SHA-1, then copies the exact bytes to package offset `0x336400` and writes a canonical raw/HA1152 `GNWX` descriptor.
- Added `rtl/hmc_ha1152.sv`. Public Star Fox captures establish active-low falling-edge programs S2=`0x00`/3840 ticks, S3=`0x3C`/2880 ticks, and S4=`0x75`/480 ticks; simultaneous priority S4 > S2 > S3; later-edge preemption; a 256-tick immediate-high startup; low-seven-bit `x^7+x+1` terminal coding; bit-seven tone/noise selection; `x^9+x^5+1` noise; continuous pitch phase across commands/repeats; zero termination; and held-input repeat behavior.
- Generated the 312.5 kHz device oscillator as an exact rational enable (`625/196608`) from the 98.304 MHz system clock. The physical device has no reset pin, so oscillator and noise phase persist; reset follows live SM530 S outputs to avoid synthesizing a startup trigger.
- Added `tools/hmc_reference.py` as an independent ROM/trace oracle. The three authentic captures match with zero structural and edge mismatches and worst edge placement within 0.321 oscillator tick. Negative self-tests reject deliberately wrong trigger, divider, and boundary models; focused RTL replay covers the three authentic move, bomb, and kill paths.
- The absolute free-running noise seed/phase cannot be distinguished from the available captures. The RTL uses a documented deterministic nonzero seed without changing the observed sequence period or command behavior. Subjective audio/level comparison remains a listening or audio-capture check, not something inferred from digital debug state.

## 2026-08-13 independent Micro Vs. player controls

- Preserved MAME `PORT_PLAYER(n)` ownership on each manifest action instead of collapsing player identity during extraction.
- Added V2 feature bit `0x04` and a five-byte ownership map at header offsets `0x38-0x3C`. Its bits correspond to S0.0 through S7.3, B, BA, and ACL; only set electrical cells resolve from MiSTer's `joystick_1` bus.
- `gnw_boxing`, `gnw_dkong3`, and `gnw_dkhockey` all produce ownership bytes `04 0C 0C 00 00`. Their player-one cells continue to use `joystick_0`, so shared rows and package electrical polarity remain intact.
- Hooked `joystick_1` through the standard MiSTer `hps_io` boundary and the existing ten-position action resolver. Packages without valid V2 player metadata intentionally select player one for every cell, preserving the previous behavior.
- Extraction tests assert the exact player-two cells, generator tests assert the exact header contract and reserved bits, loader tests fail closed on malformed metadata, and the expanded input resolver regression completed 8,389,394 checks.

## 2026-08-13 native dual-resolution packages

- Replaced the experimental run-time 360x240/720x240 point-sampling path with generator-native CRT assets. The generator performs a second render from the MAME layout and original artwork, lays it out at effective square-pixel 320x240, then expands the complete composition and LCD segment map to a 720x240 transport.
- Added V2 feature bits `0x08`/`0x10` and canonical `GNWX` descriptors for the `0xFD200`-byte paired-RGB image at `0x336500` and RLE40 mask at `0x433700`. The mask descriptor records used bytes through one explicit zero entry; the fixed region has `0xF3C0` capacity and a required zero tail.
- Current packages end at `0x442AC0` and retain the legacy header/image/mask/ROM/audio layout at its prior offsets; only the versioned header metadata changes in that region. The core can therefore switch both timing and source banks without reloading the package, while old packages remain usable through the legacy CRT bridge.
- Strengthened the RTL loader and generator validator around the extension ABI. Native CRT assets are enabled only after both descriptors and both complete payload streams validate. Mask runs must be positive, in bounds, sorted, non-overlapping, explicitly terminated, and followed only by zero padding.
- Regenerated all 168 MAME 0.289 supported packages into repository `roms/`. Each is 4,467,392 bytes, for 750,521,856 bytes total. The aggregate SHA-256 of the sorted per-file SHA-256 lines is `5c225d2e54db638cfddbea7120689171f6b9840d2442fccb5bcb54fa8bf191d3`; legacy image, mask, ROM, melody, and voice payloads were verified byte-identical to their prior generated counterparts, apart from the versioned header and newly appended assets.
- Full-directory validation reports 168 dual-resolution packages. The largest native CRT mask is `tjpark` at 7,813 runs / `0x989E` used bytes versus `0xF3C0` capacity; voice command counts remain `kst25:12`, `ktmnt2:11`, and `ktopgun2:10`.

## 2026-08-13 final fixed-clock CRT architecture

- Selected a CTA/CEA-derived logical 720x240 timing: 720 active samples in 858 total (`19/62/57` front/sync/back) and 240 active lines in 262 total (`4/3/15`). At 13.500 MHz this is 15.7343 kHz horizontal and 60.0545 Hz progressive frame rate. `720x240p` is not itself a named CTA VIC; it is the conventional one-field progressive construction for a 15 kHz analog CRT path.
- Kept `720x240 CRT` as the default OSD mode and `720x720` selectable. CRT reports 4:3; the native canvas reports 1:1.
- An initial design attempted to select separate 98.304 MHz and 54 MHz PLL outputs with core-owned clock controls. The first complete Quartus map rejected it because the framework's HDMI/VGA clock controls would have been driven by another `ALTCLKCTRL`. That build produced no release artifact and the topology was removed.
- The final source architecture drives `CLK_VIDEO` directly from the legal 98.304 MHz core PLL output. Native video uses exact `/3` pixel enable pacing. CRT uses a modulo-8192 accumulator incremented by 1125, giving exactly 13.500 MHz on average with bounded seven/eight-clock enable gaps and no line/frame phase reset.
- With system and video ports on that same PLL net, removed the obsolete asynchronous pixel-toggle path. A synchronous next-pixel packet captures coordinate, blanking, data enable, and mode on each CE; LCD mask lookup and segment resolution consume the next two clocks, leaving the third native `/3` clock for final RGB.
- Mode changes wait for vertical blank, hold the raster, switch timing and image/mask banks coherently, settle the 720-pixel data path for 4096 system clocks, then release and toggle `new_vmode`. The video raster free-runs before package load so the default-mode OSD has timing even while content RGB is blank.
- The native `/3` mode retains the existing limitation that it lacks the optional four-source-clock margin for forced scandoubling/HQ2x. CRT's seven/eight-clock cadence has that margin.
- The final focused ModelSim source set compiled with zero errors and warnings. Passing regressions cover 22 timing-boundary checks, 8,205 exact-cadence/frame checks, 1,136 live-mode checks, 4,505 synchronous-packet checks, 22 X=0 line/frame checks, 7,110 pre-ROM-raster checks, six held-settle checks, 30 CRT SDRAM-routing checks, and 11 external RLE-to-segment-to-RGB alignment checks.
- A clean combined Quartus compile/report review and final analog CRT/direct-video hardware result for this fixed-clock revision were still pending when this entry was written. No final artifact hash, fit, timing, or final hardware claim is implied here.

## 2026-08-13 combined fixed-clock build and documentation audit

This entry supersedes the build-pending and unnamed-CTA statements in the immediately preceding historical entry.

- The logical CRT raster is exactly CTA VIC 8: 720x240p with a 4:3 picture aspect, 13.500 MHz logical pixel cadence, 720 active plus `19/62/57` horizontal front/sync/back porch samples, and 240 active plus `4/3/15` vertical front/sync/back lines. VIC 9 has the same raster with a 16:9 picture aspect; the core reports 4:3.
- The HA1152 RTL's rational-enable rate is a deterministic nominal 312.5 kHz chosen to align the available captures. The original device's analog RC oscillator can drift, so this is not a claim that physical parts have an exact fixed 312.5 kHz rate.
- The supported inventory is a 168-title MAME 0.289-derived set that includes the two retained homebrew entries, not 168 titles originating only in MAME 0.289. The package headers contain provenance `2600ff1` because that was committed `HEAD` during generation from the dirty worktree; it is a nearest-commit label and does not imply this work exists in commit `2600ff1`.
- The package-set aggregate SHA-256 remains `5c225d2e54db638cfddbea7120689171f6b9840d2442fccb5bcb54fa8bf191d3`. Its exact recipe is: sort bare filenames, emit UTF-8 lines containing lowercase per-file SHA-256, two spaces, filename, and LF, retain the final LF, then SHA-256 the resulting manifest.
- The first fixed-clock fit exposed a 43-level combinational divider generated by `(descriptor_length % 5) == 0` on the 98.304 MHz loader path. The replacement sums the four hexadecimal digits, which is equivalent because `16 mod 5 = 1`. The loader regression exhaustively compares all 65,536 16-bit values to mathematical divisibility and passes 65,553 checks total.
- The post-fix full Quartus 17.0.2 flow completed successfully with zero errors. `output_files/GameAndWatch.rbf` is 3,456,436 bytes with SHA-256 `06d19fba7b36d464e8810ed05e6d2184143399e91585aabbe6fd1bd4edecb2be`. Fit uses 13,794 ALMs (33%), 18,678 registers, 2,989,439 block-memory bits (53%), 377 RAM blocks (68%), 36 DSP blocks (32%), and three PLLs (50%).
- Stage reports contain 135 warnings in total. TimeQuest reports setup `-0.916 ns` / TNS `-3.417 ns` and issues a critical timing warning; this is inside the one-nanosecond setup tolerance accepted for this task but is not timing closure. Worst hold is `+0.245 ns`; recovery, removal, and minimum-pulse checks are positive. There are zero illegal or unconstrained clocks. The inherited top-level framework I/O remains incompletely constrained at 20 input and 87 output ports.
- Copied the final RBF byte-for-byte to `releases/GameAndWatch_20260813.rbf`; it retains the same 3,456,436-byte size and SHA-256 `06d19fba7b36d464e8810ed05e6d2184143399e91585aabbe6fd1bd4edecb2be`.
- Deployed the artifact only under the new USB-2 name `/media/fat/_Dev/GameAndWatch-final-06d19fba7b36.rbf`; the stable core and packages were not overwritten. Loading without the saved core CFG proved the compiled 720x240 default. The screenshot was full width with a clean right edge and no black x=511 column. The same process then switched live to 720x720 without reloading.
- Final-package smoke tests booted Star Fox/HMC, an MSM6373 voice title, an SM530 title, and Micro Vs. Boxing with player metadata. Independent P1/P2 behavior for all three Micro Vs. games had already passed on the immediately preceding compatible build. The reverse live native-to-CRT clear was not proven by the direct status helper because that attempt omitted MiSTer's status-mask semantics; reloading restored CRT safely.
- Restored MiSTer.ini, the saved core CFG, and the physical controller map byte-for-byte; removed temporary virtual inputs/maps and rebound the physical xpad. USB-1, stable RBFs, and stable packages were not touched. Physical analog CRT/direct-video lock and audible Star Fox HMC timbre/level remain pending user checks; neither is implied by simulation, the successful build, or HDMI capture.

## 2026-08-13 360x240 Direct Video revision

This entry supersedes the current-status claims in the preceding 720x240 entries. Those entries remain as a chronological record of the earlier design, build, and hardware tests; their RBF hash and USB-2 results do not apply to this source revision.

- Changed the default OSD mode to `360x240 CRT`, retaining live-selectable `720x720`. CRT now uses 360 active samples in 429 total with `10/31/28` horizontal front/sync/back samples, and 240 active lines in 262 total with `4/3/15` vertical front/sync/back lines. The resulting rates are 15.7343 kHz horizontal and 60.0545 Hz progressive frame.
- Kept raw `CLK_VIDEO` at 98.304 MHz. Native remains exact `/3`; CRT now uses a modulo-16384 accumulator incremented by 1125 for exactly 6.750 MHz average logical cadence and bounded fourteen/fifteen-clock enable gaps. This preserves framework clock legality, but it does not lower the raw clock presented to the video path. Direct Video compatibility is therefore a pending hardware result, not a consequence of the new logical width.
- Reworked the generator's second render to compose independently from the MAME layout and original source assets at effective square-pixel 320x240, then expand the entire composition and segment-ID map to 360x240. It does not downsample either the legacy 720x720 image or the superseded 720x240 CRT image.
- Preserved the fixed extension ABI and package size. The native CRT image remains at `0x336500`, now has canonical length `0x7E900` and dimensions 360x240, and ends at `0x3B4E00`. The retained mask offset is `0x433700`, so the entire intervening `0x7E900`-byte gap is zero-filled and validated. CRT mask capacity remains `0xF3C0`; every package still ends at `0x442AC0`.
- The current core rejects old 720x240 descriptors and falls back to retained legacy 720x720 assets at source `x * 2`, `y * 3`. The mask read-ahead step follows that two-source-pixel mapping so adjacent runs survive. Conversely, the superseded core rejects new 360 descriptors and uses its own legacy fallback. This keeps compatibility fail-closed in both directions.
- Added held-settle and first-frame fallback coverage so mode/bank/source-step preload follows the stable active mode throughout the 4096-clock hold rather than changing on the first displayed CRT packet.
- The focused ModelSim source set completes 93,740 checks with zero errors and zero warnings. It covers counts, exact cadence, live mode switching, loader validation, native/legacy image and mask paths, packet alignment, held-settle preload, adjacent legacy runs, and external segment-to-RGB alignment. The loader's exhaustive descriptor-length regression now completes 65,555 checks.
- Regenerated and validated all 168 packages, then copied them into the clean repository `roms/` baseline. Each is 4,467,392 bytes (`0x442AC0`), totaling 750,521,856 bytes. The ordinal-filename-sorted lines aggregate SHA-256 is `17a70cfd698464cdc020f4a1ae1de4cf0831878be253b6deccca4da16d9b9e67`; `tjpark` remains the largest CRT mask at 7,813 runs / `0x989E` used bytes against `0xF3C0` capacity.
- Audited Nelsonic Super Mario Bros. 3 startup and sound behavior. There is no Start combo: wait at least five seconds for the all-segment power-on test, tap Button 1/Xbox-style B for Mode, then press D-pad Down. The program ignores Mode during the test interval. A normal start can remain silent because firmware RAM `0x37` bit 3 defaults clear and the intro path deliberately branches around `SME`. The authentic UI enables it by cycling to alarm, holding Button 2/A (Set) until the alarm display blinks, releasing Set, then cycling Mode back to game before pressing Down. Exact MAME and RTL traces show that path sets the bit, executes `SME`, and produces melody output; forcing sound in the core would be inaccurate.
- The clean Quartus 17.0.2 full flow completed with zero errors. `output_files/GameAndWatch.rbf` and `releases/GameAndWatch_20260813_360.rbf` are 3,505,636 bytes with SHA-256 `6ec3a12ffdada895573a79c85a58c76e652d6732d3119fbaa04c318f044bb3a8`. Fit uses 13,998 ALMs (33%), 18,581 registers, 2,989,439 memory bits (53%), 377 RAM blocks (68%), 36 DSPs (32%), and three PLLs (50%). Setup is `-0.727 ns` / TNS `-1.673 ns`, within the accepted one-nanosecond margin but not strict timing closure; hold is `+0.249 ns`. Star Fox HMC timbre/level remains a listening/capture check; Super Mario Bros. 3's melody path is proven digitally through its authentic alarm-setting state. No access to USB-1 is authorized.
- Installed the release only as `/media/fat/_Dev/GameAndWatch-360-6ec3a12ffdada.rbf` on USB-2 and verified its complete remote SHA-256. Seven representative regenerated packages were uploaded to the clean `To Test` directory and verified. The superseded hash-qualified 720 build was hash-checked and removed; the stable `GameAndWatch.rbf` rollback remains untouched.
- A no-CFG load captured the compiled default at exactly 360x240 with clean internal columns and no old x=511 seam. Nelsonic Super Mario Bros. 3 reached visible gameplay after waiting six seconds, pressing Button 1/B, then Down. The authentic alarm-setting sound-enable sequence completed, but no hardware audio capture or listener was available.
- A live 360x240-to-720x720 transition passed without reloading. Attempts to clear the bit through the direct status helper left byte-identical 720x720 captures, so the reverse hardware direction remains unproven even though both directions pass simulation. Direct Video briefly ran without crashing and was restored to `direct_video=0`, but screenshots cannot establish analog adapter/CRT lock; that remains a user-observed result.
- Restored MiSTer.ini, the active controller map, and the physical xpad binding to their exact baseline hashes. Then deliberately cleared only the saved Native Video selection bit so the 16-byte core CFG is all zero (SHA-256 `374708fff7719dd5979ec875d56cd2286f6d3cf7ec317a3b25632aab28ec37bb`) and future loads select the requested 360x240 default. The live core was left on the 360 Star Fox test.

## 2026-08-13 fixed-54 MHz Direct Video transport

This entry supersedes the current architecture, build-artifact, and Direct Video status claims in the preceding 360x240 entry. The older entries remain as a chronological record; their RBF sizes, hashes, timing reports, and hardware observations do not apply to this fixed-54 source revision.

- Confirmed that Quartus 17 maps the core PLL requested as 98.304 MHz to an actual 98.3203125 MHz (`12585/128 MHz`) clock. To prevent long-term packet-FIFO drift, native source pacing now uses `524288/1573125` for exactly 32.768 MHz, while the generator-native 360x240 CRT source uses `288/4195` for exactly 6.750 MHz. Native gaps are three/four core clocks and CRT gaps remain fourteen/fifteen clocks.
- Corrected the HA1152/HMC nominal oscillator enable to `8/2517` of the same mapped 98.3203125 MHz clock, which is exactly 312.5 kHz. This supersedes the earlier nominal-clock `625/196608` implementation ratio; the physical chip still uses an analog RC oscillator that can drift, so the deterministic RTL value is not a claim that every original part ran at an exact fixed rate.
- Added a dedicated, free-running 54.000 MHz video PLL that drives `CLK_VIDEO` directly. Complete `{SOF, HS, VS, HBlank, VBlank, DE, RGB}` packets cross from the compositor through a dual-clock FIFO; the core does not mux clocks or cascade a clock-control block ahead of the framework's own selector.
- CRT output is a 720-sample transport at exact `CE_PIXEL` /4, or 13.500 MHz. Every 360-wide source pixel is emitted on a pair of consecutive transport samples, so the paired package assets retain their intended geometry while the external timing uses 720 active plus `19/62/57` horizontal front/sync/back samples and 240 active plus `4/3/15` vertical lines.
- At the raw 54 MHz transport clock, the horizontal line is exactly 2880 active plus `76/248/228` front/sync/back clocks, or 3432 clocks total. With 262 lines, this is 15.7343 kHz horizontal and 60.0545 Hz progressive frame timing.
- Native 720x720 is still emitted through the same fixed-clock bridge, using an exact-average `2048/3375` enable accumulator for 32.768 MHz and preserving the source timing fields. It remains available through the normal MiSTer scaler path but is intentionally not supported over raw Direct Video. The core does not force that unsupported mode black.
- Direct Video's `dv_de` behavior is framework-owned. The current `sys/sys_top.v` reconstructs data enable from the observed sync sequence instead of forwarding the core's `VGA_DE` directly, and it supplies no mode-specific VIC metadata. The exact 54 MHz clock and sync totals address the raw horizontal-timing problem, but adapter/CRT lock remains a hardware result rather than a simulation or HDMI-screenshot claim.
- Focused source-packet simulation passes 52,012 checks with zero errors and zero warnings, covering SOF/control/RGB alignment, exact native and CRT source cadence including both bounded gap lengths, held output, and content-reset behavior. The fixed-clock bridge also passes vendor-`dcfifo` simulation. Final Quartus fit/timing metrics, release artifact size/hash, and hardware Direct Video validation are pending and will be recorded separately after the clean flow.

## 2026-08-13 fixed-54 MHz full-flow audit

This entry supersedes only the build-pending statement at the end of the immediately preceding fixed-54 architecture entry. The earlier entries remain unchanged as a chronological record.

- The clean combined Quartus 17.0.2 flow completed with zero errors and 138 warnings. `output_files/GameAndWatch.rbf` and `releases/GameAndWatch_20260813_54MHz.rbf` are byte-identical at 3,490,376 bytes with SHA-256 `D44B8CB83D29EF1A0CDE78E3CE22717FBE601E89BB93CAD11B06B9093FDDDFCF`.
- Fit uses 13,930 ALMs (33%), 18,783 registers, 3,018,021 block-memory bits (53%), 379 RAM blocks (69%), 36 DSP blocks (32%), and four PLLs (67%). The fourth PLL is the dedicated fixed-54 video PLL described above.
- TimeQuest reports `-0.645 ns` worst setup slack and `-2.891 ns` TNS across 14 endpoints in the 98.3203125 MHz core domain. The worst path is `ioctl_addr[23]` to `sdram.SDRAM_A[8]`; the remaining negative endpoints are other core SDRAM-address and source-packet paths. All endpoints satisfy this task's accepted one-nanosecond margin, but the build is not strict zero-slack timing closure.
- The 54 MHz video domain has `+8.337 ns` setup slack. Worst hold is `+0.246 ns`, recovery `+2.975 ns`, removal `+0.716 ns`, and minimum pulse width `+0.925 ns`. There are zero illegal or unconstrained clocks; the inherited framework still reports 20 input and 87 output ports without I/O constraints.
- The fail-closed transport SDC matched all intended fitted collections. Each of the four Gray-pointer crossing arc sets contains 11 paths; the clock-local reset exceptions leave zero recovery/removal violations; the mode-toggle and same-domain frame-status links remain timed. The final audit finds zero non-FIFO setup/hold paths in either direction between the core and video clocks. The transport/CDC work is therefore clean despite the separate core-domain setup result.
- No MiSTer, Morph, Direct Video, or CRT deployment/test was performed with this fixed-54 artifact. Physical adapter/CRT lock and audible Star Fox HMC timbre/level remain user checks; neither is implied by the build, timing report, or prior USB-2 results from superseded artifacts.

## 2026-08-13 fixed-54 CRT raster recovery correction

Hardware testing of the preceding RBF showed a readable but vertically unstable
Direct Video image. The Morph 4K alternated its MiSTer DV1 report between
`720x240` and an impossible `720x355`, proving that the observed frame boundary
was being interrupted rather than merely labeled with the wrong aspect ratio.

- Changed CRT timing ownership in `video_transport_54.sv`: after CRT mode is
  active, its 54 MHz `/4` enable, 858x262 counters, sync, blanking, and DE run
  continuously through packet-FIFO search, prefill, hold, and recovery.
- FIFO faults now blank RGB content without suppressing or restarting the CRT
  raster. Content still reacquires from a source SOF, but its recovery cannot
  stretch a line, join two frames, or make MiSTer's resolution measurement
  count an arbitrary number of DE lines between vertical-sync edges.
- Removed the steady-state CRT SOF watchdog. With a show-ahead asynchronous
  FIFO, using its head SOF bit as a second frame-clock authority could falsely
  invalidate an otherwise balanced stream at a packet boundary. FIFO empty,
  high-water/overflow, mode, and hold handling remain the content-validity
  mechanisms.
- Added an exact-ratio multiframe regression using the fitted 98.3203125 MHz to
  54 MHz clock relationship and the production source NCO. Three complete
  output frames pass 5,395,106 checks with FIFO occupancy fixed at 512 words.
- Extended forced FIFO recovery coverage to assert uninterrupted CRT CE, HS,
  VS, DE, and blanking until content returns. The behavioral model passes
  3,461,227 checks; the Quartus 17 `dcfifo` model passes the same assertions
  with only its two known internal model warnings.

This correction supersedes the preceding fixed-54 RBF. The resulting Quartus
17.0.2 test build completed with zero errors and 138 warnings. It is 3,526,984
bytes with SHA-256
`c3d31bce99b2877f2cdec5ff7827bf70b064074780ec7b7de96ee6e180916410`
and is archived as `releases/GameAndWatch_20260813_54MHz_rasterfix.rbf`.

The 54 MHz video domain has `+8.292 ns` setup slack; all guarded FIFO/CDC
collections matched and the four Gray-pointer arc sets contain 11 paths each.
The unrelated core ROM-load-to-SDRAM path is `-1.046 ns` / TNS `-2.379 ns`,
which is 0.046 ns outside the usual one-nanosecond acceptance floor. The RBF is
therefore a hardware test build rather than strict timing signoff.

USB-2 deployment is hash-verified at
`/media/fat/_Dev/GameAndWatch-54MHz-rasterfix-c3d31bce99b2.rbf`. The stable RBF
was not overwritten. A Morph/Direct Video hardware retest is still required
before claiming stable lock.

## 2026-08-13 actual 360x240 analog transport correction

Hardware review showed that the preceding fixed-54 correction still presented
720 logical active samples to Direct Video by duplicating every 360-wide source
pixel. That contradicted the requested analog-facing resolution and continued
to be reported as 720x240. This entry supersedes that current-status claim.

- Changed CRT output from `/4` to `/8` on the fixed 54.000 MHz clock, producing
  an actual 6.750 MHz pixel-enable cadence.
- Changed the output raster from 720 active / 858 total to 360 active / 429
  total and removed two-sample pixel duplication. Each source packet is now
  consumed once.
- Horizontal porches are 10/31/28 logical samples. At the raw clock they are
  80/248/224 clocks around 2880 active clocks, preserving the 3432-clock line,
  15.7343 kHz horizontal rate, and 60.0545 Hz progressive frame rate while
  exposing 360 logical active pixels.
- The three-frame exact-rate regression passes 2,697,554 checks with FIFO
  occupancy fixed at 511 words. Forced recovery passes 2,224,859 checks with
  both the behavioral and Quartus 17 vendor FIFO models.
- The clean Quartus 17.0.2 build is 3,489,552 bytes with SHA-256
  `616ff3cfb349682e6f1c6c6bb43db7c6e122c5aa2e22b78f524fca0bd0ee1da0`.
  Fit uses 14,094 ALMs, 18,713 registers, 3,018,021 memory bits, 379 RAM blocks,
  36 DSP blocks, and four PLLs. Video-domain setup slack is +7.650 ns; core
  setup is -0.707 ns / -1.523 ns TNS, within the explicit one-nanosecond
  acceptance floor but not strict zero-slack closure.
- USB-2 deployment is hash-verified as
  `/media/fat/_Dev/GameAndWatch-54MHz-360-616ff3cfb349.rbf`. The two superseded
  fixed-54 test files were removed; the stable and raw-360 rollback cores remain.

## 2026-08-13 request-locked CRT source and frame alignment

USB-2 testing of the preceding actual-360 artifact reproduced the reported
instability even with Direct Video disabled. Nine-second boot settling followed
by screenshots every four seconds showed that the Star Fox presentation was
being split and rolled: consecutive stable-content captures advanced by 19
pixels horizontally and 11 lines vertically per interval. This proved the
problem was inside the core's source/output handoff rather than the Morph or
analog adapter.

- Removed production CRT's independent source NCO authority. The 54 MHz output
  bridge now toggles one source request for every `/8` CRT output slot; a
  two-flop synchronizer converts each toggle into exactly one source packet.
- Added a CRT align state. Search/prefill continues requesting packets until a
  complete source SOF is at the FIFO head. The bridge then stops requesting and
  holds that SOF until the next local 429x262 frame boundary before entering
  run. Recovery can therefore neither drift in average rate nor splice a
  source frame into an arbitrary output coordinate.
- Added fail-closed TimeQuest coverage for the request-toggle first stage and a
  fitted audit of its timed synchronizer link. Existing Gray-pointer bounds,
  reset exceptions, and framework CDC constraints remain intact.
- A deliberately detuned source-clock multiframe test passes 2,697,554 checks
  with FIFO occupancy fixed at 511, proving frequency/phase error cannot
  accumulate. Forced recovery with absolute RGB-coordinate assertions passes
  2,900,283 checks under both the behavioral and Quartus 17 vendor `dcfifo`
  models. Seven affected compositor/video regressions and the integrated top
  parse also pass with no new errors or warnings.
- The coherent Quartus 17.0.2 build completed with zero errors and 138 warnings.
  `output_files/GameAndWatch.rbf` and
  `releases/GameAndWatch_20260813_54MHz_requestlock.rbf` are byte-identical at
  3,490,660 bytes with SHA-256
  `08d6a4ba78ec7c96ed11c943178a5ad8a380bf9decf065e2fc491be467706656`.
  Fit uses 14,213 ALMs, 18,752 registers, 3,018,021 memory bits, 379 RAM blocks,
  36 DSP blocks, and four PLLs. Video setup is +8.124 ns; hold is +0.234 ns,
  recovery +3.413 ns, removal +0.670 ns, and minimum pulse +0.925 ns.
- Core setup is -1.009 ns / -2.496 ns TNS on an unrelated loader-to-SDRAM path,
  0.009 ns outside the usual one-nanosecond floor. This remains a
  hash-qualified smoke-test artifact rather than a promoted timing release.
- Deployed only as
  `/media/fat/_Dev/GameAndWatch-54MHz-360-requestlock-08d6a4ba78ec.rbf` on
  USB-2, with Direct Video disabled and the saved zero CFG unchanged. Nine
  360x240 Star Fox screenshots spanning 32 seconds were byte-identical, each
  SHA-256
  `8e375ba3b4b6009e45b664ee5f2a53d8bb9cb9e1e6503c1ef3ca2030ae25ac4b`.
  The internal rolling defect is therefore no longer reproducible. Actual
  Morph/analog lock remains the next user-observed hardware gate.

## 2026-08-13 release debug gating and loader timing cleanup

- Added the documented `CORE_ENABLE_DEBUG_OVERLAY` build gate across the OSD,
  core capture state, and video pixel grid. Normal/release QSF builds leave the
  macro undefined; a commented QSF assignment remains for development builds.
  The release and opt-in paths compile independently, the normal pixel path
  passes 3,785 checks, and the enabled overlay/source-packet path passes 52,012
  checks.
- Registered each accepted package image `{address,data}` for one clock before
  issuing it to SDRAM p0. `ioctl_wait` now covers both the one-entry pending slot
  and controller busy time. The randomized refresh/backpressure test passes 64
  words and 322 checks, including a refresh beginning between HPS acceptance
  and the registered p0 request.
- The coherent Quartus 17.0.2 flow completed with zero errors. The final fit is
  13,443 ALMs (32%), 18,115 registers, 3,017,509 block-memory bits (53%), 379 RAM
  blocks (69%), 36 DSP blocks (32%), and four PLLs (67%). The release artifact
  `releases/GameAndWatch_20260813_nodebug_timing.rbf` is 3,488,500 bytes with
  SHA-256
  `5f38deb3152b422e2d999a02ab0f4e50de7deb3572834073d74fb45aa059e14b`.
- The video domain closes at +8.155 ns. Core setup improves to -0.605 ns / TNS
  -1.917 ns, within the accepted one-nanosecond floor but not strict zero-slack
  closure. Hold is +0.246 ns, recovery +3.538 ns, removal +0.616 ns, and minimum
  pulse width +0.925 ns. The former live `ioctl_addr` loader path is absent;
  remaining negative endpoints are true one-cycle `READ_OUTPUT`/delay-state to
  SDRAM address/command paths inside the vendored controller. Further changes
  there were rejected as disproportionate regression risk for a half-nanosecond
  accepted-margin miss.
- Final fitted CDC audit passes all four 11-path FIFO arc sets, retains the
  request/mode/status synchronizer links, finds zero unexpected non-FIFO
  core/video setup or hold paths, and leaves no intentional async-reset
  recovery/removal residue. The new RBF has not been deployed or hardware-smoked;
  the prior request-locked artifact remains the latest USB-2 hardware evidence.

## 2026-08-14 tester display and artwork corrections

- Reproduced the reported live-mode failure on USB-2. The old transport left
  the 360x240 raster running while content stayed blank because the source
  waited for an additional externally paced CRT pixel before acknowledging a
  vertical-blank hold. The source now freezes on the next source clock after
  synchronized hold; its counters and packet bus are already stable between
  pixel enables.
- Native FIFO acquisition no longer depends on an SOF marker surviving an
  asynchronous reset. Native packets contain complete sync, blanking, DE, and
  RGB state, so cold starts and held releases prefill from any buffered packet
  and settle at the following sync. CRT recovery retains strict SOF/local-frame
  alignment because its output raster is independently owned.
- Behavioral and Quartus vendor-FIFO bidirectional tests pass more than 5.32
  million checks. A separate cold-start test releases the bridge with the
  native source already mid-frame and reaches active RGB under both FIFO
  models. The timing regression passes 528,490 checks.
- The zero-error Quartus 17.0.2 build is 3,489,604 bytes with SHA-256
  `2b492710cd75eff518eba28019a7572e2c391e4af6622de57470e2d08fb36178`.
  Fit uses 13,357 ALMs, 18,109 registers, 3,017,509 block-memory bits, 379 RAM
  blocks, 36 DSPs, and four PLLs. Video setup is +8.324 ns. Core setup is
  -0.423 ns / -4.014 ns TNS, within the accepted one-nanosecond floor but not
  strict timing closure; hold, recovery, removal, and pulse width are positive.
- USB-2 verified both a live CRT-to-native transition and a cold native boot.
  Both produced the same nonblack 720x720 Star Fox capture (`b7f269af...`).
  Reloading the byte-exact restored zero CFG returned the known-good 360x240
  capture (`8e375ba3...`). The active test core is
  `/media/fat/_Dev/GameAndWatch-testerfix2-2b492710cd75.rbf`.
- Corrected LCD visibility per segment ID rather than per whole screen. Crab
  Grab, Pinball, and Spitball Sparky now expose their previously background-
  colored gameplay segments. Nu Pogodi is rebuilt from the complete
  `alternates/hydef` artwork selected by the extractor-generated manifest.
  All 168 packages validate, their new ordinal aggregate is
  `ed6e4a4544eec5cd0443134bb26424cac6a59fad84241006431ab673a31bd4ea`,
  and the refreshed manufacturer-organized `Roms.zip` hash is
  `712790fcf112c972ee42859515f670ff3143d821ac97baaebc20a40d1c96106b`.
- Nelsonic Super Mario Bros. 3 remains intentionally unchanged: the normal
  game path can be silent because firmware boots with its sound/alarm bit
  clear. The authentic alarm-setting UI path sets the bit and executes `SME`;
  forcing sound in the core or package would be inaccurate.

## 2026-08-14 Nelsonic SMB3 default sound compatibility

- Superseding the authentic-default decision immediately above, the user
  explicitly chose a convenience default: the generated `nsmb3` package now
  carries descriptorless feature bit `0x20`. For that package only, SM530 CPU
  reads of firmware RAM `0x37` see bit 3 asserted. Stored RAM, the exact
  `633.program`, and exact `633.melody` bytes remain unchanged; the firmware
  reaches its existing `SME` instruction rather than receiving a synthetic
  audio trigger or patched opcode.
- Added `Audio: On/Mute` at MiSTer status bit 11. It defaults on and gates only
  the final signed audio output, so muting does not perturb melody, voice, HMC,
  CPU, or RAM state.
- The exact-ROM RTL start regression waits through boot, presses Mode and Down,
  observes `SME`, and counts 15,402 R-output transitions. The focused RAM test
  verifies the override is limited to SM530 address `0x37` bit 3; SM510-family
  ACL/opcode regressions remain clean. The generator passes 29 locked tests,
  TypeScript parser tests and strict typecheck, and validates all 168 packages.
- Header refresh changed only SMB3 feature byte `0x30` plus the common generator
  stamp relative to the previous SMB3 file; payload bytes are unchanged. The
  168-package ordinal aggregate is
  `c6aca96b6be2ccb58bb8f9b2c6a80e46cd4ba2ad00eaf267a719b772666a67ae`.
  The refreshed manufacturer archive SHA-256 is
  `c1cd1e4f01b6c37bdf9c7b66cf2a13afcbb62c97421356d2bc0801b167449a28`.
- The zero-error Quartus 17.0.2 build produced
  `releases/GameAndWatch_20260814_sounddefault.rbf`, 3,503,712 bytes, SHA-256
  `01dbba785ae1dad7a9f8c542ae2511cd700befb3a17783dd331659f5b96c02d8`.
  Fit uses 13,534 ALMs, 18,197 registers, 3,017,509 block-memory bits, 379 RAM
  blocks, 36 DSPs, and four PLLs. Video setup is `+8.319 ns`; core setup is
  `-0.108 ns` / TNS `-0.226 ns`, within the accepted one-nanosecond floor but
  not strict zero-slack closure. Hold, recovery, removal, and minimum-pulse
  checks are positive. This RBF has not yet been deployed or audibly checked.

## 2026-08-14 native 720x720 elastic-buffer stabilization

- USB-2 screenshot diagnostics reproduced intermittent native partial-black and
  full-black frames, then identified every bad transition as packet-FIFO empty;
  overflow, SOF mismatch, mode/hold changes, and reset were not observed.
- Kept the externally visible raster unchanged at 720x720 active, 756x730
  total, exactly 32.768 MHz, and approximately 59.375 Hz. Native timing is
  output-owned, so recovery can black RGB without disturbing sync, blanking,
  DE, pixel enable, or raster coordinates.
- Changed only the internal native producer to exact core-clock `/3` pacing:
  `524375/1573125`, or 32.7734375 MHz from the mapped 98.3203125 MHz clock.
  This is a deterministic 5,437.5-packet/s lead and preserves the compositor's
  required minimum three-core-clock pixel interval.
- Added read-domain hysteresis: pause the native source at FIFO occupancy 768
  and resume it at 640. The pause freezes only the source NCO and compositor
  coordinates; it does not gate FIFO acceptance or the output raster. Its
  long-term effective producer rate therefore equals the consumer rate.
- Updated timing, rate-balance, source-packet, bidirectional transport, and
  native recovery regressions. The native test exercises a complete 768-to-640
  pause cycle, ordered full frames, and forced overflow recovery under both the
  behavioral and production Quartus 17 FIFO models.
- The clean Quartus 17.0.2 flow completed with zero errors and produced
  `output_files/GameAndWatch.rbf`, 3,494,544 bytes, SHA-256
  `16e14b86eba8c9422f9c6f9e966ba5c01627659193d6edd7070912b556dbef6f`.
  Fit uses 13,563 ALMs, 18,176 registers, 3,014,437 memory bits, 379 RAM blocks,
  36 DSP blocks, and four PLLs. Core setup is -0.401 ns / TNS -0.587 ns,
  within the accepted one-nanosecond floor but not strict zero-slack closure;
  hold +0.206 ns, recovery +2.591 ns, and removal +0.689 ns are positive.
- Deployed the hash-qualified RBF only to USB-2 as
  `/media/fat/_Dev/GameAndWatch-native-elastic-16e14b86eba8.rbf`. With Direct
  Video disabled and Star Fox selected, 60 one-second-spaced 720x720 captures
  contained no partial or black frames. The first was the normal startup
  transition; captures 1-59 were byte-identical with SHA-256
  `b7f269af912bef9752429730f35f5b148af60ac10d60445d3b22065d24c01fcc`.
  The saved zero CFG and prior core were restored exactly after the test.
