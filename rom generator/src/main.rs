#[macro_use]
extern crate guard;

use std::{
    collections::{HashMap, HashSet},
    env::temp_dir,
    fs::{self, OpenOptions},
    io::{Seek, SeekFrom, Write},
    path::{Path, PathBuf},
};

use clap::{Parser, Subcommand, ValueEnum};

use colored::Colorize;
use sha1::{Digest, Sha1};

use assets::get_assets;
use layout::parse_layout;
use manifest::PlatformSpecification;

use crate::{
    audio::{inspect_voice_bank, VOICE_BANK_SIZE},
    encode_format::{
        encode, CRT_IMAGE_HEIGHT, CRT_IMAGE_PACKAGE_OFFSET, CRT_IMAGE_SIZE, CRT_IMAGE_WIDTH,
        CRT_MASK_CAPACITY, CRT_MASK_PACKAGE_OFFSET, CRT_PACKAGE_SIZE,
        DESCRIPTOR_KIND_CRT_IMAGE, DESCRIPTOR_KIND_CRT_MASK, DESCRIPTOR_KIND_HMC,
        DESCRIPTOR_KIND_VOICE, FEATURE_CRT_IMAGE, FEATURE_CRT_MASK, FEATURE_DIRECTORY,
        FEATURE_DEFAULT_SOUND_ON, FEATURE_HMC, FEATURE_PLAYER_TWO, FEATURE_VOICE,
        HMC_PACKAGE_OFFSET, HMC_ROM_SIZE, VOICE_PACKAGE_OFFSET,
    },
    manifest::{AuxROMDefinition, AuxROMRegion, AuxROMType, CPUType},
    render::{RenderTarget, RenderedData},
};

mod assets;
mod audio;
mod encode_format;
mod layout;
mod manifest;
mod render;
mod svg_manage;

#[cfg(test)]
use crate::encode_format::{PLAYER_TWO_MASK_OFFSET, PLAYER_TWO_MASK_SIZE};

const WIDTH: usize = 720;
const HEIGHT: usize = WIDTH;

#[derive(Subcommand, Clone, Debug)]
enum FilterArg {
    /// Match a particular game
    Specific { name: String },
    /// Match the games that use a particular CPU
    CPU { name: CPUType },
    /// Match the specific CPU types supported by the core currently.
    Supported,
    /// All game types specified in the manifest.json
    All,
}

#[derive(ValueEnum, Clone, Debug)]
enum CompanyArg {
    Nintendo,
    Elektronika,
    Konami,
    Nelsonic,
    /// Tiger Electronics
    Tiger,
    Tronica,
    VTech,
}

#[derive(Parser, Debug)]
struct Args {
    #[arg(long)]
    /// Validate already-generated packages instead of rendering new ones
    validate_packages: bool,

    #[arg(long)]
    /// Refresh fixed package headers from the manifest without rerendering assets
    refresh_package_configs: bool,

    #[arg(long)]
    /// Repair invisible per-segment LCD foregrounds in already-generated packages
    repair_lcd_contrast: bool,

    #[arg(long)]
    /// Report package LCD foregrounds that the contrast repair would change
    audit_lcd_contrast: bool,

    #[command(subcommand)]
    filter: Option<FilterArg>,

    #[arg(short = 'i', long)]
    /// Only the games located in your MAME directory
    installed: bool,

    #[arg(short = 'm', long)]
    /// Legacy MAME root containing artwork/, roms/, and optionally samples/
    mame_path: Option<PathBuf>,

    #[arg(long)]
    /// Directory containing MAME artwork ZIPs
    artwork_path: Option<PathBuf>,

    #[arg(long)]
    /// Directory containing non-merged MAME ROM ZIPs
    rom_path: Option<PathBuf>,

    #[arg(long)]
    /// Directory containing MAME sample ZIPs
    sample_path: Option<PathBuf>,

    #[arg(short = 'a', long, default_value = "manifest.json")]
    /// The path to the included manifest file
    manifest_path: PathBuf,

    #[arg(short = 'o', long)]
    /// The path to the final ROM output directory
    output_path: PathBuf,

    #[arg(short = 'l', long)]
    /// The layout name specified in the MAME .lay file to use. Will fail if this layout is not found
    layout: Option<String>,

    #[arg(short = 'd', long)]
    /// Enable debug PNG output
    debug: bool,

    ///////////////////

    // Company filtering
    #[arg(short, long)]
    /// Filter to Nintendo games
    nintendo: bool,

    #[arg(short, long)]
    /// Filter to Elektronika games
    elektronika: bool,

    #[arg(short, long)]
    /// Filter to Konami games
    konami: bool,

    #[arg(short = 'c', long)]
    /// Filter to Nelsonic games
    nelsonic: bool,

    #[arg(short, long)]
    /// Filter to Tiger Electronics games
    tiger: bool,

    #[arg(short = 'r', long)]
    /// Filter to Tronica games
    tronica: bool,

    #[arg(short, long)]
    /// Filter to VTech games
    vtech: bool,

    #[arg(short = 'b', long)]
    /// Filter to Homebrew games
    homebrew: bool,
}

fn main() {
    let args = Args::parse();

    let manifest_file = fs::read(&args.manifest_path).expect("Could not find manifest file");
    let manifest: HashMap<String, PlatformSpecification> =
        serde_json::from_slice(manifest_file.as_slice()).expect("Could not parse manifest file");

    if args.refresh_package_configs {
        if let Err(error) = refresh_package_configs(&manifest, &args.output_path) {
            eprintln!("Package config refresh failed: {error}");
            std::process::exit(1);
        }
        if !args.validate_packages {
            return;
        }
    }

    if args.repair_lcd_contrast || args.audit_lcd_contrast {
        if args.repair_lcd_contrast && args.audit_lcd_contrast {
            eprintln!("Choose either --repair-lcd-contrast or --audit-lcd-contrast, not both");
            std::process::exit(1);
        }
        if let Err(error) = repair_package_lcd_contrast(
            &manifest,
            &args.output_path,
            args.repair_lcd_contrast,
        ) {
            eprintln!("Package LCD-contrast repair failed: {error}");
            std::process::exit(1);
        }
        if !args.validate_packages {
            return;
        }
    }

    if args.validate_packages {
        if let Err(error) = validate_packages(&manifest, &args.output_path) {
            eprintln!("Package validation failed: {error}");
            std::process::exit(1);
        }
        return;
    }

    let artwork_path = args
        .artwork_path
        .clone()
        .or_else(|| args.mame_path.as_ref().map(|path| path.join("artwork")));
    let rom_path = args
        .rom_path
        .clone()
        .or_else(|| args.mame_path.as_ref().map(|path| path.join("roms")));
    let sample_path = args
        .sample_path
        .clone()
        .or_else(|| args.mame_path.as_ref().map(|path| path.join("samples")));

    let artwork_path = artwork_path.expect(
        "An artwork directory is required; use --artwork-path or a legacy --mame-path",
    );
    let rom_path =
        rom_path.expect("A ROM directory is required; use --rom-path or a legacy --mame-path");

    let temp_dir = temp_dir().join("gnw");

    let output_path = args
        .output_path
        .canonicalize()
        .expect("Could not find output path");

    let company_filter = {
        let mut filter = vec![];

        if args.nintendo {
            filter.push("nintendo");
        }

        if args.elektronika {
            filter.push("elektronika");
            filter.push("bootleg (elektronika)");
        }

        if args.konami {
            filter.push("konami");
        }

        if args.nelsonic {
            filter.push("nelsonic");
        }

        if args.tiger {
            filter.push("tiger");
        }

        if args.tronica {
            filter.push("tronica");
        }

        if args.vtech {
            filter.push("vtech");
        }

        if args.homebrew {
            filter.push("homebrew");
        }

        filter
    };

    let filter_platforms =
        |platforms: Vec<CPUType>| -> Option<Vec<(String, &PlatformSpecification)>> {
            let result = manifest
                .iter()
                .filter(|(_, p)| platforms.contains(&p.device.cpu))
                .map(|(n, p)| (n.clone(), p))
                .collect::<Vec<(String, &PlatformSpecification)>>();

            if result.len() > 0 {
                Some(result)
            } else {
                None
            }
        };

    let platforms: Option<Vec<(String, &PlatformSpecification)>> = match &args.filter {
        Some(FilterArg::Specific { name }) => {
            let trimmed_name = name.trim().to_string();

            if let Some(entry) = manifest.get(&trimmed_name) {
                Some(vec![(trimmed_name, entry)])
            } else {
                None
            }
        }
        Some(FilterArg::Supported) => filter_platforms(vec![
            CPUType::SM510,
            CPUType::SM511,
            CPUType::SM512,
            CPUType::SM530,
            CPUType::SM510Tiger,
            CPUType::SM511Tiger1Bit,
            CPUType::SM511Tiger2Bit,
            CPUType::SM5a,
        ])
        .map(|platforms| {
            platforms
                .into_iter()
                .filter(|(name, platform)| is_supported(name, platform))
                .collect()
        }),
        Some(FilterArg::CPU { name }) => filter_platforms(vec![name.clone()]),
        Some(FilterArg::All) | None => Some(manifest.iter().map(|(n, p)| (n.clone(), p)).collect()),
    };

    let installed = if args.filter.is_some() {
        args.installed
    } else {
        true
    };

    guard!(let Some(mut platforms) = platforms else {
        println!("No manifest listings for selected devices found");
        return;
    });

    platforms.sort_by(|(a, _), (b, _)| a.partial_cmp(b).unwrap());

    let platforms = platforms.iter().filter(|(_, p)| {
        if company_filter.len() > 0 {
            for filter in &company_filter {
                if p.metadata.company.to_lowercase().starts_with(filter) {
                    return true;
                }
            }
        } else {
            return true;
        }

        false
    });

    let mut success_count = 0;
    let mut skip_count = 0;
    let mut fail_count = 0;
    let mut platform_count = 0;

    let mut fail = |name: &String, message: String| {
        println!("{message}");
        println!("{}", format!("Failing device {name}\n").red());

        fail_count += 1;
    };

    for (name, platform) in platforms {
        platform_count += 1;
        let asset_dir = temp_dir.join(name.clone());

        println!("-------------------------");
        println!("Processing device {}\n", name.green());

        if let Err(err) = get_assets(
            &name,
            platform.parent.as_deref(),
            &platform.rom.rom_owner,
            &artwork_path,
            platform.artwork_subdirectory.as_deref(),
            &rom_path,
            sample_path.as_deref(),
            platform.voice.as_ref().map(|voice| voice.sample_set.as_str()),
            &asset_dir,
        ) {
            if !installed {
                // Only fail if we're not looking for only owned games
                fail(name, err);
            } else {
                // See `fail` above
                println!("{err}");
                println!(
                    "{}",
                    format!("Skipping device {name}: Not installed\n").red()
                );
                skip_count += 1;
            }
            continue;
        }

        let (layout_manifest, layout) = match parse_layout(&asset_dir, args.layout.as_ref()) {
            Ok(layout) => layout,
            Err(err) => {
                fail(name, err);
                continue;
            }
        };

        let RenderedData {
            background_bytes,
            mask_bytes,
            pixels_to_mask_id,
        } = match render::render(
            &name,
            &layout,
            &layout_manifest,
            &platform,
            &asset_dir,
            RenderTarget::native(),
            args.debug,
        ) {
            Ok(data) => data,
            Err(err) => {
                fail(name, err);
                continue;
            }
        };

        // Render the CRT presentation directly from the selected MAME layout
        // and SVGs. This is intentionally a second render, not a resize or
        // point sample of the already-rasterized 720x720 package artwork.
        let RenderedData {
            background_bytes: crt_background_bytes,
            mask_bytes: crt_mask_bytes,
            pixels_to_mask_id: crt_pixels_to_mask_id,
        } = match render::render(
            &name,
            &layout,
            &layout_manifest,
            &platform,
            &asset_dir,
            RenderTarget::crt(),
            args.debug,
        ) {
            Ok(data) => data,
            Err(err) => {
                fail(name, err);
                continue;
            }
        };

        let package_output_path = output_path.join(package_manufacturer_folder(platform));
        if let Err(err) = fs::create_dir_all(&package_output_path) {
            fail(
                name,
                format!(
                    "Could not create manufacturer output directory {package_output_path:?}: {err}"
                ),
            );
            continue;
        }

        let data_path = encode(
            background_bytes.data(),
            mask_bytes.data(),
            pixels_to_mask_id.as_slice(),
            crt_background_bytes.data(),
            crt_mask_bytes.data(),
            crt_pixels_to_mask_id.as_slice(),
            platform,
            &asset_dir,
            &package_output_path,
        );

        match data_path {
            Ok(path) => {
                println!(
                    "Successfully created device {} at {}\n",
                    name.green(),
                    path.display()
                );
                success_count += 1;
            }
            Err(err) => fail(name, err),
        }
    }

    println!("-------------------------");
    println!(
        "Total: {platform_count}, Success: {success_count}, Fail: {fail_count}, Skip: {skip_count}",
    );
}

const IMAGE_AND_MASK_SIZE: usize = 0x325240;
const PROGRAM_ROM_SIZE: usize = 0x1000;
const MELODY_ROM_SIZE: usize = 0x100;
const LEGACY_IMAGE_PACKAGE_OFFSET: usize = 0x100;
const LEGACY_MASK_PACKAGE_OFFSET: usize = LEGACY_IMAGE_PACKAGE_OFFSET + WIDTH * HEIGHT * 6;
const LEGACY_MASK_CAPACITY: usize = IMAGE_AND_MASK_SIZE - LEGACY_MASK_PACKAGE_OFFSET;

#[derive(Clone, Copy, Debug)]
struct PackageMaskRun {
    id: u16,
    x: usize,
    y: usize,
    length: usize,
}

fn decode_package_mask_runs(
    package: &[u8],
    mask_offset: usize,
    mask_capacity: usize,
    width: usize,
    height: usize,
    label: &str,
) -> Result<Vec<PackageMaskRun>, String> {
    let mask_end = mask_offset
        .checked_add(mask_capacity)
        .ok_or_else(|| format!("{label} mask bounds overflowed"))?;
    let region = package
        .get(mask_offset..mask_end)
        .ok_or_else(|| format!("Package is missing its {label} mask region"))?;
    let mut runs = Vec::new();
    let mut previous_y = 0usize;
    let mut previous_end_x = 0usize;
    let mut have_previous = false;

    for (entry_index, entry) in region.chunks_exact(5).enumerate() {
        if entry.iter().all(|byte| *byte == 0) {
            break;
        }

        let packed = u64::from(entry[0])
            | (u64::from(entry[1]) << 8)
            | (u64::from(entry[2]) << 16)
            | (u64::from(entry[3]) << 24)
            | (u64::from(entry[4]) << 32);
        let id = (packed & 0x3ff) as u16;
        let x = ((packed >> 10) & 0x3ff) as usize;
        let y = ((packed >> 20) & 0x3ff) as usize;
        let length = ((packed >> 30) & 0x3ff) as usize;
        let end_x = x + length;
        if length == 0 || y >= height || end_x > width {
            return Err(format!(
                "Package has an invalid {label} mask run at entry {entry_index}"
            ));
        }
        if have_previous && (y < previous_y || (y == previous_y && x < previous_end_x)) {
            return Err(format!(
                "Package has out-of-order or overlapping {label} mask runs"
            ));
        }
        runs.push(PackageMaskRun { id, x, y, length });
        previous_y = y;
        previous_end_x = end_x;
        have_previous = true;
    }

    if runs.is_empty() {
        return Err(format!("Package {label} mask has no segment runs"));
    }
    Ok(runs)
}

fn repair_image_lcd_contrast(
    package: &mut [u8],
    image_offset: usize,
    width: usize,
    height: usize,
    mask_offset: usize,
    mask_capacity: usize,
    label: &str,
) -> Result<(usize, usize), String> {
    let image_size = width
        .checked_mul(height)
        .and_then(|pixels| pixels.checked_mul(6))
        .ok_or_else(|| format!("{label} image dimensions overflowed"))?;
    if package.get(image_offset..image_offset + image_size).is_none() {
        return Err(format!("Package is missing its {label} image region"));
    }
    let runs = decode_package_mask_runs(
        package,
        mask_offset,
        mask_capacity,
        width,
        height,
        label,
    )?;
    let mut stats: HashMap<u16, (usize, usize)> = HashMap::new();

    for run in &runs {
        for x in run.x..run.x + run.length {
            let pixel = image_offset + (run.y * width + x) * 6;
            let delta = usize::from(package[pixel].abs_diff(package[pixel + 1]))
                + usize::from(package[pixel + 2].abs_diff(package[pixel + 3]))
                + usize::from(package[pixel + 4].abs_diff(package[pixel + 5]));
            let stat = stats.entry(run.id).or_insert((0, 0));
            stat.0 += 1;
            stat.1 += delta;
        }
    }

    let low_contrast: HashSet<u16> = stats
        .iter()
        .filter_map(|(id, (pixels, delta))| {
            (*pixels != 0 && *delta <= *pixels * 3).then_some(*id)
        })
        .collect();
    let mut repaired_ids = HashSet::new();
    let mut repaired_pixels = 0usize;
    for run in &runs {
        if !low_contrast.contains(&run.id) {
            continue;
        }
        for x in run.x..run.x + run.length {
            let pixel = image_offset + (run.y * width + x) * 6;
            let replacement = [
                (u16::from(package[pixel]) * 45 / 100) as u8,
                (u16::from(package[pixel + 2]) * 45 / 100) as u8,
                (u16::from(package[pixel + 4]) * 45 / 100) as u8,
            ];
            if package[pixel + 1] != replacement[0]
                || package[pixel + 3] != replacement[1]
                || package[pixel + 5] != replacement[2]
            {
                package[pixel + 1] = replacement[0];
                package[pixel + 3] = replacement[1];
                package[pixel + 5] = replacement[2];
                repaired_ids.insert(run.id);
                repaired_pixels += 1;
            }
        }
    }

    Ok((repaired_ids.len(), repaired_pixels))
}

fn repair_package_lcd_contrast(
    manifest: &HashMap<String, PlatformSpecification>,
    output_path: &Path,
    write_changes: bool,
) -> Result<(), String> {
    let supported = supported_platforms(manifest);
    validate_package_directory_inventory(&supported, output_path)?;
    let mut repaired_packages = 0usize;
    let mut repaired_segments = 0usize;
    let mut repaired_pixels = 0usize;

    for (_, platform) in supported {
        let file_name = package_file_name(platform);
        let package_path = output_path.join(package_relative_path(platform));
        let mut package = fs::read(&package_path)
            .map_err(|err| format!("Could not read {package_path:?}: {err}"))?;
        validate_package(&file_name, &package, platform)?;

        let legacy = repair_image_lcd_contrast(
            &mut package,
            LEGACY_IMAGE_PACKAGE_OFFSET,
            WIDTH,
            HEIGHT,
            LEGACY_MASK_PACKAGE_OFFSET,
            LEGACY_MASK_CAPACITY,
            "legacy",
        )?;
        let crt = repair_image_lcd_contrast(
            &mut package,
            CRT_IMAGE_PACKAGE_OFFSET,
            CRT_IMAGE_WIDTH,
            CRT_IMAGE_HEIGHT,
            CRT_MASK_PACKAGE_OFFSET,
            CRT_MASK_CAPACITY,
            "CRT",
        )?;
        let package_segments = legacy.0 + crt.0;
        let package_pixels = legacy.1 + crt.1;
        if package_segments == 0 {
            continue;
        }

        validate_package(&file_name, &package, platform)?;
        if !write_changes {
            println!(
                "Would repair {file_name}: {package_segments} low-contrast segment layers / {package_pixels} pixels"
            );
            repaired_packages += 1;
            repaired_segments += package_segments;
            repaired_pixels += package_pixels;
            continue;
        }
        let mut temporary_name = package_path
            .file_name()
            .ok_or_else(|| format!("Package path {package_path:?} has no filename"))?
            .to_os_string();
        temporary_name.push(format!(".lcd-contrast-{}.tmp", std::process::id()));
        let temporary_path = package_path.with_file_name(temporary_name);
        if temporary_path.exists() {
            return Err(format!(
                "Refusing to overwrite stale repair file {temporary_path:?}"
            ));
        }
        let mut backup_name = package_path
            .file_name()
            .expect("package filename was checked above")
            .to_os_string();
        backup_name.push(format!(".lcd-contrast-{}.bak", std::process::id()));
        let backup_path = package_path.with_file_name(backup_name);
        if backup_path.exists() {
            return Err(format!(
                "Refusing to overwrite stale repair backup {backup_path:?}"
            ));
        }
        fs::write(&temporary_path, &package)
            .map_err(|err| format!("Could not write {temporary_path:?}: {err}"))?;
        fs::rename(&package_path, &backup_path).map_err(|err| {
            let _ = fs::remove_file(&temporary_path);
            format!("Could not stage the original {package_path:?}: {err}")
        })?;
        if let Err(error) = fs::rename(&temporary_path, &package_path) {
            let rollback = fs::rename(&backup_path, &package_path);
            let _ = fs::remove_file(&temporary_path);
            return Err(match rollback {
                Ok(()) => format!(
                    "Could not install repaired package {package_path:?}: {error}; original restored"
                ),
                Err(rollback_error) => format!(
                    "Could not install repaired package {package_path:?}: {error}; original remains at {backup_path:?} because rollback failed: {rollback_error}"
                ),
            });
        }
        fs::remove_file(&backup_path).map_err(|err| {
            format!(
                "Installed repaired package {package_path:?}, but could not remove backup {backup_path:?}: {err}"
            )
        })?;

        println!(
            "Repaired {file_name}: {package_segments} low-contrast segment layers / {package_pixels} pixels"
        );
        repaired_packages += 1;
        repaired_segments += package_segments;
        repaired_pixels += package_pixels;
    }

    println!(
        "{} {repaired_packages} packages ({repaired_segments} resolution-specific segment layers / {repaired_pixels} pixels)",
        if write_changes { "Repaired" } else { "Would repair" }
    );
    Ok(())
}

fn supported_platforms(
    manifest: &HashMap<String, PlatformSpecification>,
) -> Vec<(&String, &PlatformSpecification)> {
    let mut supported: Vec<_> = manifest
        .iter()
        .filter(|(name, platform)| {
            matches!(
                platform.device.cpu,
                CPUType::SM5a
                    | CPUType::SM510
                    | CPUType::SM511
                    | CPUType::SM512
                    | CPUType::SM530
                    | CPUType::SM510Tiger
                    | CPUType::SM511Tiger1Bit
                    | CPUType::SM511Tiger2Bit
            ) && is_supported(name, platform)
        })
        .collect();
    supported.sort_by(|(left, _), (right, _)| left.cmp(right));
    supported
}

fn validate_package_directory_inventory(
    supported: &[(&String, &PlatformSpecification)],
    output_path: &Path,
) -> Result<(), String> {
    let mut pending_directories = vec![output_path.to_path_buf()];
    let mut actual_files = 0;
    while let Some(directory) = pending_directories.pop() {
        for entry in fs::read_dir(&directory)
            .map_err(|err| format!("Could not open package directory {directory:?}: {err}"))?
        {
            let entry = entry.map_err(|err| {
                format!("Could not inspect an entry in package directory {directory:?}: {err}")
            })?;
            let file_type = entry
                .file_type()
                .map_err(|err| format!("Could not inspect package path {:?}: {err}", entry.path()))?;
            if file_type.is_dir() {
                pending_directories.push(entry.path());
            } else if file_type.is_file()
                && entry
                    .path()
                    .extension()
                    .map(|extension| extension.eq_ignore_ascii_case("gnw"))
                    .unwrap_or(false)
            {
                actual_files += 1;
            }
        }
    }
    if actual_files != supported.len() {
        return Err(format!(
            "Found {actual_files} .gnw files, expected {}",
            supported.len()
        ));
    }

    let mut filenames = std::collections::HashSet::new();
    for (_, platform) in supported {
        let file_name = package_file_name(platform);
        if !filenames.insert(file_name.clone()) {
            return Err(format!("Duplicate package filename {file_name:?}"));
        }
        let relative_path = package_relative_path(platform);
        if !output_path.join(&relative_path).is_file() {
            return Err(format!("Missing expected package {relative_path:?}"));
        }
    }

    Ok(())
}

fn refresh_package_configs(
    manifest: &HashMap<String, PlatformSpecification>,
    output_path: &std::path::Path,
) -> Result<(), String> {
    let supported = supported_platforms(manifest);
    validate_package_directory_inventory(&supported, output_path)?;

    struct PreparedHeaderRefresh {
        package_path: PathBuf,
        file_name: String,
        original_header: [u8; 0x100],
        replacement_header: Vec<u8>,
        original_sha1: String,
    }

    fn write_header(path: &Path, header: &[u8]) -> Result<(), String> {
        if header.len() != 0x100 {
            return Err(format!(
                "Refusing to write a {}-byte package header to {path:?}",
                header.len()
            ));
        }

        let mut file = OpenOptions::new()
            .write(true)
            .open(path)
            .map_err(|err| format!("Could not open {path:?} for header update: {err}"))?;
        file.seek(SeekFrom::Start(0))
            .map_err(|err| format!("Could not seek to the header of {path:?}: {err}"))?;
        file.write_all(header)
            .map_err(|err| format!("Could not update the header of {path:?}: {err}"))?;
        file.flush()
            .map_err(|err| format!("Could not flush the header of {path:?}: {err}"))
    }

    fn rollback_headers(entries: &[PreparedHeaderRefresh]) -> Result<(), String> {
        let mut failures = Vec::new();
        for entry in entries.iter().rev() {
            if let Err(error) = write_header(&entry.package_path, &entry.original_header) {
                failures.push(format!("{}: {error}", entry.file_name));
            }
        }

        if failures.is_empty() {
            Ok(())
        } else {
            Err(failures.join("\n"))
        }
    }

    fn rollback_error(error: String, entries: &[PreparedHeaderRefresh]) -> String {
        match rollback_headers(entries) {
            Ok(()) => format!("{error}; restored every header changed by this refresh"),
            Err(rollback_error) => format!(
                "{error}; header rollback was incomplete:\n{rollback_error}"
            ),
        }
    }

    let mut prepared = Vec::with_capacity(supported.len());

    // Build the exact post-refresh candidate in memory and run the same full
    // semantic validator used by --validate-packages before touching any file.
    // Payload feature bits and extension descriptors describe immutable bytes;
    // a header-only refresh must never add, remove, or reinterpret them. The
    // startup-sound flag is metadata-only and may be refreshed safely.
    for (_, platform) in &supported {
        let file_name = package_file_name(platform);
        let package_path = output_path.join(package_relative_path(platform));
        let package = fs::read(&package_path)
            .map_err(|err| format!("Could not read {package_path:?}: {err}"))?;
        let crt_mask_used_length = if package.len() >= CRT_PACKAGE_SIZE
            && package[0x30] & (FEATURE_CRT_IMAGE | FEATURE_CRT_MASK)
                == FEATURE_CRT_IMAGE | FEATURE_CRT_MASK
        {
            Some(inspect_crt_mask_payload(&file_name, &package)?.used_length)
        } else {
            // Header refresh is deliberately not a migration tool. Supplying
            // a valid placeholder makes the expected header require both CRT
            // payloads, so an old package is rejected by guard_header_refresh
            // before any byte is written.
            Some(5)
        };
        let expected = encode_format::build_config(
            platform,
            platform.voice.is_some(),
            platform.aux_rom.is_some(),
            crt_mask_used_length,
        )?;
        guard_header_refresh(&file_name, &package, &expected, platform)?;

        prepared.push(PreparedHeaderRefresh {
            package_path,
            file_name,
            original_header: package[..0x100]
                .try_into()
                .expect("guard_header_refresh accepted a truncated header"),
            replacement_header: expected,
            original_sha1: sha1_hex(&package),
        });
    }

    for (index, entry) in prepared.iter().enumerate() {
        let current = match fs::read(&entry.package_path) {
            Ok(current) => current,
            Err(error) => {
                let error = format!(
                    "Could not reread {:?} immediately before its header update: {error}",
                    entry.package_path
                );
                return Err(rollback_error(error, &prepared[..index]));
            }
        };
        if sha1_hex(&current) != entry.original_sha1 {
            let error = format!(
                "Package {:?} changed after refresh preflight; refusing a mixed update",
                entry.file_name
            );
            return Err(rollback_error(error, &prepared[..index]));
        }

        if let Err(error) = write_header(&entry.package_path, &entry.replacement_header) {
            return Err(rollback_error(error, &prepared[..=index]));
        }
    }

    println!("Refreshed config headers in {} packages", supported.len());
    Ok(())
}

fn guard_header_refresh(
    file_name: &str,
    package: &[u8],
    expected: &[u8],
    platform: &PlatformSpecification,
) -> Result<(), String> {
    if package.len() < 0x100 {
        return Err(format!(
            "Package {file_name:?} is shorter than its config header"
        ));
    }
    let refreshable_feature_mask = FEATURE_DEFAULT_SOUND_ON;
    if package[0] != expected[0]
        || (package[0x30] ^ expected[0x30]) & !refreshable_feature_mask != 0
    {
        return Err(format!(
            "Package {file_name:?} payload features differ from the manifest; regenerate it instead of refreshing its header"
        ));
    }

    if expected[0x30] & FEATURE_DIRECTORY != 0 {
        let descriptor_end = 0x40 + usize::from(expected[0x37]) * 16;
        if package[0x40..descriptor_end] != expected[0x40..descriptor_end] {
            return Err(format!(
                "Package {file_name:?} payload descriptors differ from the manifest; regenerate it"
            ));
        }
    }

    validate_extension_directory(file_name, package, expected)?;

    let mut candidate = package.to_vec();
    candidate[..0x100].copy_from_slice(expected);
    validate_package(file_name, &candidate, platform)?;

    Ok(())
}

fn validate_extension_directory(
    file_name: &str,
    package: &[u8],
    expected: &[u8],
) -> Result<(), String> {
    let directory_present = package[0x30] & FEATURE_DIRECTORY != 0;
    if !directory_present {
        if package[0x30]
            & (FEATURE_HMC | FEATURE_PLAYER_TWO | FEATURE_CRT_IMAGE | FEATURE_CRT_MASK)
            != 0
        {
            return Err(format!(
                "Package {file_name:?} marks directory-backed features without an extension directory"
            ));
        }
        return Ok(());
    }

    if package[0x31..0x38] != expected[0x31..0x38]
        || &package[0x31..0x35] != b"GNWX"
        || package[0x35] != 1
        || package[0x36] != 16
    {
        return Err(format!(
            "Package {file_name:?} extension-directory header differs from the manifest; regenerate it"
        ));
    }
    let count = usize::from(package[0x37]);
    let descriptor_end = 0x40 + count * 16;
    let descriptor_backed_features = package[0x30]
        & (FEATURE_VOICE | FEATURE_HMC | FEATURE_CRT_IMAGE | FEATURE_CRT_MASK)
        != 0;
    let descriptorless_player_two = package[0x30] & FEATURE_PLAYER_TWO != 0
        && !descriptor_backed_features;
    if descriptor_end > 0xF9 || (count == 0 && !descriptorless_player_two) {
        return Err(format!(
            "Package {file_name:?} has an invalid extension descriptor count"
        ));
    }

    let mut ranges = Vec::new();
    let mut seen_variants = std::collections::HashSet::new();
    for index in 0..count {
        let start = 0x40 + index * 16;
        let descriptor = &package[start..start + 16];
        let kind = descriptor[0];
        let encoding = descriptor[1];
        let variant = descriptor[2];
        if !seen_variants.insert((kind, variant)) || descriptor[3] != 0 {
            return Err(format!(
                "Package {file_name:?} has an invalid extension descriptor"
            ));
        }
        let offset = u32::from_le_bytes(descriptor[4..8].try_into().unwrap()) as usize;
        let length = u32::from_le_bytes(descriptor[8..12].try_into().unwrap()) as usize;
        let width = u16::from_le_bytes(descriptor[12..14].try_into().unwrap()) as usize;
        let height = u16::from_le_bytes(descriptor[14..16].try_into().unwrap()) as usize;
        let descriptor_shape_valid = match kind {
            DESCRIPTOR_KIND_VOICE => {
                encoding == 1
                    && variant == 1
                    && offset == VOICE_PACKAGE_OFFSET
                    && length == VOICE_BANK_SIZE
                    && width == 0
                    && height == 0
            }
            DESCRIPTOR_KIND_HMC => {
                encoding == 1
                    && variant == 1
                    && offset == HMC_PACKAGE_OFFSET
                    && length == HMC_ROM_SIZE
                    && width == 0
                    && height == 0
            }
            DESCRIPTOR_KIND_CRT_IMAGE => {
                encoding == 1
                    && variant == 1
                    && offset == CRT_IMAGE_PACKAGE_OFFSET
                    && length == CRT_IMAGE_SIZE
                    && width == CRT_IMAGE_WIDTH
                    && height == CRT_IMAGE_HEIGHT
            }
            DESCRIPTOR_KIND_CRT_MASK => {
                encoding == 2
                    && variant == 1
                    && offset == CRT_MASK_PACKAGE_OFFSET
                    && (5..=CRT_MASK_CAPACITY).contains(&length)
                    && length % 5 == 0
                    && width == CRT_IMAGE_WIDTH
                    && height == CRT_IMAGE_HEIGHT
            }
            _ => false,
        };
        if !descriptor_shape_valid
            || offset < 0x100
            || length == 0
            || offset.checked_add(length).is_none()
            || offset + length > package.len()
        {
            return Err(format!(
                "Package {file_name:?} has an out-of-bounds extension descriptor"
            ));
        }
        ranges.push((offset, offset + length));
    }
    ranges.sort_unstable();
    if ranges.windows(2).any(|pair| pair[0].1 > pair[1].0) {
        return Err(format!(
            "Package {file_name:?} has overlapping extension payloads"
        ));
    }

    let has_descriptor =
        |kind: u8| (0..count).any(|index| package[0x40 + index * 16] == kind);
    let required_descriptors = [
        (FEATURE_HMC, DESCRIPTOR_KIND_HMC),
        (FEATURE_CRT_IMAGE, DESCRIPTOR_KIND_CRT_IMAGE),
        (FEATURE_CRT_MASK, DESCRIPTOR_KIND_CRT_MASK),
    ];
    for (feature, kind) in required_descriptors {
        if (package[0x30] & feature != 0) != has_descriptor(kind) {
            return Err(format!(
                "Package {file_name:?} feature flags and payload descriptors disagree"
            ));
        }
    }
    if directory_present
        && ((package[0x30] & FEATURE_VOICE != 0)
            != has_descriptor(DESCRIPTOR_KIND_VOICE))
    {
        return Err(format!(
            "Package {file_name:?} voice feature and payload descriptor disagree"
        ));
    }

    Ok(())
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct CrtMaskSummary {
    used_length: usize,
    run_count: usize,
}

fn inspect_crt_mask_payload(file_name: &str, package: &[u8]) -> Result<CrtMaskSummary, String> {
    let end = CRT_MASK_PACKAGE_OFFSET + CRT_MASK_CAPACITY;
    if package.len() < end {
        return Err(format!(
            "Package {file_name:?} has a truncated native CRT mask region"
        ));
    }

    let region = &package[CRT_MASK_PACKAGE_OFFSET..end];
    let mut previous_y = 0usize;
    let mut previous_end_x = 0usize;
    let mut have_previous = false;

    for (index, entry) in region.chunks_exact(5).enumerate() {
        if entry.iter().all(|byte| *byte == 0) {
            if region[(index + 1) * 5..].iter().any(|byte| *byte != 0) {
                return Err(format!(
                    "Package {file_name:?} has nonzero data after its native CRT mask terminator"
                ));
            }
            return Ok(CrtMaskSummary {
                used_length: (index + 1) * 5,
                run_count: index,
            });
        }

        let packed = u64::from(entry[0])
            | (u64::from(entry[1]) << 8)
            | (u64::from(entry[2]) << 16)
            | (u64::from(entry[3]) << 24)
            | (u64::from(entry[4]) << 32);
        let start_x = ((packed >> 10) & 0x3ff) as usize;
        let y = ((packed >> 20) & 0x3ff) as usize;
        let length = ((packed >> 30) & 0x3ff) as usize;
        let end_x = start_x + length;
        if length == 0 || y >= CRT_IMAGE_HEIGHT || end_x > CRT_IMAGE_WIDTH {
            return Err(format!(
                "Package {file_name:?} has an invalid native CRT mask run at entry {index}"
            ));
        }
        if have_previous
            && (y < previous_y || (y == previous_y && start_x < previous_end_x))
        {
            return Err(format!(
                "Package {file_name:?} has out-of-order native CRT mask runs"
            ));
        }
        previous_y = y;
        previous_end_x = end_x;
        have_previous = true;
    }

    Err(format!(
        "Package {file_name:?} native CRT mask has no zero terminator"
    ))
}

fn validate_declared_payloads(
    file_name: &str,
    package: &[u8],
    platform: &PlatformSpecification,
) -> Result<(), String> {
    if platform.voice.is_some() {
        let voice_end = VOICE_PACKAGE_OFFSET + VOICE_BANK_SIZE;
        if package.len() < voice_end {
            return Err(format!(
                "Package {file_name:?} is missing its declared voice payload"
            ));
        }
        inspect_voice_bank(&package[VOICE_PACKAGE_OFFSET..voice_end])?;
    }
    if let Some(aux_rom) = &platform.aux_rom {
        validate_hmc_payload(file_name, package, aux_rom)?;
    }

    Ok(())
}

fn validate_packages(
    manifest: &HashMap<String, PlatformSpecification>,
    output_path: &std::path::Path,
) -> Result<(), String> {
    let supported = supported_platforms(manifest);
    validate_package_directory_inventory(&supported, output_path)?;

    let mut validated_count = 0;
    let mut voice_summary = Vec::new();
    let mut largest_crt_mask: Option<(usize, usize, String)> = None;
    for (shortname, platform) in supported {
        let file_name = package_file_name(platform);
        let package_path = output_path.join(package_relative_path(platform));
        let package = fs::read(&package_path)
            .map_err(|err| format!("Could not read {package_path:?}: {err}"))?;
        if package[0x30] & (FEATURE_CRT_IMAGE | FEATURE_CRT_MASK)
            != FEATURE_CRT_IMAGE | FEATURE_CRT_MASK
        {
            return Err(format!(
                "Package {file_name:?} is missing its native 360x240 assets"
            ));
        }
        if let Some(voice_entries) = validate_package(&file_name, &package, platform)? {
            voice_summary.push(format!("{shortname}:{voice_entries}"));
        }
        let crt_mask = inspect_crt_mask_payload(&file_name, &package)?;
        if largest_crt_mask
            .as_ref()
            .map(|(runs, _, _)| crt_mask.run_count > *runs)
            .unwrap_or(true)
        {
            largest_crt_mask = Some((
                crt_mask.run_count,
                crt_mask.used_length,
                shortname.clone(),
            ));
        }
        validated_count += 1;
    }

    let (max_runs, max_used, max_title) = largest_crt_mask
        .ok_or_else(|| "No supported packages were available to validate".to_string())?;
    println!(
        "Validated {} dual-resolution packages of {CRT_PACKAGE_SIZE:#x} bytes each (native CRT masks: max {max_runs} runs / {max_used:#x} bytes in {max_title}, capacity {CRT_MASK_CAPACITY:#x}; voice banks: {})",
        validated_count,
        voice_summary.join(", ")
    );
    Ok(())
}

fn validate_package(
    file_name: &str,
    package: &[u8],
    platform: &PlatformSpecification,
) -> Result<Option<usize>, String> {
        let mut voice_entries = None;
        if package.len() < IMAGE_AND_MASK_SIZE + 1 {
            return Err(format!("Package {file_name:?} is truncated"));
        }
        if !encode_format::is_valid_generator_stamp(&package[0xf9..0x100]) {
            return Err(format!(
                "Package {file_name:?} has invalid generator provenance"
            ));
        }
        if package[1] != cpu_config_value(&platform.device.cpu) {
            return Err(format!("Package {file_name:?} has the wrong CPU ID"));
        }
        let expected_screen = match platform.device.screen {
            manifest::Screen::Single { .. } => 0,
            manifest::Screen::DualVertical { .. } => 1,
            manifest::Screen::DualHorizontal { .. } => 2,
            manifest::Screen::TripleHorizontal { .. } => 3,
        };
        if package[2] != expected_screen {
            return Err(format!("Package {file_name:?} has the wrong screen ID"));
        }
        let crt_feature_bits = package[0x30] & (FEATURE_CRT_IMAGE | FEATURE_CRT_MASK);
        if crt_feature_bits != 0
            && crt_feature_bits != FEATURE_CRT_IMAGE | FEATURE_CRT_MASK
        {
            return Err(format!(
                "Package {file_name:?} declares only one of its two native CRT payloads"
            ));
        }
        let crt_mask = if crt_feature_bits != 0 {
            Some(inspect_crt_mask_payload(file_name, package)?)
        } else {
            None
        };
        let expected_config = encode_format::build_config(
            platform,
            platform.voice.is_some(),
            platform.aux_rom.is_some(),
            crt_mask.map(|summary| summary.used_length),
        )?;
        let has_player_two = expected_config[0x30] & FEATURE_PLAYER_TWO != 0;
        if package[..0xf9] != expected_config[..0xf9] {
            return Err(format!(
                "Package {file_name:?} config does not match the refreshed manifest"
            ));
        }
        validate_extension_directory(&file_name, &package, &expected_config)?;
        validate_declared_payloads(&file_name, &package, platform)?;

        let rom_start = IMAGE_AND_MASK_SIZE;
        if package.len() <= rom_start {
            return Err(format!("Package {file_name:?} has a truncated program ROM"));
        }
        let expected_rom = platform.rom.rom_hash.to_ascii_lowercase();
        let program_available = (package.len() - rom_start).min(PROGRAM_ROM_SIZE);
        let program_length = matching_sha1_prefix(
            &package[rom_start..rom_start + program_available],
            &expected_rom,
        )
        .ok_or_else(|| format!("Package {file_name:?} program SHA-1 does not match MAME"))?;

        let has_melody = matches!(
            platform.device.cpu,
            CPUType::SM511
                | CPUType::SM512
                | CPUType::SM530
                | CPUType::SM511Tiger1Bit
                | CPUType::SM511Tiger2Bit
        );
        if has_melody {
            let melody_start = rom_start + PROGRAM_ROM_SIZE;
            let melody_end = melody_start + MELODY_ROM_SIZE;
            if package.len() < melody_end {
                return Err(format!("Package {file_name:?} has a truncated melody ROM"));
            }
            if package[rom_start + program_length..melody_start]
                .iter()
                .any(|byte| *byte != 0)
            {
                return Err(format!(
                    "Package {file_name:?} has nonzero data in its program-ROM padding"
                ));
            }
            let expected_melody = platform
                .rom
                .melody_hash
                .as_ref()
                .ok_or_else(|| format!("Package {file_name:?} has no manifest melody SHA-1"))?;
            if sha1_hex(&package[melody_start..melody_end])
                != expected_melody.to_ascii_lowercase()
            {
                return Err(format!(
                    "Package {file_name:?} melody SHA-1 does not match MAME"
                ));
            }
        }

        let legacy_payload_end = if has_melody {
            rom_start + PROGRAM_ROM_SIZE + MELODY_ROM_SIZE
        } else {
            rom_start + program_length
        };

        if let Some(voice) = &platform.voice {
            if package[0] != 2 || package[0x30] & FEATURE_VOICE == 0 {
                return Err(format!("Voice package {file_name:?} is not marked V2"));
            }
            if package.len() < VOICE_PACKAGE_OFFSET + VOICE_BANK_SIZE {
                return Err(format!("Voice package {file_name:?} has a truncated voice bank"));
            }
            if package[legacy_payload_end..VOICE_PACKAGE_OFFSET]
                .iter()
                .any(|byte| *byte != 0)
            {
                return Err(format!(
                    "Voice package {file_name:?} has nonzero padding before its voice bank"
                ));
            }
            let entries = inspect_voice_bank(
                &package[VOICE_PACKAGE_OFFSET..VOICE_PACKAGE_OFFSET + VOICE_BANK_SIZE],
            )?;
            let actual_commands: Vec<u8> = entries
                .iter()
                .map(|(command, _, _)| *command)
                .collect();
            let expected_commands: Vec<u8> = voice
                .commands
                .iter()
                .enumerate()
                .filter_map(|(index, entry)| entry.as_ref().map(|_| (index + 1) as u8))
                .collect();
            if actual_commands != expected_commands {
                return Err(format!(
                    "Voice package {file_name:?} has commands {actual_commands:?}, expected {expected_commands:?}"
                ));
            }
            voice_entries = Some(entries.len());
        }

        if let Some(aux_rom) = &platform.aux_rom {
            if package[0] != 2
                || package[0x30] & (FEATURE_HMC | FEATURE_DIRECTORY)
                    != FEATURE_HMC | FEATURE_DIRECTORY
            {
                return Err(format!(
                    "HMC package {file_name:?} is not marked as an extended V2 package"
                ));
            }
            let preceding_end = if platform.voice.is_some() {
                VOICE_PACKAGE_OFFSET + VOICE_BANK_SIZE
            } else {
                legacy_payload_end
            };
            if package.len() < HMC_PACKAGE_OFFSET
                || package[preceding_end..HMC_PACKAGE_OFFSET]
                    .iter()
                    .any(|byte| *byte != 0)
            {
                return Err(format!(
                    "HMC package {file_name:?} has invalid padding before its HMC ROM"
                ));
            }
            validate_hmc_payload(&file_name, &package, aux_rom)?;
        }

        let legacy_expected_length = if platform.aux_rom.is_some() {
            HMC_PACKAGE_OFFSET + HMC_ROM_SIZE
        } else if platform.voice.is_some() {
            VOICE_PACKAGE_OFFSET + VOICE_BANK_SIZE
        } else {
            legacy_payload_end
        };
        let expected_length = if crt_mask.is_some() {
            if package.len() < CRT_IMAGE_PACKAGE_OFFSET
                || package[legacy_expected_length..CRT_IMAGE_PACKAGE_OFFSET]
                    .iter()
                    .any(|byte| *byte != 0)
            {
                return Err(format!(
                    "Package {file_name:?} has invalid padding before its native CRT image"
                ));
            }
            let crt_image_end = CRT_IMAGE_PACKAGE_OFFSET + CRT_IMAGE_SIZE;
            if package[crt_image_end..CRT_MASK_PACKAGE_OFFSET]
                .iter()
                .any(|byte| *byte != 0)
            {
                return Err(format!(
                    "Package {file_name:?} has nonzero padding after its native CRT image"
                ));
            }
            CRT_PACKAGE_SIZE
        } else {
            legacy_expected_length
        };
        if package.len() != expected_length {
            return Err(format!(
                "Package {file_name:?} has length {:#x}, expected {expected_length:#x}",
                package.len()
            ));
        }

        if platform.voice.is_none()
            && platform.aux_rom.is_none()
            && !has_player_two
            && crt_mask.is_none()
        {
            if package[0] != 1 || package[0x30] != 0 {
                return Err(format!("Legacy package {file_name:?} did not remain V1"));
            }
        }
    Ok(voice_entries)
}

fn matching_sha1_prefix(data: &[u8], expected_hash: &str) -> Option<usize> {
    let mut hasher = Sha1::new();
    for (index, byte) in data.iter().enumerate() {
        hasher.update([*byte]);
        if hex::encode(hasher.clone().finalize()) == expected_hash {
            return Some(index + 1);
        }
    }
    None
}

fn validate_hmc_payload(
    file_name: &str,
    package: &[u8],
    definition: &AuxROMDefinition,
) -> Result<(), String> {
    let AuxROMDefinition {
        rom_type,
        region,
        rom,
        size,
        rom_hash,
    } = definition;

    if *rom_type != AuxROMType::HA1152
        || *region != AuxROMRegion::Sfx
        || *size != HMC_ROM_SIZE
    {
        return Err(format!(
            "Package {file_name:?} has an invalid HA1152 manifest definition for {rom:?}"
        ));
    }
    let end = HMC_PACKAGE_OFFSET + HMC_ROM_SIZE;
    if package.len() < end {
        return Err(format!("Package {file_name:?} has a truncated HMC ROM"));
    }
    if sha1_hex(&package[HMC_PACKAGE_OFFSET..end]) != rom_hash.to_ascii_lowercase() {
        return Err(format!(
            "Package {file_name:?} HMC ROM SHA-1 does not match MAME"
        ));
    }
    Ok(())
}

fn sha1_hex(data: &[u8]) -> String {
    hex::encode(Sha1::digest(data))
}

fn package_file_name(platform: &PlatformSpecification) -> String {
    let mut game_name = platform.metadata.name.clone();
    if game_name.to_lowercase().starts_with("game & watch:") {
        game_name = game_name.chars().skip("Game & Watch:".len()).collect();
    }
    format!("{}.gnw", game_name.replace(":", " -").trim())
}

fn package_manufacturer_folder(platform: &PlatformSpecification) -> String {
    match platform.metadata.company.as_str() {
        "Nintendo" => "1. Nintendo".to_string(),
        "Tiger Electronics" => "2. Tiger Electronics".to_string(),
        "Konami" => "3. Konami".to_string(),
        "Nelsonic" => "4. Nelsonic".to_string(),
        "Elektronika" | "bootleg (Elektronika)" => "5. Elektronika".to_string(),
        "Tronica" => "6. Tronica".to_string(),
        "VTech" => "VTech".to_string(),
        "Homebrew" => "7. Homebrew".to_string(),
        company => {
            let sanitized: String = company
                .chars()
                .map(|character| {
                    if matches!(character, '<' | '>' | ':' | '"' | '/' | '\\' | '|' | '?' | '*')
                    {
                        '-'
                    } else {
                        character
                    }
                })
                .collect();
            sanitized.trim_matches([' ', '.']).to_string()
        }
    }
}

fn package_relative_path(platform: &PlatformSpecification) -> PathBuf {
    PathBuf::from(package_manufacturer_folder(platform)).join(package_file_name(platform))
}

fn cpu_config_value(cpu: &CPUType) -> u8 {
    match cpu {
        CPUType::SM510 => 0,
        CPUType::SM511 => 1,
        CPUType::SM512 => 2,
        CPUType::SM530 => 3,
        CPUType::SM5a => 4,
        CPUType::SM510Tiger => 5,
        CPUType::SM511Tiger1Bit => 6,
        CPUType::SM511Tiger2Bit => 7,
        CPUType::KB1013VK12 => 8,
    }
}

fn is_supported(name: &str, platform: &PlatformSpecification) -> bool {
    if platform.unsupported_reason.is_some() {
        return false;
    }

    // These devices need hardware interfaces outside the established controller and LCD model.
    if matches!(name, "bassmate" | "elbaskb" | "naltair" | "tgaiden") {
        return false;
    }

    !platform.port_map.ports.iter().any(|port| {
        let actions: Vec<&manifest::NamedAction> = match port {
            manifest::Port::S { bitmap, .. } => bitmap.iter().flatten().collect(),
            manifest::Port::ACL { bit }
            | manifest::Port::B { bit }
            | manifest::Port::BA { bit } => bit.iter().collect(),
        };

        actions.iter().any(|entry| {
            matches!(
                entry.action,
                manifest::Action::Button5
                    | manifest::Action::Button6
                    | manifest::Action::Button7
                    | manifest::Action::Button8
                    | manifest::Action::Keypad
                    | manifest::Action::Dial
                    | manifest::Action::Custom
            )
        })
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn package_contrast_repair_is_per_segment_and_idempotent() {
        fn mask_entry(id: u16, x: usize, length: usize) -> [u8; 5] {
            let packed = u64::from(id) | ((x as u64) << 10) | ((length as u64) << 30);
            [
                packed as u8,
                (packed >> 8) as u8,
                (packed >> 16) as u8,
                (packed >> 24) as u8,
                (packed >> 32) as u8,
            ]
        }

        let mut package = vec![0_u8; 4 * 6 + 3 * 5];
        for pixel in 0..4 {
            let offset = pixel * 6;
            package[offset..offset + 6].copy_from_slice(&[200, 200, 180, 180, 160, 160]);
        }
        package[2 * 6..2 * 6 + 6].copy_from_slice(&[200, 20, 180, 30, 160, 40]);
        package[3 * 6..3 * 6 + 6].copy_from_slice(&[200, 20, 180, 30, 160, 40]);
        package[24..29].copy_from_slice(&mask_entry(1, 0, 2));
        package[29..34].copy_from_slice(&mask_entry(2, 2, 2));

        assert_eq!(
            repair_image_lcd_contrast(&mut package, 0, 4, 1, 24, 15, "test").unwrap(),
            (1, 2)
        );
        assert_eq!(&package[0..6], &[200, 90, 180, 81, 160, 72]);
        assert_eq!(&package[12..18], &[200, 20, 180, 30, 160, 40]);
        assert_eq!(
            repair_image_lcd_contrast(&mut package, 0, 4, 1, 24, 15, "test").unwrap(),
            (0, 0)
        );
    }

    fn synthetic_hmc_fixture() -> (PlatformSpecification, Vec<u8>, Vec<u8>) {
        let program = vec![0x5a_u8; 0x800];
        let melody = vec![0xa5_u8; MELODY_ROM_SIZE];
        let hmc = vec![0x3c_u8; HMC_ROM_SIZE];
        let platform = serde_json::from_str(&format!(
            r#"{{
                "device":{{"cpu":"sm530","screen":{{"type":"single","width":1176,"height":1080}}}},
                "portMap":{{"ports":[]}},
                "metadata":{{"year":"1993","company":"Nelsonic","name":"Star Fox (Nelsonic)"}},
                "rom":{{"rom":"program","melody":"melody","melodyHash":"{}","romHash":"{}"}},
                "auxRom":{{"type":"ha1152","region":"sfx","rom":"ha1152_001a","size":128,"romHash":"{}"}}
            }}"#,
            sha1_hex(&melody),
            sha1_hex(&program),
            sha1_hex(&hmc),
        ))
        .expect("could not parse HA1152 fixture");

        let header = encode_format::build_config(&platform, false, true, Some(5)).unwrap();
        let mut package = vec![0_u8; CRT_PACKAGE_SIZE];
        package[..0x100].copy_from_slice(&header);
        package[IMAGE_AND_MASK_SIZE..IMAGE_AND_MASK_SIZE + program.len()]
            .copy_from_slice(&program);
        package[IMAGE_AND_MASK_SIZE + PROGRAM_ROM_SIZE
            ..IMAGE_AND_MASK_SIZE + PROGRAM_ROM_SIZE + melody.len()]
            .copy_from_slice(&melody);
        package[HMC_PACKAGE_OFFSET..HMC_PACKAGE_OFFSET + HMC_ROM_SIZE]
            .copy_from_slice(&hmc);

        (platform, header, package)
    }

    fn physical_slots(action: &manifest::Action) -> &'static [usize] {
        // 0-3 are the four D-pad directions. 4-13 are the ten stable
        // MiSTer button positions exposed by GameAndWatch.sv.
        match action {
            manifest::Action::JoyRight | manifest::Action::LeftJoyRight => &[0],
            manifest::Action::JoyLeft | manifest::Action::LeftJoyLeft => &[1],
            manifest::Action::JoyDown | manifest::Action::LeftJoyDown => &[2],
            manifest::Action::JoyUp | manifest::Action::LeftJoyUp => &[3],
            manifest::Action::CustomUpDown => &[2, 3],
            manifest::Action::Button1
            | manifest::Action::RightJoyDown
            | manifest::Action::CustomButtonHour => &[4],
            manifest::Action::Button2 | manifest::Action::RightJoyRight => &[5],
            manifest::Action::Button3 | manifest::Action::RightJoyLeft => &[6],
            manifest::Action::Button4 | manifest::Action::RightJoyUp => &[7],
            manifest::Action::Select => &[8],
            manifest::Action::Service2 => &[9],
            manifest::Action::Start1 | manifest::Action::PowerOn => &[10],
            manifest::Action::Start2 | manifest::Action::PowerOff => &[11],
            manifest::Action::VolumeDown | manifest::Action::Service4 => &[12],
            manifest::Action::Service1 | manifest::Action::Service3 => &[13],
            manifest::Action::Unused => &[],
            manifest::Action::Button5
            | manifest::Action::Button6
            | manifest::Action::Button7
            | manifest::Action::Button8
            | manifest::Action::Keypad
            | manifest::Action::Custom
            | manifest::Action::Dial => &[],
        }
    }

    fn platform_actions(platform: &PlatformSpecification) -> Vec<&manifest::NamedAction> {
        platform
            .port_map
            .ports
            .iter()
            .flat_map(|port| match port {
                manifest::Port::S { bitmap, .. } =>
                    bitmap.iter().flatten().collect::<Vec<_>>(),
                manifest::Port::ACL { bit }
                | manifest::Port::B { bit }
                | manifest::Port::BA { bit } => bit.iter().collect(),
            })
            .collect()
    }

    #[test]
    fn refreshed_manifest_has_expected_supported_scope_and_voice_maps() {
        let manifest_path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("manifest.json");
        if !manifest_path.exists() {
            eprintln!("Skipping refreshed-manifest validation; manifest.json has not been extracted");
            return;
        }

        let manifest: HashMap<String, PlatformSpecification> = serde_json::from_slice(
            &fs::read(&manifest_path).expect("could not read refreshed manifest"),
        )
        .expect("could not parse refreshed manifest");
        let supported: Vec<_> = manifest
            .iter()
            .filter(|(name, platform)| {
                matches!(
                    platform.device.cpu,
                    CPUType::SM5a
                        | CPUType::SM510
                        | CPUType::SM511
                        | CPUType::SM512
                        | CPUType::SM530
                        | CPUType::SM510Tiger
                        | CPUType::SM511Tiger1Bit
                        | CPUType::SM511Tiger2Bit
                ) && is_supported(name, platform)
            })
            .collect();
        assert_eq!(manifest.len(), 177);
        assert_eq!(supported.len(), 168);

        let mut manufacturer_folders = HashMap::new();
        for (_, platform) in &supported {
            *manufacturer_folders
                .entry(package_manufacturer_folder(platform))
                .or_insert(0_usize) += 1;
        }
        assert_eq!(
            manufacturer_folders.remove("1. Nintendo"),
            Some(59)
        );
        assert_eq!(manufacturer_folders.remove("2. Tiger Electronics"), Some(57));
        assert_eq!(manufacturer_folders.remove("3. Konami"), Some(20));
        assert_eq!(manufacturer_folders.remove("5. Elektronika"), Some(19));
        assert_eq!(manufacturer_folders.remove("6. Tronica"), Some(8));
        assert_eq!(manufacturer_folders.remove("4. Nelsonic"), Some(3));
        assert_eq!(manufacturer_folders.remove("7. Homebrew"), Some(2));
        assert!(manufacturer_folders.is_empty());

        let starfox_hmc = manifest["nstarfox"]
            .aux_rom
            .as_ref()
            .expect("refreshed MAME 0.289 manifest is missing the Star Fox HA1152 ROM");
        assert_eq!(starfox_hmc.rom_type, AuxROMType::HA1152);
        assert_eq!(starfox_hmc.region, AuxROMRegion::Sfx);
        assert_eq!(starfox_hmc.rom, "ha1152_001a");
        assert_eq!(starfox_hmc.size, HMC_ROM_SIZE);
        assert_eq!(
            starfox_hmc.rom_hash,
            "5dfb15eee3c57bbca80f485f68442e5f7c6bc5e4"
        );
        let auxiliary_titles: Vec<_> = manifest
            .iter()
            .filter_map(|(name, platform)| platform.aux_rom.as_ref().map(|_| name.as_str()))
            .collect();
        assert_eq!(auxiliary_titles, ["nstarfox"]);

        let default_sound_titles: Vec<_> = manifest
            .iter()
            .filter_map(|(name, platform)| {
                platform.default_sound_on.unwrap_or(false).then_some(name.as_str())
            })
            .collect();
        assert_eq!(default_sound_titles, ["nsmb3"]);
        let nsmb3_config =
            encode_format::build_config(&manifest["nsmb3"], false, false, None).unwrap();
        assert_eq!(
            nsmb3_config[0x30] & FEATURE_DEFAULT_SOUND_ON,
            FEATURE_DEFAULT_SOUND_ON
        );

        let expected_player_two_titles = ["gnw_boxing", "gnw_dkhockey", "gnw_dkong3"];
        let mut actual_player_two_titles = Vec::new();
        for (name, platform) in &supported {
            let config = encode_format::build_config(
                platform,
                platform.voice.is_some(),
                platform.aux_rom.is_some(),
                None,
            )
            .unwrap();
            let mask = &config
                [PLAYER_TWO_MASK_OFFSET..PLAYER_TWO_MASK_OFFSET + PLAYER_TWO_MASK_SIZE];
            if expected_player_two_titles.contains(&name.as_str()) {
                actual_player_two_titles.push(name.as_str());
                assert_eq!(mask, &[0x04, 0x0c, 0x0c, 0x00, 0x00], "{name}");
                assert_eq!(
                    config[0x30] & (FEATURE_PLAYER_TWO | FEATURE_DIRECTORY),
                    FEATURE_PLAYER_TWO | FEATURE_DIRECTORY,
                    "{name}"
                );
                assert_eq!(&config[0x31..0x35], b"GNWX", "{name}");
                assert_eq!(config[0x37], 0, "{name}");
            } else {
                assert_eq!(mask, &[0_u8; PLAYER_TWO_MASK_SIZE], "{name}");
                assert_eq!(config[0x30] & FEATURE_PLAYER_TWO, 0, "{name}");
            }
        }
        actual_player_two_titles.sort_unstable();
        assert_eq!(actual_player_two_titles, expected_player_two_titles);

        let topgun = manifest["ktopgun2"].voice.as_ref().expect("missing voice map");
        assert_eq!(topgun.commands.len(), 14);
        assert!(topgun.commands[2].is_none());
        assert!(topgun.commands[6].is_none());
        assert!(topgun.commands[10].is_none());
        assert!(topgun.commands[12].is_none());

        let config =
            encode_format::build_config(&manifest["ktmnt2"], true, false, None).unwrap();
        assert_eq!(config.len(), 0x100);
        assert_eq!(config[0], 2);
        assert_eq!(config[0x30] & 1, 1);

        let treasure = &manifest["trtreisl"];
        let config = encode_format::build_config(treasure, false, false, None).unwrap();
        assert_eq!(config[0x10], 33, "Service4/Minute needs a unique ID");
        assert_eq!(config[0x14], 16, "Service2/Alarm must retain ID 16");

        let minute = treasure
            .port_map
            .ports
            .iter()
            .find_map(|port| match port {
                manifest::Port::S { bitmap, .. } => bitmap
                    .iter()
                    .flatten()
                    .find(|entry| entry.action == manifest::Action::Service4),
                _ => None,
            })
            .expect("missing Treasure Island Minute input");
        assert_eq!(minute.name.as_deref(), Some("Min"));

        let pause = manifest["kst25"]
            .port_map
            .ports
            .iter()
            .find_map(|port| match port {
                manifest::Port::S { bitmap, .. } => bitmap
                    .iter()
                    .flatten()
                    .find(|entry| entry.action == manifest::Action::Select),
                _ => None,
            })
            .expect("missing Star Trek Pause input");
        assert_eq!(pause.name.as_deref(), Some("Pause"));

        let speed = manifest["auslalom"]
            .port_map
            .ports
            .iter()
            .find_map(|port| match port {
                manifest::Port::S { bitmap, .. } => bitmap
                    .iter()
                    .flatten()
                    .find(|entry| entry.action == manifest::Action::Button1),
                _ => None,
            })
            .expect("missing Autoslalom Speed input");
        assert_eq!(speed.name.as_deref(), Some("Скорость (Speed)"));

        // Prove that every supported package fits the compiled D-pad + ten
        // button contract without collapsing two distinct actions onto one
        // physical control. Repeated identical actions (the legacy Micro Vs.
        // player rows) do not consume another slot.
        let mut nine_button_titles = Vec::new();
        for (name, platform) in &supported {
            let mut slots: [Vec<manifest::Action>; 14] = std::array::from_fn(|_| Vec::new());
            for entry in platform_actions(platform) {
                let positions = physical_slots(&entry.action);
                assert!(
                    !positions.is_empty() || entry.action == manifest::Action::Unused,
                    "supported title {name} contains unmapped action {:?}",
                    entry.action
                );
                for position in positions {
                    if !slots[*position].contains(&entry.action) {
                        slots[*position].push(entry.action.clone());
                    }
                }
            }

            for (slot, actions) in slots.iter().enumerate() {
                assert!(
                    actions.len() <= 1,
                    "supported title {name} aliases distinct actions {actions:?} on physical slot {slot}"
                );
            }

            let buttons_used = slots[4..].iter().filter(|actions| !actions.is_empty()).count();
            assert!(
                buttons_used <= 10,
                "supported title {name} needs {buttons_used} buttons"
            );
            if buttons_used == 9 {
                nine_button_titles.push((*name).clone());
            }
        }
        nine_button_titles.sort();
        assert_eq!(
            nine_button_titles,
            [
                "tapollo13",
                "tbatfor",
                "tdennis",
                "tgaunt",
                "tgoldeye",
                "tjdredd",
                "tkazaam",
                "tmchammer",
                "tmkombat",
                "tpitfight",
                "trobhood",
                "tsddragon",
            ]
        );
    }

    #[test]
    fn package_config_is_independently_replaceable() {
        // The fixed 0x100-byte header is intentionally independent of the
        // rendered artwork, mask runs, and ROM payload. This both documents
        // the package contract and gives migrations a safe way to refresh
        // semantic input IDs without reprocessing unchanged copyrighted
        // assets.
        let manifest_path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("manifest.json");
        if !manifest_path.exists() {
            eprintln!("Skipping package-header validation; manifest.json has not been extracted");
            return;
        }

        let manifest: HashMap<String, PlatformSpecification> = serde_json::from_slice(
            &fs::read(&manifest_path).expect("could not read refreshed manifest"),
        )
        .expect("could not parse refreshed manifest");
        let treasure = &manifest["trtreisl"];

        let background = vec![0_u8; WIDTH * HEIGHT * 4];
        let masks = vec![0_u8; WIDTH * HEIGHT * 4];
        let pixels = vec![None; WIDTH * HEIGHT];
        let expected_config =
            encode_format::build_config(treasure, false, false, None).unwrap();

        let background_iter = background.iter();
        let mask_iter = masks.iter();
        let mut component = 0;
        let image_block: Vec<u8> = background_iter
            .zip(mask_iter)
            .filter(|_| {
                let previous = component;
                component = (component + 1) & 3;
                previous != 3
            })
            .flat_map(|(background_byte, mask_byte)| [*background_byte, *mask_byte])
            .collect();
        let mask_block = encode_format::build_mask_map(&pixels).unwrap();

        let mut package = expected_config.clone();
        package.extend(image_block);
        package.extend(mask_block);
        package.extend([0x5a_u8; 0x1100]);

        assert_eq!(package.len(), IMAGE_AND_MASK_SIZE + 0x1100);
        assert_eq!(&package[..0x100], expected_config.as_slice());
        assert!(package[0x100..IMAGE_AND_MASK_SIZE]
            .iter()
            .all(|byte| *byte == 0));
        assert!(package[IMAGE_AND_MASK_SIZE..]
            .iter()
            .all(|byte| *byte == 0x5a));
    }

    #[test]
    fn header_refresh_rejects_payload_feature_changes() {
        let (platform, expected_hmc, valid_package) = synthetic_hmc_fixture();
        let legacy_header = encode_format::build_config(&platform, false, false, None).unwrap();
        let mut legacy_package = valid_package.clone();
        legacy_package[..0x100].copy_from_slice(&legacy_header);

        let error = guard_header_refresh(
            "Star Fox (Nelsonic).gnw",
            &legacy_package,
            &expected_hmc,
            &platform,
        )
        .expect_err("a header refresh must not synthesize a missing HMC payload");
        assert!(error.contains("regenerate it instead of refreshing"));

        let mut bad_descriptor_package = valid_package.clone();
        bad_descriptor_package[0x40] = 0x7f;
        let error = guard_header_refresh(
            "Star Fox (Nelsonic).gnw",
            &bad_descriptor_package,
            &expected_hmc,
            &platform,
        )
        .expect_err("a header refresh must not rewrite a payload descriptor");
        assert!(error.contains("payload descriptors differ"));

        guard_header_refresh(
            "Star Fox (Nelsonic).gnw",
            &valid_package,
            &expected_hmc,
            &platform,
        )
        .expect("a matching payload must be safe to refresh");

        let mut bad_hmc_package = valid_package.clone();
        bad_hmc_package[HMC_PACKAGE_OFFSET] ^= 1;
        let error = guard_header_refresh(
            "Star Fox (Nelsonic).gnw",
            &bad_hmc_package,
            &expected_hmc,
            &platform,
        )
        .expect_err("header refresh must reject corrupted HMC bytes");
        assert!(error.contains("HMC ROM SHA-1 does not match"));

        let mut bad_program_package = valid_package.clone();
        bad_program_package[IMAGE_AND_MASK_SIZE] ^= 1;
        let error = guard_header_refresh(
            "Star Fox (Nelsonic).gnw",
            &bad_program_package,
            &expected_hmc,
            &platform,
        )
        .expect_err("header refresh must run full program validation");
        assert!(error.contains("program SHA-1 does not match"));

        let mut bad_melody_package = valid_package;
        bad_melody_package[IMAGE_AND_MASK_SIZE + PROGRAM_ROM_SIZE] ^= 1;
        let error = guard_header_refresh(
            "Star Fox (Nelsonic).gnw",
            &bad_melody_package,
            &expected_hmc,
            &platform,
        )
        .expect_err("header refresh must run full melody validation");
        assert!(error.contains("melody SHA-1 does not match"));
    }

    #[test]
    fn player_two_allows_zero_descriptors_but_requires_gnwx() {
        let mut expected = vec![0_u8; 0x100];
        expected[0] = 2;
        expected[0x30] = FEATURE_PLAYER_TWO | FEATURE_DIRECTORY;
        expected[0x31..0x35].copy_from_slice(b"GNWX");
        expected[0x35..0x38].copy_from_slice(&[1, 16, 0]);
        expected[PLAYER_TWO_MASK_OFFSET..PLAYER_TWO_MASK_OFFSET + PLAYER_TWO_MASK_SIZE]
            .copy_from_slice(&[0x04, 0x0c, 0x0c, 0x00, 0x00]);

        validate_extension_directory("Micro Vs. Test.gnw", &expected, &expected)
            .expect("P2-only GNWX directories intentionally have zero descriptors");

        let mut missing_directory = expected.clone();
        missing_directory[0x30] &= !FEATURE_DIRECTORY;
        let error = validate_extension_directory(
            "Micro Vs. Test.gnw",
            &missing_directory,
            &expected,
        )
        .expect_err("P2 ownership must never be accepted without GNWX");
        assert!(error.contains("directory-backed features"));

        let mut missing_payload_descriptor = expected;
        missing_payload_descriptor[0x30] |= FEATURE_HMC;
        let error = validate_extension_directory(
            "Micro Vs. Test.gnw",
            &missing_payload_descriptor,
            &missing_payload_descriptor,
        )
        .expect_err("descriptor-backed features must not use the P2 zero-count exception");
        assert!(error.contains("invalid extension descriptor count"));
    }

    #[test]
    fn package_header_refresh_preflights_before_writing() {
        let (mut platform, _old_header, valid_package) = synthetic_hmc_fixture();
        platform.default_sound_on = Some(true);
        let expected_header =
            encode_format::build_config(&platform, false, true, Some(5)).unwrap();
        let temp = std::env::temp_dir().join(format!(
            "gnw-header-refresh-test-{}",
            std::process::id()
        ));
        if temp.exists() {
            fs::remove_dir_all(&temp).unwrap();
        }
        fs::create_dir_all(&temp).unwrap();

        let package_path = temp.join(package_relative_path(&platform));
        fs::create_dir_all(package_path.parent().unwrap()).unwrap();
        let mut manifest = HashMap::new();
        manifest.insert("nstarfox".to_string(), platform);

        let mut stale_valid_package = valid_package.clone();
        stale_valid_package[0x08] ^= 1;
        fs::write(&package_path, &stale_valid_package).unwrap();
        refresh_package_configs(&manifest, &temp).expect("valid package should refresh");
        let refreshed = fs::read(&package_path).unwrap();
        assert_eq!(&refreshed[..0x100], expected_header.as_slice());
        assert_eq!(refreshed[0x30] & FEATURE_DEFAULT_SOUND_ON, FEATURE_DEFAULT_SOUND_ON);
        assert_eq!(&refreshed[0x100..], &valid_package[0x100..]);

        let mut stale_invalid_package = valid_package;
        stale_invalid_package[0x08] ^= 1;
        stale_invalid_package[IMAGE_AND_MASK_SIZE] ^= 1;
        fs::write(&package_path, &stale_invalid_package).unwrap();
        let error = refresh_package_configs(&manifest, &temp)
            .expect_err("invalid payload must abort before any header write");
        assert!(error.contains("program SHA-1 does not match"));
        assert_eq!(fs::read(&package_path).unwrap(), stale_invalid_package);

        fs::remove_dir_all(temp).unwrap();
    }

    #[test]
    fn crt_package_validation_rejects_partial_features_bad_lengths_and_dirty_tail() {
        let (platform, _, valid_package) = synthetic_hmc_fixture();
        validate_package("Star Fox (Nelsonic).gnw", &valid_package, &platform)
            .expect("the complete synthetic dual-resolution package must validate");

        let mut partial_features = valid_package.clone();
        partial_features[0x30] &= !FEATURE_CRT_MASK;
        let error = validate_package(
            "Star Fox (Nelsonic).gnw",
            &partial_features,
            &platform,
        )
        .expect_err("one CRT feature bit without the other must fail closed");
        assert!(error.contains("only one"));

        let mut bad_declared_length = valid_package.clone();
        // HMC is descriptor 0, CRT image is 1, and CRT mask is 2. Its LE32
        // length begins at config byte 0x68 and must equal the terminator scan.
        bad_declared_length[0x68..0x6c].copy_from_slice(&10_u32.to_le_bytes());
        let error = validate_package(
            "Star Fox (Nelsonic).gnw",
            &bad_declared_length,
            &platform,
        )
        .expect_err("a descriptor must not extend beyond the actual mask terminator");
        assert!(error.contains("config does not match"));

        let mut dirty_tail = valid_package;
        dirty_tail[CRT_MASK_PACKAGE_OFFSET + 5] = 1;
        let error = validate_package("Star Fox (Nelsonic).gnw", &dirty_tail, &platform)
            .expect_err("padding after the explicit terminator must remain zero");
        assert!(error.contains("nonzero data after"));

        let (_, _, mut dirty_image_gap) = synthetic_hmc_fixture();
        dirty_image_gap[CRT_IMAGE_PACKAGE_OFFSET + CRT_IMAGE_SIZE] = 1;
        let error = validate_package(
            "Star Fox (Nelsonic).gnw",
            &dirty_image_gap,
            &platform,
        )
        .expect_err("padding between the 360x240 image and fixed mask offset must remain zero");
        assert!(error.contains("nonzero padding after"));
    }
}
