//! Which channel the `termio` client drives, resolved from its own name.
//!
//! The shell client carried three build-time rewritten variables
//! (`SUPPORT_DIR_NAME`, `BUNDLE_ID`, `VERSION`); this derives the same
//! bindings from argv[0] instead: the dev bundle installs the binary as
//! `termio-dev`, which selects the `.dev` bundle id, the `termio-dev`
//! support directory, and the dev daemon socket. One binary, no sed.
//!
//! Inside a session the plain `termio` name is ambiguous: an agent running in
//! the dev app reaches for `termio` like any other, and the name alone sent it
//! to the release app, which does not know the session it was called from. So
//! the app stamps every session with its own channel (`TERMIO_SESSION_CHANNEL`),
//! and the plain name defers to it. An explicit `termio-<channel>` still wins.
//!
//! An inherited `TERMIO_CHANNEL` is deliberately not consulted: the shell
//! client pinned `TERMIO_CHANNEL="$CHANNEL"` on every daemon exec so a stale
//! value could not cross channels, and this keeps that rule. The one runtime
//! override is `TERMIOD_SOCK`, which pins the daemon socket outright
//! (`paths::socket_path` honors it first) — that is how a hook firing inside
//! a channel-pinned session reaches the daemon that owns it. `termio
//! version` prints which of the two answered, so a surprising socket names
//! its own cause.

/// The bindings the shell client's three rewritten variables carried.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Channel {
    /// `release`, `dev`, or a custom probe channel name.
    pub name: String,
    /// The Mac app this client drives (`open -b`, `lsappinfo`).
    pub bundle_id: String,
    /// Directory name under `~/Library/Application Support` holding the
    /// app's control socket, support copies, and device registry.
    pub support_dir_name: String,
}

/// Which rung decided where the daemon socket is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Provenance {
    /// `TERMIOD_SOCK` names the socket directly.
    ExplicitSocket,
    /// Derived from the binary's own name (`termio` / `termio-<channel>`).
    ProgramName,
    /// The plain `termio` name, inside a session the app stamped with its channel.
    SessionChannel,
}

impl Channel {
    fn release() -> Channel {
        Channel {
            name: "release".to_string(),
            bundle_id: "sh.termio.app".to_string(),
            support_dir_name: "termio".to_string(),
        }
    }

    /// Same validation rule as `paths::channel_suffix`: a channel name is a
    /// path component, so anything that isn't lowercase alphanumeric-or-dash
    /// falls back to the release channel instead of opening a stray
    /// directory.
    pub(crate) fn named(candidate: &str) -> Channel {
        let name = candidate.trim().to_lowercase();
        if name.is_empty() || name == "release" {
            return Channel::release();
        }
        if !name
            .chars()
            .all(|character| character.is_alphanumeric() || character == '-')
        {
            return Channel::release();
        }
        Channel {
            bundle_id: format!("sh.termio.app.{name}"),
            support_dir_name: format!("termio-{name}"),
            name,
        }
    }

    /// `termio` → release; `termio-dev` → dev; `termio-<name>` → `<name>`;
    /// anything else → release. Takes the bare program name, not a path.
    pub fn from_program_name(program: &str) -> Channel {
        match program.strip_prefix("termio-") {
            Some(rest) => Channel::named(rest),
            None => Channel::release(),
        }
    }

    /// The channel an invocation drives: the program name's, except that the
    /// plain `termio` name inside a session defers to the channel the app
    /// stamped on it (`session_channel`), so a call from a dev session reaches
    /// the dev app. Returns whether the session decided it.
    pub fn for_invocation(program: &str, session_channel: Option<&str>) -> (Channel, bool) {
        let named = Channel::from_program_name(program);
        if program != "termio" {
            return (named, false);
        }
        match session_channel.map(str::trim).filter(|value| !value.is_empty()) {
            Some(value) => (Channel::named(value), true),
            None => (named, false),
        }
    }

    /// The deep-link scheme this channel's app claims (`termio` /
    /// `termio-dev`), mirroring `AppChannel.urlScheme`.
    pub fn url_scheme(&self) -> String {
        if self.name == "release" {
            "termio".to_string()
        } else {
            format!("termio-{}", self.name)
        }
    }
}

fn program_name() -> String {
    std::env::args()
        .next()
        .as_deref()
        .map(std::path::Path::new)
        .and_then(|path| path.file_name())
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| "termio".to_string())
}

/// Whether `channel` came from the stamp on the session this runs in, not
/// from the name the binary was called by. A stamp outlives the app that
/// wrote it: a session a probe build started keeps the probe's channel after
/// that build is gone.
pub fn named_by_session(channel: &Channel) -> bool {
    program_name() == "termio" && channel.name != "release"
}

fn explicit_socket() -> bool {
    std::env::var_os("TERMIOD_SOCK").is_some_and(|value| !value.is_empty())
}

/// Resolve the channel and pin it for everything downstream: sets
/// `TERMIO_CHANNEL` in this process's environment so `paths::*` and every
/// exec'd daemon derive the same socket, overwriting any inherited value —
/// the same pin the shell client applied on every daemon exec.
pub fn resolve() -> (Channel, Provenance) {
    let session_channel = std::env::var("TERMIO_SESSION_CHANNEL").ok();
    let (channel, from_session) = Channel::for_invocation(&program_name(), session_channel.as_deref());
    std::env::set_var("TERMIO_CHANNEL", &channel.name);
    let provenance = if explicit_socket() {
        Provenance::ExplicitSocket
    } else if from_session {
        Provenance::SessionChannel
    } else {
        Provenance::ProgramName
    };
    (channel, provenance)
}

/// The shell client's `locate_termiod()`, same rungs in the same order: the
/// explicit `TERMIOD_BIN` override; the daemon beside this binary, but only
/// when this binary itself runs out of a bundle's `Contents/Resources` (a
/// checkout's `target/debug/termio` must not quietly prefer its sibling over
/// the live app); the running app's bundle via `lsappinfo`, which only
/// answers for a live process so it can never name a stale bundle; then the
/// standalone install locations. Every rung requires an executable file,
/// like the shell's `-x` and `command -v`.
pub fn daemon_binary(channel: &Channel) -> Option<std::path::PathBuf> {
    use std::path::{Path, PathBuf};
    if let Some(explicit) = std::env::var_os("TERMIOD_BIN") {
        let path = PathBuf::from(explicit);
        if executable(&path) {
            return Some(path);
        }
    }
    if let Some(resolved) = std::env::current_exe()
        .ok()
        .and_then(|own| own.canonicalize().ok())
    {
        if let Some(parent) = resolved.parent() {
            if parent.ends_with("Contents/Resources") {
                let candidate = parent.join("termiod");
                if executable(&candidate) {
                    return Some(candidate);
                }
            }
        }
    }
    if cfg!(target_os = "macos") {
        if let Ok(info) = std::process::Command::new("lsappinfo")
            .args(["info", "-only", "bundlepath", &channel.bundle_id])
            .output()
        {
            let stdout = String::from_utf8_lossy(&info.stdout);
            if let Some(bundle) = stdout
                .lines()
                .find_map(|line| line.strip_prefix("\"LSBundlePath\"=\""))
                .and_then(|rest| rest.strip_suffix('"'))
            {
                let candidate = Path::new(bundle).join("Contents/Resources/termiod");
                if executable(&candidate) {
                    return Some(candidate);
                }
            }
        }
    }
    if let Some(home) = std::env::var_os("HOME") {
        let candidate = Path::new(&home).join(".local/bin/termiod");
        if executable(&candidate) {
            return Some(candidate);
        }
    }
    let path_variable = std::env::var_os("PATH")?;
    std::env::split_paths(&path_variable)
        .map(|directory| directory.join("termiod"))
        .find(|candidate| executable(candidate))
}

fn executable(path: &std::path::Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    path.is_file()
        && std::fs::metadata(path)
            .map(|metadata| metadata.permissions().mode() & 0o111 != 0)
            .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_plain_name_is_the_release_channel() {
        let channel = Channel::from_program_name("termio");
        assert_eq!(channel.name, "release");
        assert_eq!(channel.bundle_id, "sh.termio.app");
        assert_eq!(channel.support_dir_name, "termio");
    }

    #[test]
    fn a_dev_suffix_selects_the_dev_bundle_and_support_dir() {
        let channel = Channel::from_program_name("termio-dev");
        assert_eq!(channel.name, "dev");
        assert_eq!(channel.bundle_id, "sh.termio.app.dev");
        assert_eq!(channel.support_dir_name, "termio-dev");
    }

    #[test]
    fn a_custom_suffix_is_its_own_probe_channel() {
        let channel = Channel::from_program_name("termio-smoke2");
        assert_eq!(channel.name, "smoke2");
        assert_eq!(channel.support_dir_name, "termio-smoke2");
    }

    #[test]
    fn an_explicit_release_suffix_collapses_to_release() {
        assert_eq!(Channel::from_program_name("termio-release"), Channel::release());
    }

    #[test]
    fn an_invalid_suffix_falls_back_to_release_like_paths_does() {
        assert_eq!(Channel::from_program_name("termio-../evil"), Channel::release());
        assert_eq!(Channel::from_program_name("termio-a_b"), Channel::release());
    }

    #[test]
    fn the_plain_name_inside_a_dev_session_drives_the_dev_app() {
        let (channel, from_session) = Channel::for_invocation("termio", Some("dev"));
        assert_eq!(channel.name, "dev");
        assert!(from_session);
    }

    #[test]
    fn an_explicit_channel_name_outranks_the_session() {
        let (channel, from_session) = Channel::for_invocation("termio-dev", Some("release"));
        assert_eq!(channel.name, "dev");
        assert!(!from_session);
    }

    #[test]
    fn outside_a_session_the_plain_name_is_release() {
        assert_eq!(Channel::for_invocation("termio", None).0, Channel::release());
        assert_eq!(Channel::for_invocation("termio", Some("  ")).0, Channel::release());
    }

    #[test]
    fn an_invalid_session_channel_falls_back_to_release() {
        assert_eq!(Channel::for_invocation("termio", Some("../evil")).0, Channel::release());
    }

    #[test]
    fn an_unrelated_program_name_is_release() {
        assert_eq!(Channel::from_program_name("termiofoo"), Channel::release());
        assert_eq!(Channel::from_program_name("cargo"), Channel::release());
    }
}
