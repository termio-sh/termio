//! `termio update` against a release served from a directory: the same
//! layout `downloads.termio.sh` serves (`linux/latest`, then
//! `v<version>/linux/SHA256SUMS` and one file per binary and CPU), read with
//! `file://` URLs. The new `termio` is a script that records the handoff it is
//! asked for, so no daemon is involved.
#![cfg(target_os = "linux")]

use sha2::{Digest, Sha256};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::atomic::{AtomicUsize, Ordering};

const CLIENT: &str = env!("CARGO_BIN_EXE_termio");

static DIRECTORIES: AtomicUsize = AtomicUsize::new(0);

struct TestDir(PathBuf);

impl TestDir {
    fn new() -> TestDir {
        let nonce = DIRECTORIES.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!("tupd-{}-{nonce}", std::process::id()));
        std::fs::create_dir_all(&path).expect("create test directory");
        TestDir(path)
    }
}

impl Drop for TestDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn target() -> &'static str {
    match std::env::consts::ARCH {
        "x86_64" => "x86_64-unknown-linux-musl",
        "aarch64" => "aarch64-unknown-linux-musl",
        other => panic!("no release triple for {other}"),
    }
}

fn hex(bytes: &[u8]) -> String {
    Sha256::digest(bytes).iter().map(|byte| format!("{byte:02x}")).collect()
}

/// A release `version` under `root`. Each binary is a script that names
/// itself; the client also writes `handoff` beside itself when asked to hand
/// off. `corrupt` lists the files whose SHA256SUMS line is wrong.
fn publish(root: &Path, version: &str, corrupt: &[&str]) {
    std::fs::create_dir_all(root.join("linux")).unwrap();
    std::fs::write(root.join("linux/latest"), format!("{version}\n")).unwrap();
    let release = root.join(format!("v{version}/linux"));
    std::fs::create_dir_all(&release).unwrap();
    let mut sums = String::new();
    for name in ["termiod", "termio", "termio-tailnet"] {
        let body = if name == "termio" {
            format!(
                "#!/bin/sh\n# {name} {version}\n\
                 [ \"$1 $2\" = \"server handoff\" ] && echo handed-off > \"$(dirname \"$0\")/handoff\"\n\
                 exit 0\n"
            )
        } else {
            format!("#!/bin/sh\n# {name} {version}\n")
        };
        let file = format!("{name}-{}", target());
        std::fs::write(release.join(&file), &body).unwrap();
        let hash = if corrupt.contains(&name) {
            hex(b"something else")
        } else {
            hex(body.as_bytes())
        };
        sums.push_str(&format!("{hash}  {file}\n"));
    }
    std::fs::write(release.join("SHA256SUMS"), sums).unwrap();
}

/// An installed build in `bin`: three files that are not the release's.
fn install_old(bin: &Path) {
    std::fs::create_dir_all(bin).unwrap();
    for name in ["termiod", "termio", "termio-tailnet"] {
        let path = bin.join(name);
        std::fs::write(&path, format!("#!/bin/sh\n# {name} old\n")).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
}

fn update(test: &TestDir, arguments: &[&str]) -> Output {
    Command::new(CLIENT)
        .arg("update")
        .args(arguments)
        .env("TERMIO_DOWNLOAD_BASE", format!("file://{}", test.0.join("release").display()))
        .env("TERMIOD_BIN", test.0.join("bin/termiod"))
        .env("HOME", &test.0)
        .env_remove("TERMIOD_SOCK")
        .output()
        .expect("run termio update")
}

fn read(path: PathBuf) -> String {
    std::fs::read_to_string(path).unwrap()
}

#[test]
fn an_update_installs_every_binary_and_hands_off() {
    let test = TestDir::new();
    publish(&test.0.join("release"), "99.0.0", &[]);
    install_old(&test.0.join("bin"));

    let output = update(&test, &[]);
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));

    for name in ["termiod", "termio", "termio-tailnet"] {
        let installed = read(test.0.join("bin").join(name));
        assert!(installed.contains(&format!("{name} 99.0.0")), "{name}: {installed}");
        let mode = std::fs::metadata(test.0.join("bin").join(name)).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o755, "{name} is executable");
    }
    assert_eq!(read(test.0.join("bin/handoff")).trim(), "handed-off");
    let left: Vec<_> = std::fs::read_dir(test.0.join("bin"))
        .unwrap()
        .filter_map(|entry| entry.ok())
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .filter(|name| name.starts_with('.'))
        .collect();
    assert!(left.is_empty(), "staging is removed: {left:?}");
}

#[test]
fn one_bad_checksum_installs_nothing() {
    let test = TestDir::new();
    publish(&test.0.join("release"), "99.0.0", &["termio-tailnet"]);
    install_old(&test.0.join("bin"));

    let output = update(&test, &[]);
    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("failed its checksum"));
    for name in ["termiod", "termio", "termio-tailnet"] {
        assert!(read(test.0.join("bin").join(name)).contains("old"), "{name} is untouched");
    }
    assert!(!test.0.join("bin/handoff").exists());
}

#[test]
fn a_release_older_than_this_build_is_not_installed() {
    let test = TestDir::new();
    publish(&test.0.join("release"), "0.0.0", &[]);
    install_old(&test.0.join("bin"));

    let output = update(&test, &[]);
    // A checkout reports 0.0.0+<commits>, which is the same release as 0.0.0.
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    assert!(String::from_utf8_lossy(&output.stdout).contains("is the newest release"));
    assert!(read(test.0.join("bin/termiod")).contains("old"));
}

#[test]
fn check_changes_nothing() {
    let test = TestDir::new();
    publish(&test.0.join("release"), "99.0.0", &[]);
    install_old(&test.0.join("bin"));

    let output = update(&test, &["--check"]);
    assert!(output.status.success());
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("newest:       99.0.0"), "{stdout}");
    assert!(read(test.0.join("bin/termiod")).contains("old"));
}
