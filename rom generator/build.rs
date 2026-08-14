use std::{error::Error, process::Command};
use vergen::EmitBuilder;

fn git_stdout(args: &[&str]) -> Option<String> {
    let output = Command::new("git").args(args).output().ok()?;
    if !output.status.success() {
        return None;
    }

    Some(String::from_utf8(output.stdout).ok()?.trim().to_owned())
}

fn git_sha_from_cli() -> Option<String> {
    let sha = git_stdout(&["rev-parse", "--verify", "HEAD"])?;
    if sha.len() < 7 || !sha.as_bytes().iter().all(u8::is_ascii_hexdigit) {
        return None;
    }

    Some(sha[..7].to_ascii_lowercase())
}

fn main() -> Result<(), Box<dyn Error>> {
    // Stamp generated ROMs with the source commit when this is built from a git checkout.
    // Prefer a direct command so GNU-hosted Windows builds do not depend on vergen finding
    // a separate POSIX shell. Release archives may not have .git metadata, so retain
    // vergen's normal fallback path. The encoder validates either result and writes the
    // explicit seven-byte `unknown` fallback for sentinels or malformed values.
    if let Some(sha) = git_sha_from_cli() {
        println!("cargo:rustc-env=VERGEN_GIT_SHA={sha}");
        println!("cargo:rerun-if-changed=../.git/HEAD");
        if let Some(reference) = git_stdout(&["symbolic-ref", "-q", "HEAD"])
            .filter(|reference| reference.starts_with("refs/") && !reference.contains(".."))
        {
            println!("cargo:rerun-if-changed=../.git/{reference}");
        }
        println!("cargo:rerun-if-changed=../.git/packed-refs");
        return Ok(());
    }

    if EmitBuilder::builder().git_sha(true).emit().is_err() {
        println!("cargo:rustc-env=VERGEN_GIT_SHA=unknown");
    }

    Ok(())
}
