use std::{
    fs::{self, File},
    path::Path,
};

use colored::Colorize;
use zip::ZipArchive;

///
/// Extract artwork and ROM assets
///
pub fn get_assets(
    platform_name: &str,
    parent_name: Option<&str>,
    owning_rom_name: &Option<String>,
    artwork_dir: &Path,
    artwork_subdirectory: Option<&str>,
    rom_dir: &Path,
    sample_dir: Option<&Path>,
    sample_set: Option<&str>,
    temp_dir: &Path,
) -> Result<(), String> {
    if temp_dir.exists() {
        fs::remove_dir_all(temp_dir)
            .map_err(|err| format!("Could not clear temporary asset directory {temp_dir:?}: {err}"))?;
    }
    fs::create_dir_all(temp_dir)
        .map_err(|err| format!("Could not create temporary asset directory {temp_dir:?}: {err}"))?;

    let standard_artwork_path = artwork_dir
        .join("foo")
        .with_file_name(platform_name)
        .with_extension("zip");
    let artwork_path = artwork_subdirectory
        .map(|subdirectory| {
            artwork_dir
                .join(subdirectory)
                .join("foo")
                .with_file_name(platform_name)
                .with_extension("zip")
        })
        .unwrap_or_else(|| standard_artwork_path.clone());

    let roms_path = rom_dir
        .join("foo")
        .with_file_name(platform_name)
        .with_extension("zip");

    let mut has_parent_rom = false;
    let mut parent_rom_error = None;

    if let Some(owning_rom_name) = owning_rom_name {
        let owning_roms_path = rom_dir
            .join("foo")
            .with_file_name(owning_rom_name)
            .with_extension("zip");

        match extract_path(&owning_roms_path, &temp_dir, "parent ROM") {
            Ok(()) => has_parent_rom = true,
            Err(message) => {
                // A non-merged child set is self-contained, so absence of its
                // MAME parent must not prevent us from trying the child's ZIP.
                // Retain the error in case neither source is available.
                parent_rom_error = Some(format!(
                    "Could not load optional parent ROM {}\n{message}",
                    owning_rom_name.cyan()
                ));
            }
        }
    }

    let artwork_result = extract_path(&artwork_path, temp_dir, "artwork").or_else(|override_error| {
        if artwork_path == standard_artwork_path {
            Err(override_error)
        } else {
            extract_path(&standard_artwork_path, temp_dir, "standard artwork").map_err(
                |standard_error| format!(
                    "{override_error}\nPreferred artwork fallback also failed:\n{standard_error}"
                ),
            )
        }
    });
    if let Err(artwork_error) = artwork_result {
        let fallback_name = parent_name.or(owning_rom_name.as_deref());
        if let Some(fallback_name) = fallback_name.filter(|name| *name != platform_name) {
            let fallback_path = artwork_dir
                .join("foo")
                .with_file_name(fallback_name)
                .with_extension("zip");
            extract_path(&fallback_path, temp_dir, "parent artwork").map_err(|fallback_error| {
                format!(
                    "{artwork_error}\nDevice artwork fallback {fallback_name:?} also failed:\n{fallback_error}"
                )
            })?;
        } else {
            return Err(artwork_error);
        }
    }

    match extract_path(&roms_path, &temp_dir, "ROM") {
        Ok(_) => {}
        Err(err) => {
            // Split/merged collections may obtain all required bytes from the
            // parent. Conversely, a non-merged child ZIP is sufficient even
            // when that parent is not installed.
            if !has_parent_rom {
                return Err(match parent_rom_error {
                    Some(parent_error) => format!("{parent_error}\n{err}"),
                    None => err,
                });
            }
        }
    };

    if let Some(sample_set) = sample_set {
        let sample_dir = sample_dir.ok_or_else(|| {
            format!("Device requires sample set {sample_set:?}, but no sample path was provided")
        })?;
        let sample_path = sample_dir
            .join("foo")
            .with_file_name(sample_set)
            .with_extension("zip");
        extract_path(&sample_path, temp_dir, "sample")?;
    }

    Ok(())
}

fn extract_path(file_path: &Path, outdir: &Path, data_type: &str) -> Result<(), String> {
    guard!(let Ok(zip_file) = File::open(file_path) else {
        let name = if let Some(name) = file_path.file_name() {
            format!(" ({name:?})")
        } else {
            "".to_string()
        };

        return Err(format!("Could not open expected {data_type} file{name} at {file_path:?}"));
    });

    guard!(let Ok(mut archive) = ZipArchive::new(zip_file) else {
        return Err(format!("Could not open zip at {file_path:?}"));
    });

    if archive.extract(outdir).is_err() {
        return Err(format!("Could not extract zip at {file_path:?}"));
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use zip::{write::FileOptions, CompressionMethod, ZipWriter};

    fn write_zip(path: &Path, file_name: &str, contents: &[u8]) {
        let file = File::create(path).unwrap();
        let mut zip = ZipWriter::new(file);
        let options = FileOptions::default().compression_method(CompressionMethod::Stored);
        zip.start_file(file_name, options).unwrap();
        zip.write_all(contents).unwrap();
        zip.finish().unwrap();
    }

    #[test]
    fn non_merged_child_rom_does_not_require_parent_zip() {
        let temp = std::env::temp_dir().join(format!(
            "gnw-non-merged-assets-test-{}",
            std::process::id()
        ));
        if temp.exists() {
            fs::remove_dir_all(&temp).unwrap();
        }
        let artwork = temp.join("artwork");
        let roms = temp.join("roms");
        let extracted = temp.join("extracted");
        fs::create_dir_all(&artwork).unwrap();
        fs::create_dir_all(&roms).unwrap();

        write_zip(&artwork.join("child.zip"), "default.lay", b"layout");
        write_zip(&roms.join("child.zip"), "program", b"child rom");

        let parent = Some("parent".to_string());
        get_assets(
            "child",
            Some("parent"),
            &parent,
            &artwork,
            None,
            &roms,
            None,
            None,
            &extracted,
        )
        .expect("a self-contained non-merged child set should be sufficient");

        assert_eq!(fs::read(extracted.join("default.lay")).unwrap(), b"layout");
        assert_eq!(fs::read(extracted.join("program")).unwrap(), b"child rom");
        fs::remove_dir_all(temp).unwrap();
    }
}
