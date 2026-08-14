# Game & Watch ROM Generator

This folder contains the ROM packaging tooling for the Game & Watch MiSTer core.

The generator converts MAME Game & Watch artwork and ROM zips into `.gnw` packages that the FPGA core can load. It does not include MAME ROMs or artwork.

## Contents

- `src/` - Rust source for `fpga-gnw-romgenerator`
- `Cargo.toml` / `Cargo.lock` - Rust build metadata
- `extraction/` - TypeScript helper for generating `manifest.json` from MAME's `hh_sm510.cpp`

## Requirements

- Rust toolchain with `cargo`
- Node.js and npm, only if regenerating `manifest.json`
- MAME ROM and artwork archives; voice titles also need MAME sample archives

Expected MAME input layout:

```text
/MAME Folder/artwork/gnw_dkong.zip
/MAME Folder/roms/gnw_dkong.zip
/MAME Folder/samples/ktmnt2.zip
```

## Build The Generator

From the repository root:

```sh
cargo build --manifest-path "rom generator/Cargo.toml" --release --locked
```

The binary will be written to:

```text
rom generator/target/release/fpga-gnw-romgenerator
```

You can also run it without separately invoking the built binary:

```sh
cargo run --manifest-path "rom generator/Cargo.toml" --release --locked -- --help
```

## Generate Or Provide The Manifest

The generator needs a `manifest.json` describing supported devices, CPU types, ROM hashes, screen setup, and input mapping.

To regenerate it from a local MAME source checkout:

```sh
cd "rom generator/extraction"
npm ci
npm run build -- /path/to/mame/src/mame/handheld/hh_sm510.cpp ../manifest.json
```

That writes `rom generator/manifest.json`, which the Rust generator can use directly.

## Generate ROM Packages

From the repository root:

```sh
cargo run --manifest-path "rom generator/Cargo.toml" --release --locked -- \
  --manifest-path "rom generator/manifest.json" \
  --mame-path "/path/to/MAME Folder" \
  --output-path "/path/to/output" \
  supported
```

The output directory must already exist.

The legacy `--mame-path` layout remains supported. Separate collections can instead be supplied with `--rom-path`, `--artwork-path`, and `--sample-path`.

With the MAME 0.289-derived manifest, the `supported` filter produces 168 controller-oriented packages, including two retained homebrew entries, across SM5a, SM510, SM511, SM512, SM530, and the SM510/SM511 Tiger variants. It intentionally excludes keyboard/calculator matrices, a dial title, controls beyond the core's controller layout, and synthetic/independent display outputs. SM511, SM512, SM530, and both SM511 Tiger variants include the fixed 4 KiB program ROM area plus the appended 256-byte melody ROM. The three voice titles additionally use the V2 sample-backed voice bank documented in `docs/format.md`.

Each current package contains independent 720x720 and 360x240 image/mask pairs. The CRT render is composed from the MAME layout and source assets on an effective square-pixel 320x240 canvas, then the complete composition and segment map are expanded to 360x240. It is not derived by downsampling the 720x720 image. The fixed package ABI keeps the CRT image at `0x336500`, uses `0x7E900` image bytes, requires a zero gap through `0x4336FF`, and keeps the CRT mask at `0x433700`.

The checked-in `roms/` set contains 168 files of 4,467,392 bytes each. Its aggregate SHA-256 is `17a70cfd698464cdc020f4a1ae1de4cf0831878be253b6deccca4da16d9b9e67`: sort bare filenames in ordinal case-sensitive order, write lowercase `sha256`, two spaces, filename, and LF for each file with a final LF, then SHA-256 the UTF-8-without-BOM manifest. Header provenance `2600ff1` names the committed `HEAD` present during generation; generation used a dirty worktree, so it does not mean this format is committed at `2600ff1`.

Validate an existing complete package directory without rebuilding artwork:

```sh
fpga-gnw-romgenerator --manifest-path "rom generator/manifest.json" \
  --output-path "/path/to/output" --validate-packages
```

If a manifest refresh changes only fixed header metadata or semantic input
IDs, update the existing packages without rerendering artwork or rewriting
ROM/audio payloads, then validate them in the same run:

```sh
fpga-gnw-romgenerator --manifest-path "rom generator/manifest.json" \
  --output-path "/path/to/output" \
  --refresh-package-configs --validate-packages
```

On MiSTer, generated `.gnw` files belong in:

```text
/games/Game and Watch/
```

## Useful Filters

Generate one game:

```sh
cargo run --manifest-path "rom generator/Cargo.toml" --release --locked -- \
  --manifest-path "rom generator/manifest.json" \
  --mame-path "/path/to/MAME Folder" \
  --output-path "/path/to/output" \
  specific gnw_dkong
```

Generate only installed supported games:

```sh
cargo run --manifest-path "rom generator/Cargo.toml" --release --locked -- \
  --manifest-path "rom generator/manifest.json" \
  --mame-path "/path/to/MAME Folder" \
  --output-path "/path/to/output" \
  --installed \
  supported
```

The Rust CLI is the source of truth for options:

```sh
cargo run --manifest-path "rom generator/Cargo.toml" --release --locked -- --help
```
