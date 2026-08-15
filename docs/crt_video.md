# CRT Video Mode

The core has two package-native video modes. `360x240 CRT` is the default; `720x720` remains selectable from the `Native Video` OSD item. The source compositor and fixed-clock output transport are deliberately separate:

| Mode | Package/source raster | Source cadence | Output raster | Output cadence | Horizontal | Frame |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `360x240 CRT` | 360 x 240 active, 429 x 262 total | exactly 6.750 MHz average | 360 x 240 active, 429 x 262 total | 6.750 MHz (`CE_PIXEL` /8 at 54 MHz) | 15.7343 kHz | 60.0545 Hz |
| `720x720` | 720 x 720 active, 756 x 730 total | exactly 32.7734375 MHz | 720 x 720 active, 756 x 730 total | exactly 32.768 MHz average | 43.344 kHz | 59.375 Hz |

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

- native uses an increment of 524375 modulo 1573125, exactly one source pixel every three core clocks or 32.7734375 MHz;
- CRT toggles one request for each fixed 54 MHz `/8` output slot; a two-flop synchronizer turns each toggle into one source pixel request.

Complete timing/control/RGB packets cross to the output domain through a dual-clock FIFO. The CRT producer is therefore demand-locked to the consumer rather than merely frequency-matched to it.

`CLK_VIDEO` is a separate, free-running 54.000 MHz PLL output connected directly to the MiSTer `emu` boundary. It is not selected through a core-owned clock mux, because the framework places its own clock selector after that boundary. The output bridge provides:

- CRT: exact `CE_PIXEL` /8, or 6.750 MHz, with one output sample for each 360-wide package/source pixel;
- native: exact-average 32.768 MHz packet consumption using a `2048/3375` accumulator on 54 MHz, with a locally owned 720x720 active / 756x730 total raster for normal scaler use.

Native deliberately gives the internal producer a 5,437.5-packet/s lead. The
output bridge pauses that producer when FIFO occupancy reaches 768 words and
resumes it at 640 words. Only the source NCO and compositor coordinates pause;
the visible 54 MHz clock, pixel-enable cadence, counters, sync, blanking, and DE
continue without interruption. The producer's long-term effective rate
therefore equals the unchanged 32.768 MHz consumer rate while short service
gaps no longer drain the FIFO.

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

The output bridge flushes and rearms its asynchronous packet FIFO around a mode change. Both modes discard partial buffered frames and hold the next complete source start-of-frame packet through prefill. Native mode aligns that held source SOF to the next boundary of its locally owned 756x730 raster; packet-carried timing fields are ignored after acquisition. CRT mode similarly waits for the next local 429x262 frame boundary. In both modes, local counters, sync, blanking, and DE continue independently through FIFO search or recovery; unavailable RGB is blacked without interrupting the raster. `CLK_VIDEO` remains fixed at 54.000 MHz in both menu modes.

Raster timing free-runs before a package is loaded and while content is reset. RGB is blanked independently, keeping OSD timing alive at boot.

## Older and Newer Package Compatibility

V1 packages and earlier V2 packages remain loadable. Their 720x720 path is unchanged. If CRT mode is selected without valid native 360 descriptors and payloads, the core reads the old 720x720 artwork/mask at source `x * 2`, `y * 3`. The mask reader advances two source pixels per 360 output pixel so adjacent legacy runs are preserved.

The extension offsets and fixed package end remain unchanged from the superseded 720x240 package revision. That older core rejects a new 360 descriptor's length/dimensions and also falls back to the retained legacy assets. Compatibility is therefore fail-closed in both directions; the native 360 assets require the current core, while neither package generation strands the legacy 720x720 presentation.

## Current Verification Boundary

The source-packet audit completes 51,982 checks with zero errors and zero warnings. The timing audit completes 528,577 checks and proves exact native `/3` source pacing plus the unchanged CRT fourteen/fifteen-clock cadence. The common-period rate test proves an exact 5,437.5-packet/s native lead. The bidirectional transport regression passes 4,514,895 checks. The native elastic-buffer regression exercises a complete 768-to-640 pause cycle, ordered full frames, and forced overflow recovery; it passes with both the behavioral FIFO model (1,555,639 active pixels, maximum level 767) and the production Quartus 17 `dcfifo` model (1,555,200 active pixels, maximum level 768). The vendor run has only the two inherited Intel model port warnings.

The regenerated set contains 168 packages of `0x442AC0` bytes each and passes full-directory validation. Its ordinal-filename-sorted lines aggregate SHA-256 is `ed6e4a4544eec5cd0443134bb26424cac6a59fad84241006431ab673a31bd4ea`.

The debug-free Quartus 17.0.2 build completed with zero errors. `output_files/GameAndWatch.rbf` is 3,494,544 bytes with SHA-256 `16E14B86EBA8C9422F9C6F9E966BA5C01627659193D6EDD7070912B556DBEF6F`. Normal builds leave all three debug/diagnostic QSF macros undefined. The fit uses 13,563 ALMs (32%), 18,176 registers, 3,014,437 block-memory bits (53%), 379 RAM blocks (69%), 36 DSP blocks (32%), and four PLLs (67%).

All custom packet-FIFO, reset, mode-toggle, pause-toggle, request-toggle, and framework CDC guards matched their intended fitted nodes. Worst overall hold is `+0.206 ns`; recovery is `+2.591 ns`, and removal is `+0.689 ns`.

The 98.3203125 MHz core domain reports `-0.401 ns` / `-0.587 ns` TNS, within the accepted one-nanosecond task floor but not strict zero-slack closure. The RBF is hash-verified on USB-2 at `/media/fat/_Dev/GameAndWatch-native-elastic-16e14b86eba8.rbf`. With Direct Video off and Star Fox selected, 60 screenshots were captured one second apart. Frame 0 was the normal startup transition; frames 1 through 59 were byte-identical 720x720 images with SHA-256 `b7f269af912bef9752429730f35f5b148af60ac10d60445d3b22065d24c01fcc`, with no partial or black frames. The saved zero CFG and prior core were restored exactly. Morph/analog lock remains a user test.
