# CRT Video Mode

The core has two native video modes:

| Mode | Active | Total | Pixel enable | Approximate scan |
| ---- | ------ | ----- | ------------ | ---------------- |
| 720x720 | 720x720 | 756x730 | `CLK_VIDEO` | 60 Hz HDMI/scaler-oriented |
| 360x240 CRT | 360x240 | 416x262 | `CLK_VIDEO / 5` | 15.75 kHz / 60.1 Hz |

Both modes use the same MiSTer framework handoff: `CLK_VIDEO` is the 32.768 MHz video PLL clock and `CE_PIXEL` marks valid source pixels. The 720x720 mode asserts `CE_PIXEL` every clock, matching the refactor-era native stream. The CRT mode divides the video clock by 5, producing a 6.5536 MHz pixel cadence and a 15 kHz-class raw stream for analog VGA and direct video.

The default mode is `Native Video = 360x240 CRT`. In that mode, the core reports a 4:3 aspect ratio to the MiSTer scaler. The selectable 720x720 mode continues to report 1:1.

## Current Package Handling

Existing `.gnw` packages are still 720x720. To avoid a package-format break, CRT mode point-samples the package down to 360x240:

```
image_source_x = output_x * 2
image_source_y = output_y * 3
```

The LCD mask data is stored as row-major RLE data. The current bridge uses a single mask reader and compares each 360x240 output pixel against the corresponding 720x720 source coordinate. During horizontal blanking it advances to the next sampled source row so it does not stall on rows that are skipped by the 720-to-240 reduction.

`CE_PIXEL` free-runs even while the core is held in reset before a ROM is loaded. That keeps the MiSTer OSD visible on the CRT timing path at boot.

This is a hardware-testable bridge, not the final preservation-quality packaging path. Thin one-pixel details can alias or disappear because the source package is point-sampled. A previous attempt to merge source mask rows in real time caused bad hardware behavior and was rolled back.

## Follow-up

A generator-native CRT package path should render the SVG background and LCD mask directly to the CRT target, then version or flag the package dimensions so the core can tell whether a loaded package is 720x720 or CRT-native. That would remove real-time sampling and simplify the bridge path.
