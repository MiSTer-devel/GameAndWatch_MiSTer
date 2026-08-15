use std::{
    fs::{self, File},
    io::{self, Read, Seek},
    path::{Path, PathBuf},
};

use bitvec::{
    field::BitField,
    prelude::{bitvec, Lsb0},
};

use sha1::{Digest, Sha1};

use crate::{
    audio::{build_voice_bank, validate_voice_bank, VOICE_BANK_SIZE},
    manifest::{
        Action, AuxROMDefinition, AuxROMRegion, AuxROMType, CPUType, NamedAction,
        PlatformSpecification, Port, Screen,
    },
    HEIGHT, WIDTH,
};

const PROGRAM_ROM_SIZE: usize = 0x1000;
const MELODY_ROM_SIZE: usize = 0x100;
pub(crate) const VOICE_PACKAGE_OFFSET: usize = 0x326340;
pub(crate) const HMC_PACKAGE_OFFSET: usize = 0x336400;
pub(crate) const HMC_ROM_SIZE: usize = 0x80;
pub(crate) const CRT_IMAGE_PACKAGE_OFFSET: usize = 0x336500;
pub(crate) const CRT_IMAGE_WIDTH: usize = 360;
pub(crate) const CRT_IMAGE_HEIGHT: usize = 240;
pub(crate) const CRT_IMAGE_SIZE: usize = CRT_IMAGE_WIDTH * CRT_IMAGE_HEIGHT * 6;
pub(crate) const CRT_MASK_PACKAGE_OFFSET: usize = 0x433700;
pub(crate) const CRT_MASK_CAPACITY: usize = 52 * CRT_IMAGE_HEIGHT * 5;
pub(crate) const CRT_PACKAGE_SIZE: usize = CRT_MASK_PACKAGE_OFFSET + CRT_MASK_CAPACITY;
pub(crate) const FEATURE_VOICE: u8 = 0x01;
pub(crate) const FEATURE_HMC: u8 = 0x02;
pub(crate) const FEATURE_PLAYER_TWO: u8 = 0x04;
pub(crate) const FEATURE_CRT_IMAGE: u8 = 0x08;
pub(crate) const FEATURE_CRT_MASK: u8 = 0x10;
pub(crate) const FEATURE_DEFAULT_SOUND_ON: u8 = 0x20;
pub(crate) const FEATURE_DIRECTORY: u8 = 0x80;

const DIRECTORY_MAGIC_OFFSET: usize = 0x31;
const DIRECTORY_REVISION_OFFSET: usize = 0x35;
const DIRECTORY_DESCRIPTOR_SIZE_OFFSET: usize = 0x36;
const DIRECTORY_DESCRIPTOR_COUNT_OFFSET: usize = 0x37;
pub(crate) const PLAYER_TWO_MASK_OFFSET: usize = 0x38;
pub(crate) const PLAYER_TWO_MASK_SIZE: usize = 5;
const DIRECTORY_DESCRIPTORS_OFFSET: usize = 0x40;
const DIRECTORY_REVISION: u8 = 1;
const DIRECTORY_DESCRIPTOR_SIZE: usize = 16;
pub(crate) const DESCRIPTOR_KIND_VOICE: u8 = 0x01;
pub(crate) const DESCRIPTOR_KIND_HMC: u8 = 0x02;
pub(crate) const DESCRIPTOR_KIND_CRT_IMAGE: u8 = 0x10;
pub(crate) const DESCRIPTOR_KIND_CRT_MASK: u8 = 0x11;
const DESCRIPTOR_ENCODING_RAW: u8 = 0x01;
const DESCRIPTOR_ENCODING_RLE40: u8 = 0x02;
const DESCRIPTOR_VARIANT_VOICE_V1: u8 = 0x01;
const DESCRIPTOR_VARIANT_HA1152: u8 = 0x01;
const DESCRIPTOR_VARIANT_COMPONENT_PAIRED_RGB: u8 = 0x01;
const DESCRIPTOR_VARIANT_MASK_RLE_V1: u8 = 0x01;
const GENERATOR_STAMP_FALLBACK: [u8; 7] = *b"unknown";

fn generator_stamp(raw_sha: Option<&str>) -> [u8; 7] {
    let Some(raw_sha) = raw_sha.map(str::trim).filter(|sha| {
        sha.len() >= 7 && sha.as_bytes().iter().all(u8::is_ascii_hexdigit)
    }) else {
        return GENERATOR_STAMP_FALLBACK;
    };

    let mut stamp = [0_u8; 7];
    for (output, input) in stamp.iter_mut().zip(raw_sha.bytes()) {
        *output = input.to_ascii_lowercase();
    }
    stamp
}

pub(crate) fn is_valid_generator_stamp(stamp: &[u8]) -> bool {
    stamp == GENERATOR_STAMP_FALLBACK
        || (stamp.len() == 7
            && stamp
                .iter()
                .all(|byte| byte.is_ascii_digit() || matches!(byte, b'a'..=b'f')))
}

pub fn encode(
    background_bytes: &[u8],
    mask_bytes: &[u8],
    pixels_to_mask_id: &[Option<u16>],
    crt_background_bytes: &[u8],
    crt_mask_bytes: &[u8],
    crt_pixels_to_mask_id: &[Option<u16>],
    platform: &PlatformSpecification,
    asset_dir: &Path,
    output_dir: &Path,
) -> Result<PathBuf, String> {
    let voice_bank = platform
        .voice
        .as_ref()
        .map(|definition| build_voice_bank(definition, asset_dir))
        .transpose()?;
    if let Some(bank) = &voice_bank {
        validate_voice_bank(bank)?;
    }
    let hmc_rom = platform
        .aux_rom
        .as_ref()
        .map(|definition| read_hmc_rom(definition, asset_dir))
        .transpose()?;

    let mut image_block = build_image_block(background_bytes, mask_bytes, WIDTH, HEIGHT)?;
    let mut crt_image_block = build_image_block(
        crt_background_bytes,
        crt_mask_bytes,
        CRT_IMAGE_WIDTH,
        CRT_IMAGE_HEIGHT,
    )?;
    if crt_image_block.len() != CRT_IMAGE_SIZE {
        return Err(format!(
            "CRT image encoder produced {:#x} bytes, expected {CRT_IMAGE_SIZE:#x}",
            crt_image_block.len()
        ));
    }

    let crt_mask = build_crt_mask_map(crt_pixels_to_mask_id)?;
    if crt_mask.used_length != (crt_mask.run_count + 1) * BYTES_PER_ENTRY {
        return Err("CRT mask encoder produced an inconsistent terminator length".to_string());
    }

    // Build config only after the mask is encoded: its descriptor records the
    // exact byte count through the explicit zero terminator, while the package
    // reserves and zero-fills the full fixed-capacity region.
    let mut config = build_config(
        platform,
        voice_bank.is_some(),
        hmc_rom.is_some(),
        Some(crt_mask.used_length),
    )?;

    config.append(&mut image_block);

    // Build mask config
    let mut mask_block = build_mask_map(pixels_to_mask_id)?;

    config.append(&mut mask_block);

    // Add ROM data. Melody data is appended at offset 0x1000 so old SM510/SM5a
    // packages remain layout-compatible.
    let mut rom_data =
        read_rom_by_name_or_hash(&platform.rom.rom, &platform.rom.rom_hash, asset_dir)?;

    if has_melody_rom(&platform.device.cpu) {
        if rom_data.len() > PROGRAM_ROM_SIZE {
            return Err(format!(
                "Program ROM for {} is larger than {PROGRAM_ROM_SIZE:#x} bytes",
                platform.metadata.name
            ));
        }

        rom_data.resize(PROGRAM_ROM_SIZE, 0);

        let melody_name = platform
            .rom
            .melody
            .as_ref()
            .ok_or_else(|| format!("{} requires a melody ROM", platform.metadata.name))?;
        let mut melody_data = if let Some(melody_hash) = &platform.rom.melody_hash {
            read_rom_by_name_or_hash(melody_name, melody_hash, asset_dir)?
        } else {
            read_rom_by_name(melody_name, asset_dir)?
        };

        if melody_data.len() != MELODY_ROM_SIZE {
            return Err(format!(
                "Melody ROM {melody_name:?} for {} was {} bytes, expected {MELODY_ROM_SIZE:#x}",
                platform.metadata.name,
                melody_data.len()
            ));
        }

        rom_data.append(&mut melody_data);
    }

    config.append(&mut rom_data);

    if let Some(mut voice_bank) = voice_bank {
        let desired_length = VOICE_PACKAGE_OFFSET;
        if config.len() > desired_length {
            return Err(format!(
                "Package data overlaps the voice-bank offset: {:#x} > {desired_length:#x}",
                config.len()
            ));
        }
        config.resize(desired_length, 0);
        config.append(&mut voice_bank);
    }

    if let Some(mut hmc_rom) = hmc_rom {
        if config.len() > HMC_PACKAGE_OFFSET {
            return Err(format!(
                "Package data overlaps the HMC-ROM offset: {:#x} > {HMC_PACKAGE_OFFSET:#x}",
                config.len()
            ));
        }
        config.resize(HMC_PACKAGE_OFFSET, 0);
        config.append(&mut hmc_rom);
    }

    if config.len() > CRT_IMAGE_PACKAGE_OFFSET {
        return Err(format!(
            "Package data overlaps the CRT-image offset: {:#x} > {CRT_IMAGE_PACKAGE_OFFSET:#x}",
            config.len()
        ));
    }
    config.resize(CRT_IMAGE_PACKAGE_OFFSET, 0);
    config.append(&mut crt_image_block);
    if config.len() > CRT_MASK_PACKAGE_OFFSET {
        return Err(format!(
            "CRT image overlaps the fixed mask offset: {:#x} > {CRT_MASK_PACKAGE_OFFSET:#x}",
            config.len()
        ));
    }
    // Keep the established mask offset and package size stable. The smaller
    // 360x240 image leaves a reserved span that must be deterministic zero
    // padding so validators and future format revisions can fail closed.
    config.resize(CRT_MASK_PACKAGE_OFFSET, 0);
    config.extend_from_slice(&crt_mask.bytes);
    if config.len() != CRT_PACKAGE_SIZE {
        return Err(format!(
            "Dual-resolution package ended at {:#x}, expected {CRT_PACKAGE_SIZE:#x}",
            config.len()
        ));
    }

    let mut game_name = platform.metadata.name.clone();

    if game_name.to_lowercase().starts_with("game & watch:") {
        game_name = game_name.chars().skip("Game & Watch:".len()).collect();
    }

    game_name = game_name.replace(":", " -");
    let game_name = game_name.trim();

    let output_path: PathBuf = output_dir.join(format!("{game_name}.gnw"));
    fs::write(&output_path, config)
        .map_err(|err| format!("Could not write package {output_path:?}: {err}"))?;

    Ok(output_path)
}

fn has_melody_rom(cpu_type: &CPUType) -> bool {
    matches!(
        cpu_type,
        CPUType::SM511
            | CPUType::SM512
            | CPUType::SM530
            | CPUType::SM511Tiger1Bit
            | CPUType::SM511Tiger2Bit
    )
}

fn read_rom_by_name(name: &String, asset_dir: &Path) -> Result<Vec<u8>, String> {
    let path = asset_dir.join(name);

    fs::read(&path).map_err(|_| format!("Could not open ROM {path:?}"))
}

fn read_rom_by_name_or_hash(
    name: &String,
    target_hash: &String,
    asset_dir: &Path,
) -> Result<Vec<u8>, String> {
    match read_rom_by_name(name, asset_dir) {
        Ok(data) => Ok(data),
        Err(name_err) => match find_rom_by_hash(target_hash, asset_dir) {
            Ok(data) => Ok(data),
            Err(hash_err) => Err(format!("{hash_err}\n{name_err}")),
        },
    }
}

fn build_image_block(
    background_bytes: &[u8],
    mask_bytes: &[u8],
    width: usize,
    height: usize,
) -> Result<Vec<u8>, String> {
    let rgba_size = width
        .checked_mul(height)
        .and_then(|pixels| pixels.checked_mul(4))
        .ok_or_else(|| "Image dimensions overflowed the host address space".to_string())?;
    if background_bytes.len() != rgba_size || mask_bytes.len() != rgba_size {
        return Err(format!(
            "Rendered image buffers were {} and {} bytes, expected {rgba_size}",
            background_bytes.len(),
            mask_bytes.len()
        ));
    }

    let mut output = Vec::with_capacity(width * height * 6);
    for (background, mask) in background_bytes
        .chunks_exact(4)
        .zip(mask_bytes.chunks_exact(4))
    {
        // Preserve the legacy component-paired layout consumed by the FPGA:
        // background is the low byte for R, G, and B in sequence.
        output.extend_from_slice(&[
            background[0],
            mask[0],
            background[1],
            mask[1],
            background[2],
            mask[2],
        ]);
    }
    Ok(output)
}

fn read_hmc_rom(definition: &AuxROMDefinition, asset_dir: &Path) -> Result<Vec<u8>, String> {
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
            "HA1152 auxiliary ROM {rom:?} must describe region \"sfx\" with size {HMC_ROM_SIZE:#x}"
        ));
    }

    let data = read_rom_by_name_or_hash(rom, rom_hash, asset_dir)?;
    if data.len() != *size {
        return Err(format!(
            "HA1152 ROM {rom:?} was {} bytes, expected {size:#x}",
            data.len()
        ));
    }
    let actual_hash = hex::encode(Sha1::digest(&data));
    if actual_hash != rom_hash.to_ascii_lowercase() {
        return Err(format!(
            "HA1152 ROM {rom:?} SHA-1 {actual_hash} does not match manifest {}",
            rom_hash.to_ascii_lowercase()
        ));
    }

    Ok(data)
}

fn find_rom_by_hash(target_hash: &String, asset_dir: &Path) -> Result<Vec<u8>, String> {
    for entry in fs::read_dir(asset_dir).expect("Could not open temp directory") {
        if let Ok(entry) = entry {
            let mut file = match File::open(entry.path()) {
                Ok(file) => file,
                Err(_) => continue,
            };
            let mut hasher = Sha1::new();
            let _ = match io::copy(&mut file, &mut hasher) {
                Ok(_) => {}
                Err(_) => continue,
            };
            let hash = hasher.finalize();

            let hash = hex::encode(hash);

            if &hash == target_hash {
                let mut buffer = Vec::new();
                if let Err(_) = file.seek(io::SeekFrom::Start(0)) {
                    return Err("Could not reread from file after hash check".into());
                }
                if let Err(_) = file.read_to_end(&mut buffer) {
                    return Err(format!("Could not open SHA matched ROM {:?}", entry.path()));
                }

                return Ok(buffer);
            }
        }
    }

    Err(format!("No SHA matched ROM found"))
}

fn build_player_two_mask(
    platform: &PlatformSpecification,
) -> Result<[u8; PLAYER_TWO_MASK_SIZE], String> {
    let mut mask = [0_u8; PLAYER_TWO_MASK_SIZE];

    let mut assign_owner = |action: &NamedAction, cell: usize| -> Result<(), String> {
        match action.player {
            None | Some(1) => Ok(()),
            Some(2) => {
                mask[cell / 8] |= 1 << (cell % 8);
                Ok(())
            }
            Some(player) => Err(format!(
                "{} assigns unsupported player {player} to an electrical input cell",
                platform.metadata.name
            )),
        }
    };

    for port in &platform.port_map.ports {
        match port {
            Port::S { index, bitmap } => {
                if *index > 7 {
                    return Err(format!("Port index {index} is out of bounds"));
                }
                for (bit, action) in bitmap.iter().enumerate() {
                    if let Some(action) = action {
                        assign_owner(action, *index * 4 + bit)?;
                    }
                }
            }
            Port::B { bit } => {
                if let Some(action) = bit {
                    assign_owner(action, 32)?;
                }
            }
            Port::BA { bit } => {
                if let Some(action) = bit {
                    assign_owner(action, 33)?;
                }
            }
            Port::ACL { bit } => {
                if let Some(action) = bit {
                    assign_owner(action, 34)?;
                }
            }
        }
    }

    Ok(mask)
}

pub(crate) fn build_config(
    platform: &PlatformSpecification,
    has_voice: bool,
    has_hmc: bool,
    crt_mask_used_length: Option<usize>,
) -> Result<Vec<u8>, String> {
    if let Some(length) = crt_mask_used_length {
        if length < BYTES_PER_ENTRY
            || length > CRT_MASK_CAPACITY
            || length % BYTES_PER_ENTRY != 0
        {
            return Err(format!(
                "CRT mask declared length {length:#x} is outside its aligned capacity"
            ));
        }
    }
    let has_crt_assets = crt_mask_used_length.is_some();
    let has_default_sound_on = platform.default_sound_on.unwrap_or(false);
    let player_two_mask = build_player_two_mask(platform)?;
    let has_player_two = player_two_mask.iter().any(|byte| *byte != 0);
    let has_directory = has_hmc || has_player_two || has_crt_assets;
    let mut config = Vec::<u8>::with_capacity(0x100);
    // Version
    config.push(if has_voice
        || has_hmc
        || has_player_two
        || has_crt_assets
        || has_default_sound_on
    {
        2
    } else {
        1
    });

    // MPU version
    let version = match platform.device.cpu {
        CPUType::SM510 => 0,
        CPUType::SM511 => 1,
        CPUType::SM512 => 2,
        CPUType::SM530 => 3,
        CPUType::SM5a => 4,
        CPUType::SM510Tiger => 5,
        CPUType::SM511Tiger1Bit => 6,
        CPUType::SM511Tiger2Bit => 7,
        CPUType::KB1013VK12 => 8,
    };

    config.push(version);

    // Screen configuration
    let (screen, width, height) = match &platform.device.screen {
        Screen::Single { width, height } => (0, *width, *height),
        Screen::DualVertical { top, bottom } => {
            if top != bottom {
                println!("Top and bottom screen sizes don't match");
            }

            (1, top.width, top.height)
        }
        Screen::DualHorizontal { left, right } => {
            if left != right {
                println!("Left and right screen sizes don't match");
            }

            (2, left.width, left.height)
        }
        Screen::TripleHorizontal {
            left,
            middle,
            right,
        } => {
            if left.height != middle.height || middle.height != right.height {
                println!("Triple-horizontal screen heights don't match");
            }

            // The current FPGA package renderer uses the per-screen SVG bounds,
            // but keep a representative panel size in the legacy 12-bit field.
            (3, middle.width, middle.height)
        }
    };
    config.push(screen);

    let mut data: bitvec::vec::BitVec<u8> = bitvec![u8, Lsb0; 0; 3*8];
    let width = width.round() as u16;
    let height = height.round() as u16;
    data[0..10].store(width);
    data[10..20].store(height);

    config.append(&mut data.into());

    // Reserved
    config.push(0);
    config.push(0);

    // Input mapping
    let mut s_ports: [Option<[Option<NamedAction>; 4]>; 8] = Default::default();
    let mut b_port: Option<NamedAction> = None;
    let mut ba_port: Option<NamedAction> = None;
    let mut acl_port: Option<NamedAction> = None;

    for port in &platform.port_map.ports {
        match port {
            Port::S { index, bitmap } => {
                if *index > 7 {
                    return Err(format!("Port index {index} is out of bounds"));
                }

                s_ports[*index] = Some(bitmap.clone());
            }
            Port::ACL { bit } => acl_port = bit.clone(),
            Port::B { bit } => b_port = bit.clone(),
            Port::BA { bit } => ba_port = bit.clone(),
        }
    }

    for port in s_ports {
        if let Some(port) = port {
            for action in port {
                if let Some(action) = action {
                    config.push(input_value_for_port(action));
                } else {
                    config.push(0x7F);
                }
            }
        } else {
            // Write 4 zeros
            config.push(0x7F);
            config.push(0x7F);
            config.push(0x7F);
            config.push(0x7F);
        }
    }

    let unused_action = NamedAction {
        action: Action::Unused,
        active_low: true,
        name: None,
        player: None,
    };

    let b_port = if let Some(b_port) = b_port {
        input_value_for_port(b_port)
    } else {
        // B and BA have pull-ups, so an absent pin is represented by the
        // legacy active-low unused value and resolves electrically high.
        input_value_for_port(unused_action.clone())
    };
    config.push(b_port);

    let ba_port = if let Some(ba_port) = ba_port {
        input_value_for_port(ba_port)
    } else {
        input_value_for_port(unused_action.clone())
    };
    config.push(ba_port);

    let acl_port = if let Some(acl_port) = acl_port {
        input_value_for_port(acl_port)
    } else {
        // ACL has no B/BA pull-up semantics. Keep absent ACL canonical and
        // inactive instead of encoding an asserted active-low reset.
        let mut action = unused_action;
        action.active_low = false;
        input_value_for_port(action)
    };
    config.push(acl_port);

    let ground_index = if let Some(ground_last_index) = platform.port_map.ground_last_index {
        // Indexes start at 1
        ground_last_index + 1
    } else {
        // Unset
        0
    };

    config.push(ground_index);

    // Spacer pixels for input mapping
    for _ in 0..4 {
        config.push(0);
    }

    // Reserved space. Existing voice-only V2 packages retain their original
    // header. Packages with an HMC ROM or player-two ownership metadata use
    // the GNWX extension directory; a P2-only package has zero descriptors.
    let mut feature_flags = 0;
    if has_voice {
        feature_flags |= FEATURE_VOICE;
    }
    if has_hmc {
        feature_flags |= FEATURE_HMC;
    }
    if has_player_two {
        feature_flags |= FEATURE_PLAYER_TWO;
    }
    if has_crt_assets {
        feature_flags |= FEATURE_CRT_IMAGE | FEATURE_CRT_MASK;
    }
    if has_default_sound_on {
        feature_flags |= FEATURE_DEFAULT_SOUND_ON;
    }
    if has_directory {
        feature_flags |= FEATURE_DIRECTORY;
    }
    config.push(feature_flags);
    for _ in 1..0xC9 {
        config.push(0);
    }

    if has_directory {
        config[DIRECTORY_MAGIC_OFFSET..DIRECTORY_MAGIC_OFFSET + 4]
            .copy_from_slice(b"GNWX");
        config[DIRECTORY_REVISION_OFFSET] = DIRECTORY_REVISION;
        config[DIRECTORY_DESCRIPTOR_SIZE_OFFSET] = DIRECTORY_DESCRIPTOR_SIZE as u8;
        config[PLAYER_TWO_MASK_OFFSET..PLAYER_TWO_MASK_OFFSET + PLAYER_TWO_MASK_SIZE]
            .copy_from_slice(&player_two_mask);

        let mut descriptor_index = 0;
        if has_voice {
            write_payload_descriptor(
                &mut config,
                descriptor_index,
                DESCRIPTOR_KIND_VOICE,
                DESCRIPTOR_ENCODING_RAW,
                DESCRIPTOR_VARIANT_VOICE_V1,
                VOICE_PACKAGE_OFFSET,
                VOICE_BANK_SIZE,
                0,
                0,
            )?;
            descriptor_index += 1;
        }
        if has_hmc {
            write_payload_descriptor(
                &mut config,
                descriptor_index,
                DESCRIPTOR_KIND_HMC,
                DESCRIPTOR_ENCODING_RAW,
                DESCRIPTOR_VARIANT_HA1152,
                HMC_PACKAGE_OFFSET,
                HMC_ROM_SIZE,
                0,
                0,
            )?;
            descriptor_index += 1;
        }
        if let Some(crt_mask_used_length) = crt_mask_used_length {
            write_payload_descriptor(
                &mut config,
                descriptor_index,
                DESCRIPTOR_KIND_CRT_IMAGE,
                DESCRIPTOR_ENCODING_RAW,
                DESCRIPTOR_VARIANT_COMPONENT_PAIRED_RGB,
                CRT_IMAGE_PACKAGE_OFFSET,
                CRT_IMAGE_SIZE,
                CRT_IMAGE_WIDTH,
                CRT_IMAGE_HEIGHT,
            )?;
            descriptor_index += 1;
            write_payload_descriptor(
                &mut config,
                descriptor_index,
                DESCRIPTOR_KIND_CRT_MASK,
                DESCRIPTOR_ENCODING_RLE40,
                DESCRIPTOR_VARIANT_MASK_RLE_V1,
                CRT_MASK_PACKAGE_OFFSET,
                crt_mask_used_length,
                CRT_IMAGE_WIDTH,
                CRT_IMAGE_HEIGHT,
            )?;
            descriptor_index += 1;
        }
        config[DIRECTORY_DESCRIPTOR_COUNT_OFFSET] = descriptor_index as u8;
    }

    // Vergen emits VERGEN_IDEMPOTENT_OUTPUT when Git is unavailable and can
    // still report success. Only a hexadecimal Git ID is package provenance;
    // normalize every sentinel or malformed value to an explicit fallback.
    config.extend_from_slice(&generator_stamp(option_env!("VERGEN_GIT_SHA")));

    Ok(config)
}

fn write_payload_descriptor(
    config: &mut [u8],
    index: usize,
    kind: u8,
    encoding: u8,
    variant: u8,
    offset: usize,
    length: usize,
    width: usize,
    height: usize,
) -> Result<(), String> {
    let start = DIRECTORY_DESCRIPTORS_OFFSET + index * DIRECTORY_DESCRIPTOR_SIZE;
    let end = start + DIRECTORY_DESCRIPTOR_SIZE;
    if end > 0xF9 {
        return Err("Too many package extension descriptors".to_string());
    }
    let offset = u32::try_from(offset)
        .map_err(|_| "Package descriptor offset does not fit in 32 bits".to_string())?;
    let length = u32::try_from(length)
        .map_err(|_| "Package descriptor length does not fit in 32 bits".to_string())?;
    let width = u16::try_from(width)
        .map_err(|_| "Package descriptor width does not fit in 16 bits".to_string())?;
    let height = u16::try_from(height)
        .map_err(|_| "Package descriptor height does not fit in 16 bits".to_string())?;

    config[start] = kind;
    config[start + 1] = encoding;
    config[start + 2] = variant;
    config[start + 3] = 0;
    config[start + 4..start + 8].copy_from_slice(&offset.to_le_bytes());
    config[start + 8..start + 12].copy_from_slice(&length.to_le_bytes());
    config[start + 12..start + 14].copy_from_slice(&width.to_le_bytes());
    config[start + 14..end].copy_from_slice(&height.to_le_bytes());
    Ok(())
}

fn input_value_for_port(action: NamedAction) -> u8 {
    let mut input: u8 = match action.action {
        Action::JoyUp => 0,
        Action::JoyDown => 1,
        Action::JoyLeft => 2,
        Action::JoyRight => 3,
        Action::Button1 => 4,
        Action::Button2 => 5,
        Action::Button3 => 6,
        Action::Button4 => 7,
        Action::Button5 => 8,
        Action::Button6 => 9,
        Action::Button7 => 10,
        Action::Button8 => 11,
        Action::Select => 12,
        Action::Start1 => 13,
        Action::Start2 => 14,
        Action::Service1 => 15,
        Action::Service2 => 16,
        Action::Service3 => 15,
        // Keep 16 as Service2/Alarm for existing packages. Service4 needs its
        // own ID so titles such as Treasure Island can expose Minute and Alarm
        // as independent physical controls.
        Action::Service4 => 33,
        Action::LeftJoyUp => 17,
        Action::LeftJoyDown => 18,
        Action::LeftJoyLeft => 19,
        Action::LeftJoyRight => 20,
        Action::RightJoyUp => 21,
        Action::RightJoyDown => 22,
        Action::RightJoyLeft => 23,
        Action::RightJoyRight => 24,
        Action::VolumeDown => 25,
        Action::PowerOn => 26,
        Action::PowerOff => 27,
        Action::Keypad => 28,
        Action::Custom => 29,
        Action::CustomUpDown => 30,
        Action::CustomButtonHour => 31,
        Action::Dial => 32,
        Action::Unused => 0x7F,
    };

    if action.active_low {
        input |= 0x80;
    }

    input
}

const BYTES_PER_ENTRY: usize = 5;
const AVERAGE_ENTRIES_PER_ROW: usize = 52;
const TOTAL_BYTE_LENGTH: usize = BYTES_PER_ENTRY * AVERAGE_ENTRIES_PER_ROW * HEIGHT;

#[derive(Debug)]
pub(crate) struct EncodedMask {
    pub bytes: Vec<u8>,
    pub used_length: usize,
    pub run_count: usize,
}

fn insert_mask_entry_bytes(
    output: &mut Vec<u8>,
    byte_index: &mut usize,
    capacity: usize,
    id: u16,
    length: usize,
    start_x: usize,
    y: usize,
) -> Result<(), String> {
    if *byte_index + BYTES_PER_ENTRY > capacity {
        return Err(format!(
            "Mask needs more than {} entries ({} bytes)",
            capacity / BYTES_PER_ENTRY,
            capacity
        ));
    }

    output[*byte_index..*byte_index + BYTES_PER_ENTRY]
        .clone_from_slice(&entry_to_bytes(id, length, start_x, y));

    *byte_index += BYTES_PER_ENTRY;

    Ok(())
}

pub(crate) fn build_mask_map(pixels_to_mask_id: &[Option<u16>]) -> Result<Vec<u8>, String> {
    Ok(build_mask_map_for_dimensions(
        pixels_to_mask_id,
        WIDTH,
        HEIGHT,
        TOTAL_BYTE_LENGTH,
        false,
    )?
    .bytes)
}

pub(crate) fn build_crt_mask_map(
    pixels_to_mask_id: &[Option<u16>],
) -> Result<EncodedMask, String> {
    build_mask_map_for_dimensions(
        pixels_to_mask_id,
        CRT_IMAGE_WIDTH,
        CRT_IMAGE_HEIGHT,
        CRT_MASK_CAPACITY,
        true,
    )
}

fn build_mask_map_for_dimensions(
    pixels_to_mask_id: &[Option<u16>],
    width: usize,
    height: usize,
    capacity: usize,
    append_terminator: bool,
) -> Result<EncodedMask, String> {
    let expected_pixels = width
        .checked_mul(height)
        .ok_or_else(|| "Mask dimensions overflowed the host address space".to_string())?;
    if pixels_to_mask_id.len() != expected_pixels {
        return Err(format!(
            "Mask contains {} pixels, expected {expected_pixels} for {width}x{height}",
            pixels_to_mask_id.len()
        ));
    }
    if capacity % BYTES_PER_ENTRY != 0 {
        return Err("Mask capacity is not aligned to 40-bit entries".to_string());
    }

    let mut output: Vec<u8> = vec![0; capacity];
    let mut byte_index = 0;

    for y in 0..height {
        let mut current_id: Option<u16> = None;
        let mut start_x: usize = 0;
        let mut length: usize = 0;

        for x in 0..width {
            if let Some(id) = pixels_to_mask_id[y * width + x] {
                // Has id
                match current_id {
                    Some(stored_id) => {
                        if stored_id == id {
                            // Increment current entry
                            length += 1;
                        } else {
                            // This is a new segment, finish the old segment and start a new one
                            insert_mask_entry_bytes(
                                &mut output,
                                &mut byte_index,
                                capacity,
                                stored_id,
                                length,
                                start_x,
                                y,
                            )?;

                            current_id = Some(id);
                            start_x = x;
                            length = 1;
                        }
                    }
                    None => {
                        // Begin entry
                        current_id = Some(id);
                        start_x = x;
                        length = 1;
                    }
                }
            } else {
                // No id
                if let Some(id) = current_id {
                    // End entry
                    current_id = None;

                    insert_mask_entry_bytes(
                        &mut output,
                        &mut byte_index,
                        capacity,
                        id,
                        length,
                        start_x,
                        y,
                    )?;
                }
            }
        }

        if let Some(id) = current_id {
            // Clean up straggler at the end of a row
            insert_mask_entry_bytes(
                &mut output,
                &mut byte_index,
                capacity,
                id,
                length,
                start_x,
                y,
            )?;
        }
    }

    let run_count = byte_index / BYTES_PER_ENTRY;
    if append_terminator {
        if byte_index + BYTES_PER_ENTRY > capacity {
            return Err(format!(
                "CRT mask uses {run_count} runs and has no room for its required zero terminator (capacity: {} runs)",
                capacity / BYTES_PER_ENTRY
            ));
        }
        // The buffer was initialized to zero, so advancing over one entry
        // makes that all-zero 40-bit value an explicit terminator.
        byte_index += BYTES_PER_ENTRY;
    }

    Ok(EncodedMask {
        bytes: output,
        used_length: byte_index,
        run_count,
    })
}

fn entry_to_bytes(id: u16, length: usize, start_x: usize, y: usize) -> Vec<u8> {
    let mut data: bitvec::vec::BitVec<u8> = bitvec![u8, Lsb0; 0; 5*8];

    data[0..10].store::<u16>(id);
    data[10..20].store::<u16>(start_x as u16);
    data[20..30].store::<u16>(y as u16);
    data[30..40].store::<u16>(length as u16);

    data.into()
}

#[cfg(test)]
mod tests {
    use super::{
        build_config, build_crt_mask_map, encode, generator_stamp, is_valid_generator_stamp,
        CRT_IMAGE_HEIGHT, CRT_IMAGE_PACKAGE_OFFSET, CRT_IMAGE_SIZE, CRT_IMAGE_WIDTH,
        CRT_MASK_CAPACITY, CRT_MASK_PACKAGE_OFFSET, CRT_PACKAGE_SIZE, FEATURE_CRT_IMAGE,
        FEATURE_CRT_MASK, FEATURE_DEFAULT_SOUND_ON, FEATURE_DIRECTORY, FEATURE_HMC,
        FEATURE_PLAYER_TWO, FEATURE_VOICE, HMC_PACKAGE_OFFSET, HMC_ROM_SIZE,
        PLAYER_TWO_MASK_OFFSET, VOICE_BANK_SIZE, VOICE_PACKAGE_OFFSET,
    };
    use crate::manifest::PlatformSpecification;
    use crate::{HEIGHT, WIDTH};
    use sha1::{Digest, Sha1};
    use std::fs;

    fn hmc_platform() -> PlatformSpecification {
        serde_json::from_str(
            r#"{
                "device":{"cpu":"sm530","screen":{"type":"single","width":1176,"height":1080}},
                "portMap":{"ports":[]},
                "metadata":{"year":"1993","company":"Nelsonic","name":"Star Fox (Nelsonic)"},
                "rom":{"rom":"643.program","melody":"643.melody","melodyHash":"32056467f796cb2e3c9f05c364419e7935fd1361","romHash":"165cefeba9abc8725e55d15fdc218b07857d4cfe"},
                "auxRom":{"type":"ha1152","region":"sfx","rom":"ha1152_001a","size":128,"romHash":"5dfb15eee3c57bbca80f485f68442e5f7c6bc5e4"}
            }"#,
        )
        .expect("could not parse HA1152 fixture")
    }

    fn player_two_platform() -> PlatformSpecification {
        serde_json::from_str(
            r#"{
                "device":{"cpu":"sm511","screen":{"type":"single","width":1920,"height":524}},
                "portMap":{"ports":[
                    {"type":"s","index":0,"bitmap":[null,null,{"action":"button1","activeLow":false,"player":2},null]},
                    {"type":"s","index":2,"bitmap":[null,null,{"action":"joyDown","activeLow":false,"player":2},{"action":"joyUp","activeLow":false,"player":2}]},
                    {"type":"s","index":4,"bitmap":[null,null,{"action":"joyRight","activeLow":false,"player":2},{"action":"joyLeft","activeLow":false,"player":2}]}
                ]},
                "metadata":{"year":"1984","company":"Nintendo","name":"Micro Vs. Test"},
                "rom":{"rom":"program","melody":"melody","melodyHash":"0000000000000000000000000000000000000000","romHash":"0000000000000000000000000000000000000000"}
            }"#,
        )
        .expect("could not parse player-two fixture")
    }

    fn default_sound_platform() -> PlatformSpecification {
        serde_json::from_str(
            r#"{
                "device":{"cpu":"sm530","screen":{"type":"single","width":1203,"height":1080}},
                "portMap":{"ports":[]},
                "metadata":{"year":"1990","company":"Nelsonic","name":"Super Mario Bros. 3 (Nelsonic)"},
                "rom":{"rom":"633.program","melody":"633.melody","melodyHash":"94b5865fc669b7f6487845647866c06f4f581f63","romHash":"1271d15e6168d73852f8ade9ade4d5f3b1838bf5"},
                "defaultSoundOn":true
            }"#,
        )
        .expect("could not parse startup-sound fixture")
    }

    #[test]
    fn generator_stamp_accepts_git_sha_and_rejects_vergen_sentinel() {
        assert_eq!(
            generator_stamp(Some("2600FF1D4C95")),
            *b"2600ff1",
            "Git IDs should be truncated and normalized"
        );
        assert_eq!(
            generator_stamp(Some("VERGEN_IDEMPOTENT_OUTPUT")),
            *b"unknown",
            "the vergen sentinel must never enter a package"
        );
        assert_eq!(generator_stamp(Some("123456g")), *b"unknown");
        assert_eq!(generator_stamp(None), *b"unknown");

        assert!(is_valid_generator_stamp(b"2600ff1"));
        assert!(is_valid_generator_stamp(b"unknown"));
        assert!(!is_valid_generator_stamp(b"VERGEN_"));
    }

    #[test]
    fn hmc_config_uses_the_exact_extended_v2_descriptor() {
        let platform = hmc_platform();
        let config = build_config(&platform, false, true, None).unwrap();

        assert_eq!(config.len(), 0x100);
        assert_eq!(config[0], 2);
        assert_eq!(config[0x30], FEATURE_HMC | FEATURE_DIRECTORY);
        assert_eq!(&config[0x31..0x35], b"GNWX");
        assert_eq!(&config[0x35..0x38], &[1, 16, 1]);
        assert_eq!(
            &config[0x40..0x50],
            &[
                0x02,
                0x01,
                0x01,
                0x00,
                (HMC_PACKAGE_OFFSET & 0xff) as u8,
                ((HMC_PACKAGE_OFFSET >> 8) & 0xff) as u8,
                ((HMC_PACKAGE_OFFSET >> 16) & 0xff) as u8,
                ((HMC_PACKAGE_OFFSET >> 24) & 0xff) as u8,
                HMC_ROM_SIZE as u8,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
            ]
        );
        assert!(config[0x50..0xf9].iter().all(|byte| *byte == 0));
        assert_eq!(
            &config[PLAYER_TWO_MASK_OFFSET..PLAYER_TWO_MASK_OFFSET + 5],
            &[0_u8; 5]
        );
    }

    #[test]
    fn player_two_config_uses_a_descriptorless_gnwx_directory() {
        let platform = player_two_platform();
        let config = build_config(&platform, false, false, None).unwrap();

        assert_eq!(config.len(), 0x100);
        assert_eq!(config[0], 2);
        assert_eq!(config[0x30], FEATURE_PLAYER_TWO | FEATURE_DIRECTORY);
        assert_eq!(&config[0x31..0x35], b"GNWX");
        assert_eq!(&config[0x35..0x38], &[1, 16, 0]);
        assert_eq!(
            &config[PLAYER_TWO_MASK_OFFSET..PLAYER_TWO_MASK_OFFSET + 5],
            &[0x04, 0x0c, 0x0c, 0x00, 0x00]
        );
        assert!(config[0x3d..0xf9].iter().all(|byte| *byte == 0));
    }

    #[test]
    fn default_sound_on_is_a_descriptorless_v2_feature() {
        let config = build_config(&default_sound_platform(), false, false, None).unwrap();

        assert_eq!(config.len(), 0x100);
        assert_eq!(config[0], 2);
        assert_eq!(config[0x30], FEATURE_DEFAULT_SOUND_ON);
        assert!(config[0x31..0xf9].iter().all(|byte| *byte == 0));
    }

    #[test]
    fn player_two_metadata_coexists_with_both_crt_descriptors() {
        let config = build_config(&player_two_platform(), false, false, Some(5)).unwrap();

        assert_eq!(
            config[0x30],
            FEATURE_PLAYER_TWO | FEATURE_CRT_IMAGE | FEATURE_CRT_MASK | FEATURE_DIRECTORY
        );
        assert_eq!(&config[0x35..0x38], &[1, 16, 2]);
        assert_eq!(
            &config[PLAYER_TWO_MASK_OFFSET..PLAYER_TWO_MASK_OFFSET + 5],
            &[0x04, 0x0c, 0x0c, 0x00, 0x00]
        );
        assert_eq!(&config[0x40..0x44], &[0x10, 0x01, 0x01, 0x00]);
        assert_eq!(&config[0x50..0x54], &[0x11, 0x02, 0x01, 0x00]);
    }

    #[test]
    fn voice_only_header_remains_legacy_v2_and_combined_directory_is_ordered() {
        let platform = hmc_platform();
        let voice_only = build_config(&platform, true, false, None).unwrap();
        assert_eq!(voice_only[0], 2);
        assert_eq!(voice_only[0x30], FEATURE_VOICE);
        assert!(voice_only[0x31..0xf9].iter().all(|byte| *byte == 0));

        let combined = build_config(&platform, true, true, None).unwrap();
        assert_eq!(
            combined[0x30],
            FEATURE_VOICE | FEATURE_HMC | FEATURE_DIRECTORY
        );
        assert_eq!(combined[0x37], 2);
        assert_eq!(&combined[0x40..0x44], &[0x01, 0x01, 0x01, 0x00]);
        assert_eq!(
            u32::from_le_bytes(combined[0x44..0x48].try_into().unwrap()) as usize,
            VOICE_PACKAGE_OFFSET
        );
        assert_eq!(
            u32::from_le_bytes(combined[0x48..0x4c].try_into().unwrap()) as usize,
            VOICE_BANK_SIZE
        );
        assert_eq!(&combined[0x50..0x54], &[0x02, 0x01, 0x01, 0x00]);
    }

    #[test]
    fn dual_resolution_config_uses_exact_crt_descriptors_after_hmc() {
        let config = build_config(&hmc_platform(), false, true, Some(0x1234)).unwrap();

        assert_eq!(CRT_IMAGE_PACKAGE_OFFSET, 0x336500);
        assert_eq!(CRT_IMAGE_SIZE, 0x7e900);
        assert_eq!(CRT_MASK_PACKAGE_OFFSET, 0x433700);
        assert_eq!(CRT_PACKAGE_SIZE, 0x442ac0);
        assert_eq!(
            config[0x30],
            FEATURE_HMC | FEATURE_CRT_IMAGE | FEATURE_CRT_MASK | FEATURE_DIRECTORY
        );
        assert_eq!(&config[0x35..0x38], &[1, 16, 3]);
        assert_eq!(&config[0x40..0x44], &[0x02, 0x01, 0x01, 0x00]);
        assert_eq!(&config[0x50..0x54], &[0x10, 0x01, 0x01, 0x00]);
        assert_eq!(
            u32::from_le_bytes(config[0x54..0x58].try_into().unwrap()) as usize,
            CRT_IMAGE_PACKAGE_OFFSET
        );
        assert_eq!(
            u32::from_le_bytes(config[0x58..0x5c].try_into().unwrap()) as usize,
            CRT_IMAGE_SIZE
        );
        assert_eq!(&config[0x5c..0x60], &[0x68, 0x01, 0xf0, 0x00]);
        assert_eq!(&config[0x60..0x64], &[0x11, 0x02, 0x01, 0x00]);
        assert_eq!(
            u32::from_le_bytes(config[0x64..0x68].try_into().unwrap()) as usize,
            CRT_MASK_PACKAGE_OFFSET
        );
        assert_eq!(
            u32::from_le_bytes(config[0x68..0x6c].try_into().unwrap()) as usize,
            0x1234
        );
        assert_eq!(&config[0x6c..0x70], &[0x68, 0x01, 0xf0, 0x00]);
    }

    #[test]
    fn crt_mask_length_includes_one_explicit_terminator_and_fixed_padding() {
        let mut pixels = vec![None; CRT_IMAGE_WIDTH * CRT_IMAGE_HEIGHT];
        pixels[3] = Some(7);
        pixels[4] = Some(7);
        pixels[CRT_IMAGE_WIDTH + 10] = Some(9);

        let encoded = build_crt_mask_map(&pixels).unwrap();
        assert_eq!(encoded.bytes.len(), CRT_MASK_CAPACITY);
        assert_eq!(encoded.run_count, 2);
        assert_eq!(encoded.used_length, 15);
        assert!(encoded.bytes[10..].iter().all(|byte| *byte == 0));
    }

    #[test]
    fn full_package_keeps_legacy_payloads_and_places_raw_hmc_bytes_exactly() {
        let temp = std::env::temp_dir().join(format!(
            "gnw-hmc-package-test-{}",
            std::process::id()
        ));
        if temp.exists() {
            fs::remove_dir_all(&temp).unwrap();
        }
        let assets = temp.join("assets");
        let output = temp.join("output");
        fs::create_dir_all(&assets).unwrap();
        fs::create_dir_all(&output).unwrap();

        let program = vec![0x5a_u8; 0x800];
        let melody = vec![0xa5_u8; 0x100];
        let hmc: Vec<u8> = (0..HMC_ROM_SIZE).map(|value| value as u8).collect();
        fs::write(assets.join("program"), &program).unwrap();
        fs::write(assets.join("melody"), &melody).unwrap();
        fs::write(assets.join("hmc"), &hmc).unwrap();

        let platform: PlatformSpecification = serde_json::from_str(&format!(
            r#"{{
                "device":{{"cpu":"sm530","screen":{{"type":"single","width":1176,"height":1080}}}},
                "portMap":{{"ports":[]}},
                "metadata":{{"year":"1993","company":"Test","name":"HMC Package Test"}},
                "rom":{{"rom":"program","melody":"melody","melodyHash":"{}","romHash":"{}"}},
                "auxRom":{{"type":"ha1152","region":"sfx","rom":"hmc","size":128,"romHash":"{}"}}
            }}"#,
            hex::encode(Sha1::digest(&melody)),
            hex::encode(Sha1::digest(&program)),
            hex::encode(Sha1::digest(&hmc)),
        ))
        .unwrap();

        let rgba = vec![0_u8; WIDTH * HEIGHT * 4];
        let pixels = vec![None; WIDTH * HEIGHT];
        let crt_rgba = vec![0_u8; CRT_IMAGE_WIDTH * CRT_IMAGE_HEIGHT * 4];
        let crt_pixels = vec![None; CRT_IMAGE_WIDTH * CRT_IMAGE_HEIGHT];
        let package_path = encode(
            &rgba,
            &rgba,
            &pixels,
            &crt_rgba,
            &crt_rgba,
            &crt_pixels,
            &platform,
            &assets,
            &output,
        )
        .unwrap();
        let package = fs::read(package_path).unwrap();

        assert_eq!(package.len(), CRT_PACKAGE_SIZE);
        assert_eq!(&package[0x325240..0x325a40], program.as_slice());
        assert!(package[0x325a40..0x326240].iter().all(|byte| *byte == 0));
        assert_eq!(&package[0x326240..0x326340], melody.as_slice());
        assert!(package[0x326340..HMC_PACKAGE_OFFSET]
            .iter()
            .all(|byte| *byte == 0));
        assert_eq!(
            &package[HMC_PACKAGE_OFFSET..HMC_PACKAGE_OFFSET + HMC_ROM_SIZE],
            hmc.as_slice()
        );
        assert!(package[HMC_PACKAGE_OFFSET + HMC_ROM_SIZE..CRT_IMAGE_PACKAGE_OFFSET]
            .iter()
            .all(|byte| *byte == 0));
        let crt_image_end = CRT_IMAGE_PACKAGE_OFFSET + CRT_IMAGE_SIZE;
        assert!(package[CRT_IMAGE_PACKAGE_OFFSET..crt_image_end]
            .iter()
            .all(|byte| *byte == 0));
        assert!(package[crt_image_end..CRT_MASK_PACKAGE_OFFSET]
            .iter()
            .all(|byte| *byte == 0));
        assert!(package[CRT_MASK_PACKAGE_OFFSET..].iter().all(|byte| *byte == 0));

        fs::remove_dir_all(temp).unwrap();
    }
}
