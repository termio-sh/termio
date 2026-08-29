//! Keeping the daemon alive across logins and crashes (§6).
//!
//! Making `termiod` the only PTY owner makes it a single point of failure. An
//! in-process PTY at least died *with* the app; a daemon that is not supervised
//! dies on its own and takes every session with it — and "the session lives on
//! the box, not in the connection" stops being true the first time the user
//! logs out.
//!
//! macOS answers this with a **launchd user agent**: `RunAtLoad` starts it at
//! login, `KeepAlive` restarts it if it dies. Linux answers with a **systemd
//! `--user` unit**: `WantedBy=default.target` starts it at login,
//! `Restart=on-failure` brings it back after a crash, and `loginctl
//! enable-linger` keeps the user's manager — and so the daemon — alive across
//! logouts. Without linger a user daemon is killed at logout, so sessions would
//! vanish silently between SSH connections; install asks for linger and says
//! so when it cannot get it. The same three verbs do the same three things on
//! both, from the same clap surface.
//!
//! Installing is never automatic. It writes into the user's `LaunchAgents` or
//! `~/.config/systemd/user` and makes the daemon outlive every termio process,
//! which is the user's decision to make, not a side effect of running a
//! command.

use anyhow::{bail, Context, Result};
use std::path::PathBuf;

use crate::paths;

const LABEL_BASE: &str = "sh.termio.termiod";

/// The launchd label, scoped by channel: `sh.termio.termiod` for a release
/// build, `sh.termio.termiod.dev` for the dev build beside it.
///
/// The label is also the plist filename and the `gui/$UID/…` target, so one
/// label for two channels is one job for two apps to fight over: each
/// `install()` boots the other's out, repoints the plist at its own binary, and
/// `KeepAlive` respawns whichever wrote last. Scoping the socket alone would
/// not have fixed that — it is a second axis.
pub fn label() -> String {
    match paths::channel_suffix().strip_prefix('-') {
        Some(channel) => format!("{LABEL_BASE}.{channel}"),
        None => LABEL_BASE.to_string(),
    }
}

#[derive(clap::Subcommand)]
pub enum ServiceCmd {
    /// Install and start the user service: a launchd agent on macOS, a
    /// systemd --user unit on Linux.
    Install,
    /// Stop and remove the user service.
    Uninstall,
    /// Report whether the service is installed and running.
    Status,
}

fn home() -> Result<PathBuf> {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .context("HOME is not set, so the user's service directory can't be found")
}

fn plist_path() -> Result<PathBuf> {
    Ok(home()?
        .join("Library/LaunchAgents")
        .join(format!("{}.plist", label())))
}

fn escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

/// The agent definition.
///
/// `TERMIOD_SOCK` is forwarded **only if the caller had it set**. Both sides
/// derive the socket path the same way from the same environment, so pinning it
/// here when the user has not pinned it would make the daemon and the app
/// rendezvous at different sockets the moment either one's `TMPDIR` differs.
/// If the user has pinned it, they meant it, and the agent must honour it.
///
/// `TERMIO_CHANNEL` is the opposite case and is pinned whenever it is not the
/// release channel. There is nothing for the agent to inherit it *from*:
/// launchd starts the daemon from its own environment, and the channel is not
/// in it — the app reads its own off its bundle identifier. An unpinned agent
/// would therefore serve the release socket no matter which build installed it,
/// which is the collision this scoping exists to end.
pub fn plist(
    binary: &str,
    socket_override: Option<&str>,
    label: &str,
    channel: Option<&str>,
) -> String {
    let mut variables: Vec<(&str, &str)> = Vec::new();
    if let Some(channel) = channel {
        variables.push(("TERMIO_CHANNEL", channel));
    }
    if let Some(socket) = socket_override {
        variables.push(("TERMIOD_SOCK", socket));
    }
    let environment = if variables.is_empty() {
        String::new()
    } else {
        let body: String = variables
            .iter()
            .map(|(key, value)| {
                format!(
                    "        <key>{key}</key>\n        <string>{}</string>\n",
                    escape(value)
                )
            })
            .collect();
        format!("    <key>EnvironmentVariables</key>\n    <dict>\n{body}    </dict>\n")
    };
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>{label}</string>
    <key>ProgramArguments</key>
    <array>
        <string>{binary}</string>
        <string>serve</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Interactive</string>
{environment}</dict>
</plist>
"#,
        label = escape(label),
        binary = escape(binary),
        environment = environment,
    )
}

/// The binary launchd should run. Resolved to an absolute path at install time
/// so the agent does not depend on a `PATH` it will not inherit.
fn resolved_binary() -> Result<String> {
    let binary = std::env::current_exe().context("resolving this binary's path")?;
    let binary = binary.canonicalize().unwrap_or(binary);
    Ok(binary.to_string_lossy().into_owned())
}

fn launchctl(args: &[&str]) -> Result<std::process::Output> {
    std::process::Command::new("launchctl")
        .args(args)
        .output()
        .context("running launchctl")
}

fn domain_target() -> String {
    format!("gui/{}", unsafe { libc::getuid() })
}

pub fn run(cmd: ServiceCmd) -> Result<()> {
    if cfg!(target_os = "macos") {
        match cmd {
            ServiceCmd::Install => install(),
            ServiceCmd::Uninstall => uninstall(),
            ServiceCmd::Status => status(),
        }
    } else if cfg!(target_os = "linux") {
        match cmd {
            ServiceCmd::Install => systemd::install(),
            ServiceCmd::Uninstall => systemd::uninstall(),
            ServiceCmd::Status => systemd::status(),
        }
    } else {
        bail!("`termiod service` needs launchd (macOS) or systemd (Linux) to supervise the daemon");
    }
}

fn install() -> Result<()> {
    let path = plist_path()?;
    std::fs::create_dir_all(path.parent().expect("plist path always has a parent"))
        .context("creating ~/Library/LaunchAgents")?;
    let socket_override = std::env::var("TERMIOD_SOCK").ok();
    let label = label();
    let suffix = paths::channel_suffix();
    let contents = plist(
        &resolved_binary()?,
        socket_override.as_deref(),
        &label,
        suffix.strip_prefix('-'),
    );
    std::fs::write(&path, contents).with_context(|| format!("writing {}", path.display()))?;

    // Replacing an existing agent: boot it out first, or `bootstrap` fails with
    // "service already loaded" and the user is left running the old binary while
    // the new plist sits on disk claiming otherwise.
    let target = format!("{}/{label}", domain_target());
    let _ = launchctl(&["bootout", &target]);
    let output = launchctl(&["bootstrap", &domain_target(), &path.to_string_lossy()])?;
    if !output.status.success() {
        bail!(
            "launchctl bootstrap failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    println!("installed {label} → {}", path.display());
    println!("termiod now starts at login and restarts if it crashes.");
    Ok(())
}

fn uninstall() -> Result<()> {
    let path = plist_path()?;
    let label = label();
    let booted_out = launchctl(&["bootout", &format!("{}/{label}", domain_target())])
        .map(|output| output.status.success())
        .unwrap_or(false);
    match std::fs::remove_file(&path) {
        Ok(()) => println!("removed {}", path.display()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            println!("{label} was not installed");
        }
        Err(error) => return Err(error).with_context(|| format!("removing {}", path.display())),
    }
    // Booting out the job stops the daemon launchd owns, which ends its
    // sessions — the old message claimed the opposite. But a daemon some client
    // autostarted is not launchd's to stop, and it keeps running, so the claim
    // is only true when there was a loaded job to boot out.
    if booted_out {
        println!("the daemon and its running sessions were stopped; it will not restart.");
    } else {
        println!("no supervised daemon was loaded; anything already running is untouched.");
    }
    Ok(())
}

fn status() -> Result<()> {
    let path = plist_path()?;
    println!(
        "plist:  {} ({})",
        path.display(),
        if path.exists() { "present" } else { "absent" }
    );
    println!("socket: {}", paths::socket_path()?.display());
    let output = launchctl(&["print", &format!("{}/{}", domain_target(), label())])?;
    if output.status.success() {
        let text = String::from_utf8_lossy(&output.stdout);
        let pid = text
            .lines()
            .find_map(|line| line.trim().strip_prefix("pid = "))
            .unwrap_or("not running");
        println!("agent:  loaded (pid {})", pid.trim());
    } else {
        println!("agent:  not loaded");
    }
    Ok(())
}

/// The channel this build serves, as the value `TERMIO_CHANNEL` must carry:
/// `None` on the release channel, which is the absence of one.
fn channel() -> Option<String> {
    paths::channel_suffix()
        .strip_prefix('-')
        .map(str::to_string)
}

/// Whether systemd owns the daemon for *this caller's* socket: a unit exists,
/// it serves the socket this process would connect to, and it is enabled or
/// active. The unit file is read before `systemctl` is asked anything, so an
/// unsupervised box — the default — never spawns a process to find that out.
///
/// The socket check is the guard that keeps a `TERMIOD_SOCK`-pinned caller
/// (the test suite, a side-by-side daemon) from starting the real unit in
/// place of its own daemon: a daemon pointed at its own socket is its own
/// daemon, the same rule `paths::log_path` follows.
pub fn systemd_unit_owns_daemon() -> bool {
    if !cfg!(target_os = "linux") {
        return false;
    }
    let Ok(path) = systemd::unit_path() else {
        return false;
    };
    let Ok(text) = std::fs::read_to_string(&path) else {
        return false;
    };
    let socket_override = std::env::var("TERMIOD_SOCK").ok();
    let serves_this_socket = match socket_override.as_deref() {
        None => !text.contains("TERMIOD_SOCK="),
        Some(socket) => text.contains(&systemd::environment_line("TERMIOD_SOCK", socket)),
    };
    if !serves_this_socket {
        return false;
    }
    let unit = systemd::unit_name();
    let query = |verb: &str| {
        systemd::systemctl(&["--user", verb, "--quiet", &unit])
            .map(|output| output.status.success())
            .unwrap_or(false)
    };
    query("is-enabled") || query("is-active")
}

/// Start the daemon through its unit, for a client that found the socket dead
/// while [`systemd_unit_owns_daemon`] is true. A `setsid` fork here would win
/// the socket and leave the unit failing at every later start — which demotes
/// the box from supervised to unsupervised without anyone asking for it.
pub fn start_systemd_unit() -> Result<()> {
    let unit = systemd::unit_name();
    let output = systemd::systemctl(&["--user", "start", &unit])?;
    if !output.status.success() {
        bail!(
            "the daemon is supervised by systemd, but `systemctl --user start {unit}` failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    Ok(())
}

/// The Linux half: a systemd `--user` unit under `~/.config/systemd/user`.
mod systemd {
    use anyhow::{bail, Context, Result};
    use std::path::PathBuf;

    use crate::paths;

    const UNIT_BASE: &str = "termiod";

    /// The unit name, scoped by channel for the same reason as the launchd
    /// label: `termiod.service` for a release build, `termiod-dev.service` for
    /// the dev build beside it. `-dev` rather than `.dev` because a dot in a
    /// unit name is a template instance to systemd.
    pub fn unit_name() -> String {
        unit_name_for(super::channel().as_deref())
    }

    pub fn unit_name_for(channel: Option<&str>) -> String {
        match channel {
            Some(channel) => format!("{UNIT_BASE}-{channel}.service"),
            None => format!("{UNIT_BASE}.service"),
        }
    }

    /// `$XDG_CONFIG_HOME/systemd/user`, which is where `systemctl --user`
    /// looks, with `~/.config` as the base systemd itself assumes when the
    /// variable is unset.
    fn unit_dir() -> Result<PathBuf> {
        let config = match std::env::var_os("XDG_CONFIG_HOME") {
            Some(config) if !config.is_empty() => PathBuf::from(config),
            _ => super::home()?.join(".config"),
        };
        Ok(config.join("systemd").join("user"))
    }

    pub fn unit_path() -> Result<PathBuf> {
        Ok(unit_dir()?.join(unit_name()))
    }

    /// One word, quoted the way unit files read words. `%` is a specifier
    /// everywhere and `$` is a variable reference in `ExecStart=`, so both are
    /// doubled to stay literal; `\` and `"` are escaped so the path cannot
    /// close the quotes it sits in, and a newline becomes its escape because
    /// a unit line ends at the first one.
    fn quote(value: &str) -> String {
        let mut quoted = String::with_capacity(value.len() + 2);
        quoted.push('"');
        for character in value.chars() {
            match character {
                '%' => quoted.push_str("%%"),
                '$' => quoted.push_str("$$"),
                '\\' => quoted.push_str("\\\\"),
                '"' => quoted.push_str("\\\""),
                '\n' => quoted.push_str("\\n"),
                other => quoted.push(other),
            }
        }
        quoted.push('"');
        quoted
    }

    /// `Environment="KEY=value"`, the exact line [`unit`] writes, so a reader
    /// can look for the value it would have written rather than parse.
    pub fn environment_line(key: &str, value: &str) -> String {
        format!("Environment={}", quote(&format!("{key}={value}")))
    }

    /// The unit definition. The environment rules are `plist()`'s: `TERMIOD_SOCK`
    /// only if the caller had it set, `TERMIO_CHANNEL` whenever there is one —
    /// systemd starts the daemon from the manager's environment, not the
    /// shell's, so an unpinned dev unit would serve the release socket.
    ///
    /// `Restart=on-failure`, not `always`: `termiod stop` sends `SIGTERM` and
    /// waits for the socket to stay gone, and a unit that restarted on a clean
    /// exit would race that drain. The next client contact starts the unit
    /// again (`client::spawn_daemon`), which is the bounce path an update
    /// takes. WSS is deliberately not on the command line: the bind survives in
    /// `wss.bind` beside the socket, or in a `TERMIOD_WSS` drop-in.
    pub fn unit(binary: &str, socket_override: Option<&str>, channel: Option<&str>) -> String {
        let mut environment = String::new();
        if let Some(channel) = channel {
            environment.push_str(&environment_line("TERMIO_CHANNEL", channel));
            environment.push('\n');
        }
        if let Some(socket) = socket_override {
            environment.push_str(&environment_line("TERMIOD_SOCK", socket));
            environment.push('\n');
        }
        let description = match channel {
            Some(channel) => format!("termiod session host ({channel})"),
            None => "termiod session host".to_string(),
        };
        format!(
            "[Unit]\n\
             Description={description}\n\
             \n\
             [Service]\n\
             ExecStart={binary} serve\n\
             Restart=on-failure\n\
             {environment}\
             \n\
             [Install]\n\
             WantedBy=default.target\n",
            binary = quote(binary),
        )
    }

    /// A missing `systemctl` is an answer — this is not a systemd box — and is
    /// reported as one rather than as an opaque spawn failure.
    pub fn systemctl(args: &[&str]) -> Result<std::process::Output> {
        std::process::Command::new("systemctl")
            .args(args)
            .output()
            .context("running systemctl — is this user session managed by systemd?")
    }

    fn loginctl(args: &[&str]) -> Result<std::process::Output> {
        std::process::Command::new("loginctl")
            .args(args)
            .output()
            .context("running loginctl — is this user session managed by systemd?")
    }

    fn checked(output: std::process::Output, what: &str) -> Result<()> {
        if output.status.success() {
            return Ok(());
        }
        bail!(
            "{what} failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }

    fn is_active(unit: &str) -> Result<bool> {
        Ok(systemctl(&["--user", "is-active", "--quiet", unit])?
            .status
            .success())
    }

    /// Whether a daemon already answers on the socket. Sync on purpose: the
    /// service verbs are one-shot commands with no runtime.
    fn socket_answers() -> bool {
        paths::socket_path()
            .ok()
            .map(|socket| std::os::unix::net::UnixStream::connect(socket).is_ok())
            .unwrap_or(false)
    }

    pub fn install() -> Result<()> {
        let path = unit_path()?;
        let name = unit_name();
        // A daemon some client autostarted holds the socket the unit is about
        // to bind. The unit's daemon would exit "already running", systemd
        // would retry it until the start limit tripped, and the operator would
        // be left with a failed unit and the same unsupervised daemon. Stop is
        // the user's call: it declines while sessions are busy.
        if socket_answers() && !is_active(&name)? {
            bail!(
                "a daemon is already running unsupervised on {}; run `termiod stop` first, then install again",
                paths::socket_path()?.display()
            );
        }
        let directory = unit_dir()?;
        std::fs::create_dir_all(&directory)
            .with_context(|| format!("creating {}", directory.display()))?;
        let socket_override = std::env::var("TERMIOD_SOCK").ok();
        let contents = unit(
            &super::resolved_binary()?,
            socket_override.as_deref(),
            super::channel().as_deref(),
        );
        std::fs::write(&path, contents).with_context(|| format!("writing {}", path.display()))?;

        let was_active = is_active(&name)?;
        checked(
            systemctl(&["--user", "daemon-reload"])?,
            "systemctl --user daemon-reload",
        )?;
        checked(
            systemctl(&["--user", "enable", "--now", &name])?,
            &format!("systemctl --user enable --now {name}"),
        )?;
        println!("installed {name} → {}", path.display());
        if was_active {
            // `enable --now` leaves a running unit alone, and restarting it here
            // would end its sessions without being asked to.
            println!("the unit was already running; the definition on disk applies at its next start.");
        }

        // Linger is what makes "survives logout" true, and it changes the box's
        // logout behavior, so a refusal (polkit over ssh, typically) is a next
        // step for the operator rather than a failed install.
        let linger = loginctl(&["enable-linger"])?;
        if linger.status.success() {
            println!("termiod now starts at login, restarts if it crashes, and survives logout.");
        } else {
            println!("termiod now starts at login and restarts if it crashes.");
            println!(
                "linger could not be enabled ({}); to keep the daemon alive after logout, run:\n    loginctl enable-linger $USER",
                String::from_utf8_lossy(&linger.stderr).trim()
            );
        }
        Ok(())
    }

    pub fn uninstall() -> Result<()> {
        let path = unit_path()?;
        let name = unit_name();
        // Read before disabling: after `--now` the unit is inactive whether or
        // not it ever ran, and the message below has to say which.
        let was_active = is_active(&name).unwrap_or(false);
        let _ = systemctl(&["--user", "disable", "--now", &name])?;
        match std::fs::remove_file(&path) {
            Ok(()) => println!("removed {}", path.display()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                println!("{name} was not installed");
            }
            Err(error) => return Err(error).with_context(|| format!("removing {}", path.display())),
        }
        let _ = systemctl(&["--user", "daemon-reload"])?;
        // Linger is left as it was: it is a property of the account, not of
        // this unit, and the operator may have enabled it for other reasons.
        if was_active {
            println!("the daemon and its running sessions were stopped; it will not restart.");
        } else {
            println!("no supervised daemon was running; anything already running is untouched.");
        }
        Ok(())
    }

    pub fn status() -> Result<()> {
        let path = unit_path()?;
        let name = unit_name();
        println!(
            "unit:    {} ({})",
            path.display(),
            if path.exists() { "present" } else { "absent" }
        );
        println!("socket:  {}", paths::socket_path()?.display());

        let output = systemctl(&[
            "--user",
            "show",
            &name,
            "--property=LoadState,ActiveState,UnitFileState,MainPID",
        ])?;
        if !output.status.success() {
            bail!(
                "systemctl --user show failed: {}",
                String::from_utf8_lossy(&output.stderr).trim()
            );
        }
        let text = String::from_utf8_lossy(&output.stdout);
        let property = |key: &str| -> String {
            text.lines()
                .find_map(|line| line.strip_prefix(key).and_then(|rest| rest.strip_prefix('=')))
                .unwrap_or_default()
                .trim()
                .to_string()
        };
        let state = if property("LoadState") == "not-found" {
            "not installed".to_string()
        } else {
            let active = property("ActiveState");
            let pid = property("MainPID");
            let enabled = property("UnitFileState");
            match (active.as_str(), pid.as_str()) {
                ("active", pid) if pid != "0" && !pid.is_empty() => format!("active (pid {pid})"),
                (active, _) if enabled.is_empty() => active.to_string(),
                (active, _) => format!("{active} ({enabled})"),
            }
        };
        println!("service: {state}");

        let uid = unsafe { libc::getuid() }.to_string();
        let linger = loginctl(&["show-user", &uid, "--property=Linger", "--value"])?;
        if linger.status.success() {
            let value = String::from_utf8_lossy(&linger.stdout).trim().to_string();
            if value == "yes" {
                println!("linger:  yes");
            } else {
                println!("linger:  {value} — the daemon dies at logout; run `loginctl enable-linger $USER`");
            }
        } else {
            println!(
                "linger:  unknown ({})",
                String::from_utf8_lossy(&linger.stderr).trim()
            );
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::systemd::{unit, unit_name_for};
    use super::{plist, LABEL_BASE};

    /// The two keys that make this a *supervised* daemon rather than a one-shot
    /// launch: start at login, and come back after a crash.
    #[test]
    fn the_agent_starts_at_login_and_restarts_after_a_crash() {
        let text = plist("/usr/local/bin/termiod", None, LABEL_BASE, None);
        assert!(text.contains("<key>RunAtLoad</key>\n    <true/>"), "{text}");
        assert!(text.contains("<key>KeepAlive</key>\n    <true/>"), "{text}");
        assert!(text.contains(&format!("<string>{LABEL_BASE}</string>")));
        assert!(text.contains("<string>serve</string>"));
    }

    /// Pinning a socket the user never pinned would send the daemon and the app
    /// to different rendezvous points, so the key is simply absent.
    #[test]
    fn no_socket_is_pinned_unless_the_user_pinned_one() {
        assert!(!plist("/usr/local/bin/termiod", None, LABEL_BASE, None).contains("TERMIOD_SOCK"));

        let pinned = plist(
            "/usr/local/bin/termiod",
            Some("/tmp/custom/termiod.sock"),
            LABEL_BASE,
            None,
        );
        assert!(pinned.contains("<key>TERMIOD_SOCK</key>"), "{pinned}");
        assert!(pinned.contains("<string>/tmp/custom/termiod.sock</string>"));
    }

    /// The release channel is the absence of a channel, so its agent carries no
    /// `TERMIO_CHANNEL` and stays byte-identical to the one shipped before this
    /// scoping existed. A dev build's agent must differ on both axes at once —
    /// a distinct label, or the two jobs overwrite each other, *and* a pinned
    /// channel, or the job launchd starts serves the release socket.
    #[test]
    fn a_dev_agent_is_a_different_job_pinned_to_its_own_channel() {
        let release = plist("/usr/local/bin/termiod", None, LABEL_BASE, None);
        assert!(!release.contains("TERMIO_CHANNEL"), "{release}");

        let dev = plist(
            "/usr/local/bin/termiod",
            None,
            &format!("{LABEL_BASE}.dev"),
            Some("dev"),
        );
        assert!(dev.contains(&format!("<string>{LABEL_BASE}.dev</string>")), "{dev}");
        assert!(dev.contains("<key>TERMIO_CHANNEL</key>"), "{dev}");
        assert!(dev.contains("<string>dev</string>"), "{dev}");
    }

    /// Both environment keys land in one dict. Emitting a second
    /// `EnvironmentVariables` would make launchd read only the last.
    #[test]
    fn a_pinned_socket_and_channel_share_one_dict() {
        let text = plist(
            "/usr/local/bin/termiod",
            Some("/tmp/custom/termiod.sock"),
            &format!("{LABEL_BASE}.dev"),
            Some("dev"),
        );
        assert_eq!(text.matches("<key>EnvironmentVariables</key>").count(), 1, "{text}");
        assert!(text.contains("<key>TERMIO_CHANNEL</key>"), "{text}");
        assert!(text.contains("<key>TERMIOD_SOCK</key>"), "{text}");
    }

    /// A path with XML metacharacters must not be able to break the document —
    /// the plist is generated, and a malformed one fails to load with a message
    /// that explains nothing.
    #[test]
    fn paths_with_xml_metacharacters_stay_inside_their_element() {
        let text = plist("/opt/a&b/<termiod>", None, LABEL_BASE, None);
        assert!(text.contains("<string>/opt/a&amp;b/&lt;termiod&gt;</string>"), "{text}");
    }

    // MARK: systemd

    /// The two lines that make the unit a *supervised* daemon rather than a
    /// one-shot: come back after a crash, and start when the user's manager
    /// does. `on-failure` and not `always`, so a clean `termiod stop` stays
    /// stopped.
    #[test]
    fn the_unit_starts_at_login_and_restarts_after_a_crash() {
        let text = unit("/usr/local/bin/termiod", None, None);
        assert!(text.contains("\nRestart=on-failure\n"), "{text}");
        assert!(!text.contains("Restart=always"), "{text}");
        assert!(text.contains("\nWantedBy=default.target\n"), "{text}");
        assert!(text.contains("\nExecStart=\"/usr/local/bin/termiod\" serve\n"), "{text}");
        assert!(!text.contains("--wss"), "{text}");
    }

    #[test]
    fn no_socket_is_pinned_in_the_unit_unless_the_user_pinned_one() {
        assert!(!unit("/usr/local/bin/termiod", None, None).contains("TERMIOD_SOCK"));

        let pinned = unit("/usr/local/bin/termiod", Some("/tmp/custom/termiod.sock"), None);
        assert!(
            pinned.contains("\nEnvironment=\"TERMIOD_SOCK=/tmp/custom/termiod.sock\"\n"),
            "{pinned}"
        );
    }

    /// Same two axes as the launchd agent: a dev unit is a different unit,
    /// and it pins its channel, or the daemon systemd starts serves the
    /// release socket.
    #[test]
    fn a_dev_unit_is_a_different_unit_pinned_to_its_own_channel() {
        assert_eq!(unit_name_for(None), "termiod.service");
        assert_eq!(unit_name_for(Some("dev")), "termiod-dev.service");

        let release = unit("/usr/local/bin/termiod", None, None);
        assert!(!release.contains("TERMIO_CHANNEL"), "{release}");

        let dev = unit("/usr/local/bin/termiod", None, Some("dev"));
        assert!(dev.contains("\nEnvironment=\"TERMIO_CHANNEL=dev\"\n"), "{dev}");
    }

    /// Every environment line lands inside `[Service]`, before `[Install]`;
    /// systemd reads a key under the wrong section as an error.
    #[test]
    fn a_pinned_socket_and_channel_both_sit_in_the_service_section() {
        let text = unit("/usr/local/bin/termiod", Some("/tmp/custom/termiod.sock"), Some("dev"));
        let service = text.find("[Service]").unwrap_or(usize::MAX);
        let install = text.find("[Install]").unwrap_or(0);
        let channel = text.find("TERMIO_CHANNEL=").unwrap_or(0);
        let socket = text.find("TERMIOD_SOCK=").unwrap_or(0);
        assert!(service < channel && channel < install, "{text}");
        assert!(service < socket && socket < install, "{text}");
    }

    /// A path with unit-file metacharacters must not be able to break the
    /// unit: a space would split the word, `"` would close it, `%` is a
    /// specifier and `$` a variable to systemd, and any of them yields a unit
    /// that fails to load with a message that explains nothing.
    #[test]
    fn paths_with_unit_metacharacters_stay_inside_their_word() {
        let text = unit("/opt/a b/100%/$HOME/\"q\"\\termiod", Some("/tmp/50%/x.sock"), None);
        assert!(
            text.contains("\nExecStart=\"/opt/a b/100%%/$$HOME/\\\"q\\\"\\\\termiod\" serve\n"),
            "{text}"
        );
        assert!(text.contains("\nEnvironment=\"TERMIOD_SOCK=/tmp/50%%/x.sock\"\n"), "{text}");
    }
}
