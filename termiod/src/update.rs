//! `termio update`: this machine's Termio server, from the newest release.
//!
//! The same download `install.sh` does, in the same order: read the version,
//! fetch the release's `SHA256SUMS`, fetch each binary for this CPU and check
//! it, and only once every file matches, rename them over the installed ones.
//! The running daemon then becomes the new build in place, so its sessions
//! carry on. Unlike the installer it leaves systemd and Tailscale alone: an
//! update changes the binaries and nothing else.
//!
//! The download is the system's `curl` (or `wget`), the way the installer
//! fetches it; no TLS is linked into termio.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use anyhow::{bail, Context, Result};
use clap::Args;
use sha2::{Digest, Sha256};

use crate::lifecycle::{self, Version};

const DEFAULT_BASE: &str = "https://downloads.termio.sh";

/// What a release ships for Linux. `termio-tailnet` is missing from releases
/// before built-in Tailscale, and only that one may be.
const BINARIES: [&str; 3] = ["termiod", "termio", "termio-tailnet"];

#[derive(Args)]
pub struct UpdateArgs {
    /// Install this release instead of the newest, older or newer.
    #[arg(long, value_name = "X.Y.Z")]
    pub version: Option<String>,

    /// Print this machine's version and the newest release, and change nothing.
    #[arg(long, conflicts_with = "version")]
    pub check: bool,
}

pub async fn run(args: UpdateArgs) -> Result<()> {
    if cfg!(target_os = "macos") {
        bail!("on a Mac, termio updates with the app: termio > Check for Updates…");
    }
    let target = target_triple()?;
    let base = std::env::var("TERMIO_DOWNLOAD_BASE")
        .ok()
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| DEFAULT_BASE.to_string());
    let base = base.trim_end_matches('/');
    let current = release_of(lifecycle::BUILD_VERSION);

    let wanted = match &args.version {
        Some(version) => version.trim().trim_start_matches('v').to_string(),
        None => {
            let latest = fetch_text(&format!("{base}/linux/latest"))
                .await
                .context("couldn't read the newest version")?;
            latest.trim().to_string()
        }
    };
    let Some(wanted_version) = Version::parse(&wanted) else {
        bail!("{wanted:?} is not a version like 0.75.0");
    };
    let newer = Version::parse(current).is_none_or(|have| wanted_version > have);

    if args.check {
        println!("this machine: {current}");
        println!("newest:       {wanted}");
        if newer {
            println!("Run termio update to install {wanted}.");
        } else {
            println!("Up to date.");
        }
        return Ok(());
    }
    if args.version.is_none() && !newer {
        println!("termio {current} is the newest release.");
        return Ok(());
    }

    let directory = install_directory()?;
    let release = format!("{base}/v{wanted}/linux");
    println!("Downloading termio {wanted} for {target}");

    // Beside the binaries, so the final rename never crosses a filesystem.
    let staging = Staging::create(&directory)?;
    let sums = fetch_text(&format!("{release}/SHA256SUMS"))
        .await
        .with_context(|| format!("termio {wanted} has no Linux build at {release}"))?;
    let sums = parse_sums(&sums);
    let mut fetched = Vec::new();
    for name in BINARIES {
        let file = format!("{name}-{target}");
        let Some(want) = sums.get(&file) else {
            if name == "termio-tailnet" {
                continue;
            }
            bail!("SHA256SUMS lists no {file}");
        };
        let path = staging.path.join(&file);
        fetch_file(&format!("{release}/{file}"), &path)
            .await
            .with_context(|| format!("couldn't download {release}/{file}"))?;
        let got = digest(&path)?;
        if &got != want {
            bail!("{file} failed its checksum (got {got}, want {want})");
        }
        make_executable(&path)?;
        fetched.push((path, directory.join(name)));
    }
    println!("    checksums match");

    // Renamed into place, never written over: a running daemon keeps the file
    // it was started from until the handoff moves it onto the new one.
    for (from, to) in &fetched {
        std::fs::rename(from, to)
            .with_context(|| format!("installing {}", to.display()))?;
    }
    println!("Installed termio {wanted} in {}", directory.display());

    // The new build's own handoff, as the installer runs it: the client that
    // asks is the one that knows the build it is asking for.
    // Named outright, and `TERMIOD_BIN` dropped, so the daemon handed off to
    // is the file just installed and never one an override points at.
    let client = directory.join("termio");
    let daemon = directory.join("termiod");
    let status = tokio::process::Command::new(&client)
        .args(["server", "handoff", "--binary"])
        .arg(&daemon)
        .env_remove("TERMIOD_BIN")
        .status()
        .await
        .with_context(|| format!("running {} server handoff", client.display()))?;
    if !status.success() {
        println!("The running daemon couldn't take the new build in place.");
        println!("It picks it up at its next start: termio server stop, once its sessions are done.");
    }
    Ok(())
}

/// Where this `termio` really lives, with every symlink resolved: the
/// directory the installer put all three binaries in. Only a `termiod` beside
/// it qualifies. `paired_daemon`'s other answers (`TERMIOD_BIN`, argv0's
/// directory, a daemon found on PATH) name a daemon to talk to, not the files
/// this command replaces, and following them updated a different directory
/// than the one the command ran from, or replaced a symlink with a file.
fn install_directory() -> Result<PathBuf> {
    let client = std::env::current_exe()
        .and_then(|path| path.canonicalize())
        .context("resolving this termio")?;
    let directory = client
        .parent()
        .with_context(|| format!("{} has no directory", client.display()))?
        .to_path_buf();
    if !directory.join("termiod").is_file() {
        bail!(
            "no termiod beside {}; install with: curl -fsSL https://www.termio.sh/install | sh",
            client.display()
        );
    }
    Ok(directory)
}

/// The release triple of this CPU. termio ships for Linux on two.
fn target_triple() -> Result<&'static str> {
    match std::env::consts::ARCH {
        "x86_64" => Ok("x86_64-unknown-linux-musl"),
        "aarch64" => Ok("aarch64-unknown-linux-musl"),
        other => bail!("no build for {other}; termio ships x86_64 and aarch64"),
    }
}

/// `0.74.0+1600` → `0.74.0`. Releases are named by version alone, and the
/// build number only orders two builds of one version.
fn release_of(stamp: &str) -> &str {
    stamp.split_once('+').map_or(stamp, |(release, _)| release)
}

/// `<sha256>  <file>` per line, as `sha256sum` writes it; a `*` before the
/// name marks binary mode and is not part of it.
fn parse_sums(text: &str) -> HashMap<String, String> {
    text.lines()
        .filter_map(|line| {
            let mut words = line.split_whitespace();
            let hash = words.next()?;
            let name = words.next()?.trim_start_matches('*');
            Some((name.to_string(), hash.to_ascii_lowercase()))
        })
        .collect()
}

fn digest(path: &Path) -> Result<String> {
    let mut file =
        std::fs::File::open(path).with_context(|| format!("opening {}", path.display()))?;
    let mut hasher = Sha256::new();
    std::io::copy(&mut file, &mut hasher)?;
    Ok(hasher
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect())
}

fn make_executable(path: &Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755))
        .with_context(|| format!("making {} executable", path.display()))
}

async fn fetch_text(url: &str) -> Result<String> {
    let output = downloader(url, None).output().await?;
    if !output.status.success() {
        bail!("{}", String::from_utf8_lossy(&output.stderr).trim());
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

async fn fetch_file(url: &str, path: &Path) -> Result<()> {
    let output = downloader(url, Some(path)).output().await?;
    if !output.status.success() {
        bail!("{}", String::from_utf8_lossy(&output.stderr).trim());
    }
    Ok(())
}

/// `curl`, or `wget` where a minimal image has only that. Writes to `path`,
/// or to stdout without one.
fn downloader(url: &str, path: Option<&Path>) -> tokio::process::Command {
    let output = path.map_or_else(|| "-".to_string(), |path| path.display().to_string());
    if has_command("curl") {
        let mut command = tokio::process::Command::new("curl");
        command.args(["-fsSL", "-o", &output, url]);
        command
    } else {
        let mut command = tokio::process::Command::new("wget");
        command.args(["-q", "-O", &output, url]);
        command
    }
}

fn has_command(name: &str) -> bool {
    std::env::var_os("PATH").is_some_and(|path| {
        std::env::split_paths(&path).any(|directory| directory.join(name).is_file())
    })
}

/// A private directory beside the install, removed however the update ends.
struct Staging {
    path: PathBuf,
}

impl Staging {
    fn create(directory: &Path) -> Result<Staging> {
        let path = directory.join(format!(".termio-update-{}", std::process::id()));
        std::fs::create_dir_all(&path)
            .with_context(|| format!("creating {}", path.display()))?;
        Ok(Staging { path })
    }
}

impl Drop for Staging {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.path);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sums_read_both_sha256sum_modes() {
        let sums = parse_sums(
            "ABC  termiod-x86_64-unknown-linux-musl\n\
             def *termio-x86_64-unknown-linux-musl\n\n",
        );
        assert_eq!(sums["termiod-x86_64-unknown-linux-musl"], "abc");
        assert_eq!(sums["termio-x86_64-unknown-linux-musl"], "def");
        assert_eq!(sums.len(), 2);
    }

    #[test]
    fn a_build_stamp_names_its_release() {
        assert_eq!(release_of("0.74.0+1600"), "0.74.0");
        assert_eq!(release_of("0.74.0"), "0.74.0");
    }
}
