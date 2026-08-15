# ROM Generator

A tool for converting MAME handheld assets into packages suitable for this core. The current manifest and supported-set audit target MAME 0.289.

## Usage

random11 has created a full tutorial (with a Windows focus) walking you through each of these steps. [Take a look](https://github.com/random11x/agg23-fpga-gameandwatch-hand-hold-guide/).

----

Place your `[artwork].zip` and `[rom].zip` MAME ROM files into your MAME folder, OR create a new folder, placing artwork in a folder called `artwork`, and ROMs in a folder called `roms`. Your file structure should look like this:

```
/MAME Folder/artwork/gnw_dkong.zip
/MAME Folder/roms/gnw_dkong.zip
```

The generator source lives in [`rom generator/`](../rom%20generator). Build it from the repository root with:

```sh
cargo build --manifest-path "rom generator/Cargo.toml" --release --locked
```

The built binary will be at `rom generator/target/release/fpga-gnw-romgenerator`.

----

The tool has many options and features which you can explore by running:

```sh
cargo run --manifest-path "rom generator/Cargo.toml" --release --locked -- --help
```

But most users will just want to generate any supported, installed ROMs they have, which you can do by running:

```sh
cargo run --manifest-path "rom generator/Cargo.toml" --release --locked -- \
  --manifest-path "rom generator/manifest.json" \
  --mame-path [MAME path] \
  --output-path [Output ROM path] \
  --installed \
  supported
```

Make sure to replace the brackets with the actual paths to your files. The MAME path should be the folder that contains the `artwork` and `roms` folders. The output path must already exist.

The `supported` filter includes SM510, SM511, SM512, SM530, SM510 Tiger, SM511 Tiger, and SM5a titles. Known non-keypad MAME `IPT_CUSTOM` shared inputs are converted into explicit `CustomUpDown` or `CustomButtonHour` actions when they fit the core controller layout. For SM511/SM512/SM530 and SM511 Tiger titles, the generator pads the program ROM area to `0x1000` bytes and appends the 256-byte melody ROM automatically, matching the package layout documented in [Format](format.md).

The generator also supports the SM511 Tiger 1-bit and 2-bit variants. With the 0.289-derived manifest, `supported` is a capability-filtered set of 168 titles, including the two retained homebrew entries. An automated manifest regression proves that every selected title fits the core's D-pad plus ten stable button positions without action collisions; the maximum is nine occupied buttons. Keyboard/calculator matrices, dial-only input, controller layouts needing more buttons than the core exposes, and non-LCD synthetic/independent display outputs are excluded.

MAME `PORT_NAME` labels and `PORT_PLAYER` ownership are retained in the manifest so unusual controls such as Pause, Status, Sound, Minute, and the Micro Vs. player split remain auditable. Package action IDs stay semantic; the core resolves those actions onto its compound MiSTer labels. Service4/Minute uses ID 33 in newly generated packages, rather than the legacy Service2/Alarm alias. `gnw_boxing`, `gnw_dkong3`, and `gnw_dkhockey` encode the player-two electrical cells in the V2 `GNWX` header instead of mirroring both sides onto player one.

If ROMs, artwork, and samples live in separate collections, use `--rom-path`, `--artwork-path`, and `--sample-path` instead of `--mame-path`. The three MSM6373 titles require their MAME sample ZIPs; the generator resamples those WAV files to 8 kHz, encodes them as OKI ADPCM4, and appends a versioned voice bank. This provides the observable phrase/busy behavior without claiming a dump or bit-identical emulation of the original internal mask ROM.

Nelsonic Star Fox is different: MAME has its actual 128-byte `ha1152_001a` effect ROM. The extractor records it as an HA1152 `sfx` auxiliary ROM, and the Rust generator finds it by filename or SHA-1, verifies its type/region/size/hash, writes the exact bytes at `0x336400`, and emits the canonical HMC descriptor. It does not generate or approximate HA1152 content.

Every newly generated package also receives a second native video render. The generator composes the selected MAME layout at an effective square-pixel 320x240, expands the complete composition horizontally to `360x240`, and encodes a matching LCD-segment RLE map. This render starts from the layout and original assets; it is not a point sample of the package's 720x720 image or a downsample of the superseded 720x240 transport. The legacy image/mask/ROM region is retained so the same package switches natively between both core modes.

LCD contrast fallback is evaluated per segment ID, not across the whole screen. A title with visible status digits can therefore no longer hide nearly background-colored gameplay segments. `--audit-lcd-contrast` reports repairable segment layers in an existing package directory; `--repair-lcd-contrast` updates only the affected foreground bytes and revalidates each package before replacement. The current set repairs Crab Grab, Pinball, and Spitball Sparky. Nu Pogodi instead uses the complete `alternates/hydef` artwork selected by the generated manifest, with automatic fallback to the standard ZIP if that source is absent.

The generated manifest marks only `nsmb3` with `defaultSoundOn`. This emits descriptorless V2 feature bit `0x20`; it does not alter the exact program or melody ROM. Header refresh treats this bit as metadata-only while continuing to reject changes to every payload-backed feature bit.

An already-generated directory can be checked with `--validate-packages`. Validation covers the exact inventory of 168 filenames, program/melody/HMC hashes, complete legacy headers and payloads, player-two ownership, package size, feature/directory/descriptor consistency, voice header/bounds/command slots, the 360x240 CRT image, the required zero image-to-mask gap, CRT RLE ordering and terminator, and all remaining zero padding. Current dual-resolution packages are exactly `0x442AC0` bytes each.

When a manifest refresh changes only fixed header metadata or semantic input IDs, `--refresh-package-configs` updates the 0x100-byte headers of every supported package without rerendering artwork or rewriting ROM/audio payloads. Pair it with `--validate-packages` in the same invocation; validation compares every header byte through the reserved area against the refreshed manifest before rechecking all payload hashes and bounds. Header refresh deliberately refuses to migrate an old single-resolution package into the dual-resolution format because the missing artwork and mask payloads must be rendered.

You can also generate a single game, all of the games for a certain CPU, and more.

## Current Regenerated Set

The repository `roms/` directory contains the complete 168-title MAME 0.289-derived supported set, including two retained homebrew entries, regenerated for native 360x240 and 720x720. Each package is 4,467,392 bytes and total package data is 750,521,856 bytes. To reproduce aggregate SHA-256 `c6aca96b6be2ccb58bb8f9b2c6a80e46cd4ba2ad00eaf267a719b772666a67ae`, sort the bare filenames using ordinal case-sensitive order, emit each file's lowercase SHA-256 followed by two spaces, its filename, and LF, retain the final LF, encode as UTF-8 without a BOM, and SHA-256 that manifest. `roms/Roms.zip` contains exactly those 168 manufacturer-organized packages and has SHA-256 `c1cd1e4f01b6c37bdf9c7b66cf2a13afcbb62c97421356d2bc0801b167449a28`.

These packages store generator provenance `2627bd8`. The header refresh ran while committed `HEAD` was `2627bd8` but the working tree already contained the uncommitted generator and package work, so the field is a nearest-commit label rather than proof that commit `2627bd8` contains this format.

Full-directory validation reports 168 dual-resolution packages, with the largest CRT mask at 7,813 runs / `0x989E` used bytes in `tjpark` against `0xF3C0` capacity. Voice directories contain 12 commands for `kst25`, 11 for `ktmnt2`, and 10 for `ktopgun2`. Legacy image, mask, ROM, melody, and voice payloads were checked byte-for-byte against the prior generated packages; the versioned header and CRT extension contain the intentional changes.

## General Structure

Turning MAME ROMs, SVGs, raster artwork, and optional sound data into two synchronized presentation targets requires several stages:

1. Find MAME artwork and ROM files and extract the ZIPs to a temporary folder.
2. Open the `default.lay` MAME layout, parse its XML, and rank the available views while avoiding device overlays.
3. Scan through the layout, identify the assets and their positions, and calculate their placement for the 720x720 target.
4. Render the assets in layout order. `screens` (which reference the SVG LCDs) are rendered to a separate active-LCD buffer.
   1. The SVG rendering process examines the SVG tree for `title` nodes. These titles contain the `x.y.z` segment identification values for the LCD. Maintain a map of node ids to segment ids
   2. Gather all SVG nodes matched to a given segment ID (there can be multiple occurrences), and render them to a temporary bitmap at their final size and position.
   3. Record the pixels in the final rendered area.
   4. Render the full SVG to a composite mask-layer bitmap and record the pixel-to-segment-ID mapping.
5. Repeat the composition from source assets for a logical 320x240 CRT target, then expand the completed image and segment-ID map to 360x240.
6. Build the format described in [Format](format.md).
   1. Scan each target's segment-ID pixels to build row-major contiguous mask spans.
   2. Add voice, HA1152/HMC, player ownership, and extension descriptors when declared by the manifest.
7. Save one fixed-size dual-resolution output package.

## Manifest

The manifest extractor (located at [`rom generator/extraction`](../rom%20generator/extraction)) reads the MAME `hh_sm510.cpp` device definition file that contains the SM5xx handheld titles and converts it into a reliable, reusable format. Use is very simple, run:

```sh
cd "rom generator/extraction"
npm ci
npm run build -- [Path to hh_sm510.cpp] ../manifest.json
```

This will create a `rom generator/manifest.json` file with the SM5xx titles supported by MAME. You can use this in the ROM Generator by passing the `--manifest-path` argument.
