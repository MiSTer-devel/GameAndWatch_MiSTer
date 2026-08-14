# CRT Video Mode

The core has two package-native video modes. `360x240 CRT` is the default; `720x720` remains selectable from the `Native Video` OSD item. The source compositor and fixed-clock output transport are deliberately separate:

| Mode | Package/source raster | Source cadence | Output raster | Output cadence | Horizontal | Frame |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `360x240 CRT` | 360 x 240 active, 429 x 262 total | exactly 6.750 MHz average | 360 x 240 active, 429 x 262 total | 6.750 MHz (`CE_PIXEL` /8 at 54 MHz) | 15.7343 kHz | 60.0545 Hz |
| `720x720` | 720 x 720 active, 756 x 730 total | 32.768 MHz | source timing preserved | exactly 32.768 MHz average | 43.344 kHz | 59.375 Hz |

CRT mode reports 4:3 to the MiSTer scaler. The 720x720 mode reports 1:1.

## Why 360x240

The package-native CRT canvas is 360 pixels wide so its artwork and segment map are generated at the requested resolution. Its source porches are:

```text
Horizontal: 360 active + 10 front + 31 sync + 28 back = 429
Vertical:   240 active +  4 front +  3 sync + 15 back = 262
```

At exactly 6.750 MHz, a 429-sample line is 15.7343 kHz and a 262-line frame is 60.0545 Hz. A 360-pixel active picture is therefore compatible with the same 15 kHz CRT timing family; it is not a high-scan-rate mode merely because it is generated digitally.

The fixed-clock bridge emits every completed 360-wide source pixel exactly once:

```text
Logical transport: 360 active + 10 front + 31 sync + 28 back = 429
Raw 54 MHz clocks: 2880 active + 80 front + 248 sync + 224 back = 3432
Vertical:          240 active +  4 front +   3 sync +  15 back = 262
```

The raw line is therefore exactly 3432 clocks at 54.000 MHz, including 2880 active clocks. This produces the same 15.7343 kHz horizontal and 60.0545 Hz progressive frame rates as the source while exposing 360 logical active pixels to Direct Video. The raw porch split is `80/248/224`, derived from the requested 360-sample raster; it is deliberately not the superseded 720-sample CTA-style split.

Compatibility with a particular CRT, transcoder, HDMI-to-analog adapter, or MiSTer Direct Video path is still a hardware result. A successful scaler/HDMI capture does not prove raw analog lock. MiSTer's current `sys_top.v` also does not forward the core's `VGA_DE` directly in Direct Video mode: it reconstructs `dv_de` from the observed horizontal and vertical sync sequence. The exact clock and sync totals are intentional inputs to that framework logic, but they do not constitute a claim that every downstream HDMI converter will recognize the mode.

## Fixed Output Clock and Pixel Enables

Quartus 17 maps the core PLL requested as 98.304 MHz to an actual 98.3203125 MHz (`12585/128 MHz`) clock. Native pacing is derived from that mapped value, while production CRT pacing is locked to requests from the output transport:

- native uses an increment of 524288 modulo 1573125 for exactly 32.768 MHz, with three/four-clock gaps;
- CRT toggles one request for each fixed 54 MHz `/8` output slot; a two-flop synchronizer turns each toggle into one source pixel request.

Complete timing/control/RGB packets cross to the output domain through a dual-clock FIFO. The CRT producer is therefore demand-locked to the consumer rather than merely frequency-matched to it.

`CLK_VIDEO` is a separate, free-running 54.000 MHz PLL output connected directly to the MiSTer `emu` boundary. It is not selected through a core-owned clock mux, because the framework places its own clock selector after that boundary. The output bridge provides:

- CRT: exact `CE_PIXEL` /8, or 6.750 MHz, with one output sample for each 360-wide package/source pixel;
- native: exact-average 32.768 MHz packet consumption using a `2048/3375` accumulator on 54 MHz, preserving the existing 720x720 timing fields for normal scaler use.

Both modes are emitted by the fixed-clock bridge, but raw Direct Video support is intentionally claimed only for `360x240 CRT`. The live-selectable 720x720 mode is not required or supported over Direct Video; it remains available through MiSTer's scaler path.

## Generator-Native Dual Assets

Current packages carry two independent image/mask pairs:

- the original `720x720` component-paired RGB image and fixed RLE mask;
- a `360x240` image at `0x336500` and native CRT RLE mask at `0x433700`.

The generator performs a second composition directly from the selected MAME layout and source SVG/raster assets. It lays the CRT presentation out on an effective square-pixel 320x240 canvas, including the LCD artwork, then expands the completed composition and segment-ID map to 360x240. It does not downsample the already-rasterized 720x720 package image or the superseded 720x240 transport.

The paired-RGB CRT image is `0x7E900` bytes and ends at `0x3B4E00`. The fixed ABI retains the CRT-mask offset at `0x433700`, so the intervening `0x7E900` bytes must be zero. The loader accepts native CRT assets only after validating both feature bits, both canonical descriptors, an in-order complete image stream, that entire zero gap, in-bounds row-major mask runs, one explicit zero terminator, and a zero-filled mask tail.

See [Package Format](format.md) for the exact offsets and descriptor fields.

## Live Mode Switching

Changing `Native Video` does not reload the `.gnw` file. The core:

1. waits for vertical blank;
2. holds and blanks the raster;
3. changes timing and image/mask bank together;
4. allows 4096 system clocks for the new source and mask state to preload;
5. releases the raster and toggles MiSTer's `new_vmode` indication.

Coordinates, blanking, data enable, and mode identity are captured as one synchronous next-pixel packet. The preload path uses the stable active mode throughout hold/settle, including the old-package fallback, so a live switch does not defer the legacy X-step change until the first displayed pixel.

The output bridge flushes and rearms its asynchronous packet FIFO around a mode change, searches for the next complete source start-of-frame packet, and prefills while requesting CRT source pixels. It then holds that source SOF and stops requesting new packets until the next local 429x262 frame boundary. Only then does it enter run state and consume one packet per `/8` output slot. Once CRT mode is active, its `/8` enable, counters, sync, blanking, and DE continue independently through FIFO search or recovery; missing packet content is blacked without interrupting the raster. This prevents a recovered source frame from being spliced into an arbitrary output coordinate. `CLK_VIDEO` remains fixed at 54.000 MHz in both menu modes.

Raster timing free-runs before a package is loaded and while content is reset. RGB is blanked independently, keeping OSD timing alive at boot.

## Older and Newer Package Compatibility

V1 packages and earlier V2 packages remain loadable. Their 720x720 path is unchanged. If CRT mode is selected without valid native 360 descriptors and payloads, the core reads the old 720x720 artwork/mask at source `x * 2`, `y * 3`. The mask reader advances two source pixels per 360 output pixel so adjacent legacy runs are preserved.

The extension offsets and fixed package end remain unchanged from the superseded 720x240 package revision. That older core rejects a new 360 descriptor's length/dimensions and also falls back to the retained legacy assets. Compatibility is therefore fail-closed in both directions; the native 360 assets require the current core, while neither package generation strands the legacy 720x720 presentation.

## Current Verification Boundary

The source-packet audit completes 52,012 checks with zero errors and zero warnings. It verifies atomic start-of-frame/control/RGB alignment, exact native cadence, request-locked CRT cadence, packet hold behavior, and content-reset blanking. A deliberately detuned source-clock multiframe regression passes 2,697,554 checks across three complete CRT frames with FIFO occupancy fixed at 511 words. Forced recovery passes 2,900,283 checks with uninterrupted CRT CE/sync/DE/blanking plus absolute RGB-coordinate assertions, source-SOF hold, and local-frame alignment using both the behavioral FIFO and Quartus 17's vendor `dcfifo` model. The existing focused timing, mode-change, preload, loader, mask, and segment-to-RGB regressions remain applicable.

The regenerated set contains 168 packages of `0x442AC0` bytes each and passes full-directory validation. Its ordinal-filename-sorted lines aggregate SHA-256 is `17a70cfd698464cdc020f4a1ae1de4cf0831878be253b6deccca4da16d9b9e67`.

The debug-free Quartus 17.0.2 build completed with zero errors. `output_files/GameAndWatch.rbf` and `releases/GameAndWatch_20260813_nodebug_timing.rbf` are byte-identical at 3,488,500 bytes with SHA-256 `5F38DEB3152B422E2D999A02AB0F4E50DE7DEB3572834073D74FB45AA059E14B`. Normal builds leave `CORE_ENABLE_DEBUG_OVERLAY` undefined, so the diagnostic menu/capture/grid is not synthesized. The fit uses 13,443 ALMs (32%), 18,115 registers, 3,017,509 block-memory bits (53%), 379 RAM blocks (69%), 36 DSP blocks (32%), and four PLLs (67%).

TimeQuest reports `+8.155 ns` setup slack for the 54 MHz video domain. All custom packet-FIFO, reset, mode-toggle, request-toggle, and framework CDC guards matched their intended fitted nodes; the final audit found all four Gray-pointer arc sets at 11 paths, the request-toggle synchronizer timed, and zero unexpected non-FIFO setup/hold crossings. Worst overall hold is `+0.246 ns`; recovery is `+3.538 ns`, removal `+0.616 ns`, and minimum pulse width `+0.925 ns`.

The 98.3203125 MHz core domain reports `-0.605 ns` / `-1.917 ns` TNS, within the accepted one-nanosecond task floor but not strict zero-slack closure. Registering the package image-write address/data removed the former live `ioctl_addr` to SDRAM-pin critical cone; remaining misses are real one-cycle paths wholly inside the vendored SDRAM command/address state machine. The new RBF has not been deployed. The preceding request-locked build remains hash-verified on USB-2 at `/media/fat/_Dev/GameAndWatch-54MHz-360-requestlock-08d6a4ba78ec.rbf`; with Direct Video off, nine Star Fox screenshots at four-second intervals were byte-identical 360x240 frames. Morph/analog lock for the actual 360-wide transport remains a user test.
