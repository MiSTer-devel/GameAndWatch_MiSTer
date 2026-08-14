use std::{fs, path::{Path, PathBuf}};

use crate::manifest::VoiceDefinition;

pub const VOICE_BANK_SIZE: usize = 0x1_0000;
pub const VOICE_PAYLOAD_OFFSET: usize = 0x100;
pub const VOICE_SAMPLE_RATE: u32 = 8_000;

const DIRECTORY_OFFSET: usize = 0x10;
const DIRECTORY_ENTRY_SIZE: usize = 4;
const DIRECTORY_ENTRIES: usize = 32;
const INDEX_SHIFT: [i8; 8] = [-1, -1, -1, -1, 2, 4, 6, 8];
const STEP_TABLE: [i32; 49] = [
    16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66, 73, 80,
    88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337,
    371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166, 1282,
    1411, 1552,
];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct DecoderState {
    signal: i32,
    step: i32,
}

impl DecoderState {
    fn reset() -> Self {
        Self { signal: -2, step: 0 }
    }

    fn decode(&mut self, nibble: u8) -> i16 {
        let step_value = STEP_TABLE[self.step as usize];
        let mut difference = step_value / 8;
        if nibble & 1 != 0 {
            difference += step_value / 4;
        }
        if nibble & 2 != 0 {
            difference += step_value / 2;
        }
        if nibble & 4 != 0 {
            difference += step_value;
        }
        if nibble & 8 != 0 {
            difference = -difference;
        }

        self.signal = (self.signal + difference).clamp(-2048, 2047);
        self.step = (self.step + i32::from(INDEX_SHIFT[(nibble & 7) as usize])).clamp(0, 48);
        self.signal as i16
    }
}

#[derive(Debug)]
struct WaveData {
    sample_rate: u32,
    samples: Vec<i16>,
}

pub fn build_voice_bank(
    definition: &VoiceDefinition,
    asset_dir: &Path,
) -> Result<Vec<u8>, String> {
    if definition.commands.len() > DIRECTORY_ENTRIES - 1 {
        return Err(format!(
            "Sample set {:?} defines {} commands; the package supports at most {}",
            definition.sample_set,
            definition.commands.len(),
            DIRECTORY_ENTRIES - 1
        ));
    }

    let mut bank = vec![0_u8; VOICE_BANK_SIZE];
    bank[0..4].copy_from_slice(b"GWAU");
    bank[4] = 1; // Bank version.
    bank[5] = 1; // OKI ADPCM4, high nibble first.
    bank[6..8].copy_from_slice(&(VOICE_SAMPLE_RATE as u16).to_le_bytes());
    bank[8] = DIRECTORY_ENTRIES as u8;

    let mut payload_cursor = VOICE_PAYLOAD_OFFSET;
    for (command_index, sample_name) in definition.commands.iter().enumerate() {
        let command = command_index + 1;
        let Some(sample_name) = sample_name else {
            continue;
        };

        let wav_path = find_case_insensitive(asset_dir, &format!("{sample_name}.wav"))?
            .ok_or_else(|| {
                format!(
                    "Could not find sample {:?} for set {:?} in {asset_dir:?}",
                    format!("{sample_name}.wav"),
                    definition.sample_set
                )
            })?;
        let wave = parse_wave(&fs::read(&wav_path).map_err(|err| {
            format!("Could not read voice sample {wav_path:?}: {err}")
        })?)?;
        let resampled = resample_bandlimited(&wave.samples, wave.sample_rate, VOICE_SAMPLE_RATE);
        if resampled.is_empty() {
            return Err(format!("Voice sample {wav_path:?} contains no PCM frames"));
        }
        if resampled.len() > u16::MAX as usize {
            return Err(format!(
                "Voice sample {wav_path:?} is too long after resampling ({} frames)",
                resampled.len()
            ));
        }

        let encoded = encode_oki(&resampled);
        if payload_cursor + encoded.len() > VOICE_BANK_SIZE {
            return Err(format!(
                "Sample set {:?} exceeds the 64 KiB voice bank while adding {sample_name:?}",
                definition.sample_set
            ));
        }

        let relative_start = payload_cursor - VOICE_PAYLOAD_OFFSET;
        let directory_entry = DIRECTORY_OFFSET + command * DIRECTORY_ENTRY_SIZE;
        bank[directory_entry..directory_entry + 2]
            .copy_from_slice(&(relative_start as u16).to_le_bytes());
        bank[directory_entry + 2..directory_entry + 4]
            .copy_from_slice(&(resampled.len() as u16).to_le_bytes());
        bank[payload_cursor..payload_cursor + encoded.len()].copy_from_slice(&encoded);
        payload_cursor += encoded.len();
    }

    let payload_size = payload_cursor - VOICE_PAYLOAD_OFFSET;
    bank[10..12].copy_from_slice(&(payload_size as u16).to_le_bytes());
    Ok(bank)
}

pub fn validate_voice_bank(bank: &[u8]) -> Result<(), String> {
    if bank.len() != VOICE_BANK_SIZE {
        return Err(format!(
            "Voice bank is {} bytes, expected {VOICE_BANK_SIZE}",
            bank.len()
        ));
    }
    if &bank[0..4] != b"GWAU"
        || bank[4] != 1
        || bank[5] != 1
        || u16::from_le_bytes([bank[6], bank[7]]) != VOICE_SAMPLE_RATE as u16
        || bank[8] != DIRECTORY_ENTRIES as u8
    {
        return Err("Voice bank header is invalid".to_string());
    }

    let payload_size = usize::from(u16::from_le_bytes([bank[10], bank[11]]));
    if VOICE_PAYLOAD_OFFSET + payload_size > bank.len() {
        return Err("Voice bank payload extends past the fixed bank".to_string());
    }

    for command in 0..DIRECTORY_ENTRIES {
        let entry = DIRECTORY_OFFSET + command * DIRECTORY_ENTRY_SIZE;
        let start = usize::from(u16::from_le_bytes([bank[entry], bank[entry + 1]]));
        let nibble_count =
            usize::from(u16::from_le_bytes([bank[entry + 2], bank[entry + 3]]));
        if command == 0 && (start != 0 || nibble_count != 0) {
            return Err("Voice command zero must remain the stop/empty slot".to_string());
        }
        if nibble_count != 0 && start + nibble_count.div_ceil(2) > payload_size {
            return Err(format!("Voice command {command} extends past the payload"));
        }
    }
    Ok(())
}

pub fn inspect_voice_bank(bank: &[u8]) -> Result<Vec<(u8, u16, u16)>, String> {
    validate_voice_bank(bank)?;
    let mut entries = Vec::new();
    for command in 1..DIRECTORY_ENTRIES {
        let entry = DIRECTORY_OFFSET + command * DIRECTORY_ENTRY_SIZE;
        let start = u16::from_le_bytes([bank[entry], bank[entry + 1]]);
        let count = u16::from_le_bytes([bank[entry + 2], bank[entry + 3]]);
        if count != 0 {
            entries.push((command as u8, start, count));
        }
    }
    Ok(entries)
}

fn find_case_insensitive(root: &Path, file_name: &str) -> Result<Option<PathBuf>, String> {
    let target = file_name.to_ascii_lowercase();
    let entries = fs::read_dir(root)
        .map_err(|err| format!("Could not inspect extracted assets at {root:?}: {err}"))?;
    for entry in entries {
        let entry = entry.map_err(|err| format!("Could not inspect an asset in {root:?}: {err}"))?;
        let path = entry.path();
        if path.is_dir() {
            if let Some(found) = find_case_insensitive(&path, file_name)? {
                return Ok(Some(found));
            }
        } else if entry.file_name().to_string_lossy().to_ascii_lowercase() == target {
            return Ok(Some(path));
        }
    }
    Ok(None)
}

fn parse_wave(bytes: &[u8]) -> Result<WaveData, String> {
    if bytes.len() < 12 || &bytes[0..4] != b"RIFF" || &bytes[8..12] != b"WAVE" {
        return Err("Voice sample is not a RIFF/WAVE file".to_string());
    }

    let mut format: Option<(u16, u32, u16, u16)> = None;
    let mut pcm_bytes: Vec<u8> = Vec::new();
    let mut cursor = 12_usize;
    while cursor + 8 <= bytes.len() {
        let chunk_id = &bytes[cursor..cursor + 4];
        let chunk_len = u32::from_le_bytes(bytes[cursor + 4..cursor + 8].try_into().unwrap()) as usize;
        let data_start = cursor + 8;
        let data_end = data_start
            .checked_add(chunk_len)
            .ok_or_else(|| "WAVE chunk length overflow".to_string())?;
        if data_end > bytes.len() {
            return Err("WAVE chunk extends past the end of the file".to_string());
        }

        if chunk_id == b"fmt " {
            if chunk_len < 16 {
                return Err("WAVE fmt chunk is shorter than 16 bytes".to_string());
            }
            let encoding = u16::from_le_bytes(bytes[data_start..data_start + 2].try_into().unwrap());
            let channels = u16::from_le_bytes(bytes[data_start + 2..data_start + 4].try_into().unwrap());
            let sample_rate =
                u32::from_le_bytes(bytes[data_start + 4..data_start + 8].try_into().unwrap());
            let block_align =
                u16::from_le_bytes(bytes[data_start + 12..data_start + 14].try_into().unwrap());
            let bits =
                u16::from_le_bytes(bytes[data_start + 14..data_start + 16].try_into().unwrap());
            if encoding != 1 {
                return Err(format!("Unsupported WAVE encoding {encoding}; PCM is required"));
            }
            if channels == 0 || sample_rate == 0 {
                return Err("WAVE has zero channels or sample rate".to_string());
            }
            format = Some((channels, sample_rate, bits, block_align));
        } else if chunk_id == b"data" {
            pcm_bytes.extend_from_slice(&bytes[data_start..data_end]);
        }

        cursor = data_end + (chunk_len & 1);
    }

    let (channels, sample_rate, bits, block_align) =
        format.ok_or_else(|| "WAVE is missing a fmt chunk".to_string())?;
    if pcm_bytes.is_empty() {
        return Err("WAVE is missing PCM data".to_string());
    }
    let bytes_per_sample = usize::from(bits.div_ceil(8));
    let expected_align = usize::from(channels) * bytes_per_sample;
    if !matches!(bits, 8 | 16 | 24) || usize::from(block_align) < expected_align {
        return Err(format!(
            "Unsupported WAVE layout: {channels} channels, {bits} bits, block align {block_align}"
        ));
    }

    let frame_size = usize::from(block_align);
    let mut samples = Vec::with_capacity(pcm_bytes.len() / frame_size);
    for frame in pcm_bytes.chunks_exact(frame_size) {
        let mut sum = 0_i64;
        for channel in 0..usize::from(channels) {
            let offset = channel * bytes_per_sample;
            let value = match bits {
                8 => (i32::from(frame[offset]) - 128) << 8,
                16 => i32::from(i16::from_le_bytes([frame[offset], frame[offset + 1]])),
                24 => {
                    let raw = i32::from(frame[offset])
                        | (i32::from(frame[offset + 1]) << 8)
                        | (i32::from(frame[offset + 2]) << 16);
                    ((raw << 8) >> 8) >> 8
                }
                _ => unreachable!(),
            };
            sum += i64::from(value);
        }
        samples.push((sum / i64::from(channels)).clamp(-32768, 32767) as i16);
    }

    Ok(WaveData { sample_rate, samples })
}

fn resample_bandlimited(input: &[i16], source_rate: u32, target_rate: u32) -> Vec<i16> {
    if input.is_empty() || source_rate == 0 || target_rate == 0 {
        return Vec::new();
    }
    if source_rate == target_rate {
        return input.to_vec();
    }

    let output_len = ((input.len() as u64 * u64::from(target_rate)
        + u64::from(source_rate) / 2)
        / u64::from(source_rate)) as usize;
    let ratio = f64::from(source_rate) / f64::from(target_rate);
    let cutoff = 0.475_f64 * (f64::from(target_rate) / f64::from(source_rate)).min(1.0);
    const RADIUS: isize = 24;
    let mut output = Vec::with_capacity(output_len);

    for output_index in 0..output_len {
        let source_position = output_index as f64 * ratio;
        let center = source_position.floor() as isize;
        let mut sum = 0.0_f64;
        let mut weight_sum = 0.0_f64;
        for tap in (center - RADIUS + 1)..=(center + RADIUS) {
            if tap < 0 || tap >= input.len() as isize {
                continue;
            }
            let distance = source_position - tap as f64;
            let normalized = distance / RADIUS as f64;
            if normalized.abs() >= 1.0 {
                continue;
            }
            let sinc_argument = 2.0 * std::f64::consts::PI * cutoff * distance;
            let sinc = if sinc_argument.abs() < 1.0e-12 {
                2.0 * cutoff
            } else {
                2.0 * cutoff * sinc_argument.sin() / sinc_argument
            };
            // Blackman window bounds the FIR and suppresses downsampling aliases.
            let window = 0.42
                + 0.5 * (std::f64::consts::PI * normalized).cos()
                + 0.08 * (2.0 * std::f64::consts::PI * normalized).cos();
            let weight = sinc * window;
            sum += f64::from(input[tap as usize]) * weight;
            weight_sum += weight;
        }
        let sample = if weight_sum.abs() < 1.0e-12 { 0.0 } else { sum / weight_sum };
        output.push(sample.round().clamp(-32768.0, 32767.0) as i16);
    }
    output
}

fn encode_oki(samples: &[i16]) -> Vec<u8> {
    let mut state = DecoderState::reset();
    let mut output = Vec::with_capacity(samples.len().div_ceil(2));
    let mut pending_high = None;

    for &sample in samples {
        let target = i32::from(sample) >> 4;
        let mut best_nibble = 0_u8;
        let mut best_state = state;
        let mut best_error = i32::MAX;
        for nibble in 0_u8..16 {
            let mut candidate = state;
            let decoded = i32::from(candidate.decode(nibble));
            let error = (decoded - target).abs();
            if error < best_error {
                best_error = error;
                best_nibble = nibble;
                best_state = candidate;
            }
        }
        state = best_state;

        if let Some(high) = pending_high.take() {
            output.push((high << 4) | best_nibble);
        } else {
            pending_high = Some(best_nibble);
        }
    }
    if let Some(high) = pending_high {
        output.push(high << 4);
    }
    output
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_pcm_wave(samples: &[i16], sample_rate: u32, with_junk: bool) -> Vec<u8> {
        let mut body = Vec::new();
        body.extend_from_slice(b"fmt ");
        body.extend_from_slice(&16_u32.to_le_bytes());
        body.extend_from_slice(&1_u16.to_le_bytes());
        body.extend_from_slice(&1_u16.to_le_bytes());
        body.extend_from_slice(&sample_rate.to_le_bytes());
        body.extend_from_slice(&(sample_rate * 2).to_le_bytes());
        body.extend_from_slice(&2_u16.to_le_bytes());
        body.extend_from_slice(&16_u16.to_le_bytes());
        if with_junk {
            body.extend_from_slice(b"JUNK");
            body.extend_from_slice(&3_u32.to_le_bytes());
            body.extend_from_slice(&[1, 2, 3, 0]);
        }
        body.extend_from_slice(b"data");
        body.extend_from_slice(&((samples.len() * 2) as u32).to_le_bytes());
        for sample in samples {
            body.extend_from_slice(&sample.to_le_bytes());
        }
        let mut wave = b"RIFF".to_vec();
        wave.extend_from_slice(&((body.len() + 4) as u32).to_le_bytes());
        wave.extend_from_slice(b"WAVE");
        wave.extend_from_slice(&body);
        wave
    }

    #[test]
    fn parses_pcm_with_unknown_chunks() {
        let wave = parse_wave(&make_pcm_wave(&[-32768, 0, 32767], 44_100, true)).unwrap();
        assert_eq!(wave.sample_rate, 44_100);
        assert_eq!(wave.samples, [-32768, 0, 32767]);
    }

    #[test]
    fn resampler_preserves_duration() {
        let input = vec![1000_i16; 44_100];
        let output = resample_bandlimited(&input, 44_100, 8_000);
        assert_eq!(output.len(), 8_000);
        assert!(output[100..7_900].iter().all(|sample| (*sample - 1000).abs() <= 1));
    }

    #[test]
    fn encoder_is_high_nibble_first_and_tracks_pcm() {
        let input: Vec<i16> = (0..512)
            .map(|index| (((index as f64 / 24.0).sin()) * 20_000.0) as i16)
            .collect();
        let encoded = encode_oki(&input);
        assert_eq!(encoded.len(), 256);

        let mut state = DecoderState::reset();
        let mut decoded = Vec::new();
        for byte in encoded {
            decoded.push(i32::from(state.decode(byte >> 4)) << 4);
            decoded.push(i32::from(state.decode(byte & 0x0f)) << 4);
        }
        let mean_error = decoded
            .iter()
            .zip(input.iter())
            .map(|(actual, expected)| (actual - i32::from(*expected)).abs() as u64)
            .sum::<u64>()
            / input.len() as u64;
        assert!(mean_error < 2_000, "mean ADPCM error was {mean_error}");
    }

    #[test]
    fn validator_rejects_bad_directory_bounds() {
        let mut bank = vec![0_u8; VOICE_BANK_SIZE];
        bank[0..4].copy_from_slice(b"GWAU");
        bank[4] = 1;
        bank[5] = 1;
        bank[6..8].copy_from_slice(&(VOICE_SAMPLE_RATE as u16).to_le_bytes());
        bank[8] = DIRECTORY_ENTRIES as u8;
        bank[10..12].copy_from_slice(&1_u16.to_le_bytes());
        bank[DIRECTORY_OFFSET + 4..DIRECTORY_OFFSET + 6]
            .copy_from_slice(&1_u16.to_le_bytes());
        bank[DIRECTORY_OFFSET + 6..DIRECTORY_OFFSET + 8]
            .copy_from_slice(&4_u16.to_le_bytes());
        assert!(validate_voice_bank(&bank).is_err());
    }
}
