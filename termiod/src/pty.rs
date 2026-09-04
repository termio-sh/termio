//! PTY ownership. The daemon opens a pseudo-terminal, spawns the session's
//! program on the slave side with the **login_tty shape** (setsid +
//! TIOCSCTTY + dup to 0/1/2), and keeps the master for byte I/O.
//!
//! The login_tty shape is deliberate: termio's macOS app learned the hard way
//! that a `posix_spawn`-without-controlling-tty PTY breaks agents' resize
//! repaint (see the repo's `terminal-resize-no-reflow` handoff). We reproduce
//! the `forkpty`/`login_tty` layout here so a remote `claude`/`codex` reflows
//! correctly on resize.

use anyhow::{bail, Context, Result};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::process::CommandExt;
use std::process::{Child, Command, Stdio};
use tokio::io::unix::AsyncFd;

/// The PTY master for a session. The child `Child` is handed back separately
/// so the session task can reap it in a blocking wait without borrowing this.
pub struct Pty {
    master: AsyncFd<OwnedFd>,
    pub pid: i32,
}

fn set_winsize(fd: RawFd, rows: u16, cols: u16) -> Result<()> {
    let ws = libc::winsize {
        ws_row: rows,
        ws_col: cols,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    let rc = unsafe { libc::ioctl(fd, libc::TIOCSWINSZ, &ws) };
    if rc != 0 {
        bail!("TIOCSWINSZ failed: {}", std::io::Error::last_os_error());
    }
    Ok(())
}

fn get_winsize(fd: RawFd) -> Result<(u16, u16)> {
    let mut ws = libc::winsize {
        ws_row: 0,
        ws_col: 0,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    let rc = unsafe { libc::ioctl(fd, libc::TIOCGWINSZ, &mut ws) };
    if rc != 0 {
        bail!("TIOCGWINSZ failed: {}", std::io::Error::last_os_error());
    }
    Ok((ws.ws_row, ws.ws_col))
}

fn set_nonblocking(fd: RawFd) -> Result<()> {
    unsafe {
        let flags = libc::fcntl(fd, libc::F_GETFL);
        if flags < 0 {
            bail!("F_GETFL: {}", std::io::Error::last_os_error());
        }
        if libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) < 0 {
            bail!("F_SETFL O_NONBLOCK: {}", std::io::Error::last_os_error());
        }
    }
    Ok(())
}

fn set_cloexec(fd: RawFd) -> Result<()> {
    unsafe {
        let flags = libc::fcntl(fd, libc::F_GETFD);
        if flags < 0 {
            bail!("F_GETFD: {}", std::io::Error::last_os_error());
        }
        if libc::fcntl(fd, libc::F_SETFD, flags | libc::FD_CLOEXEC) < 0 {
            bail!("F_SETFD FD_CLOEXEC: {}", std::io::Error::last_os_error());
        }
    }
    Ok(())
}

/// Environment variables that describe the terminal — or the agent — that
/// happened to launch the daemon, not how a session should run.
///
/// The daemon is long-lived and inherits its environment from whoever started
/// it: the macOS app hands over its own `environ` (it must, for TMPDIR), and
/// the app in turn inherits the shell that opened it. So a daemon started from
/// inside a Claude Code session carries `CLAUDE_CODE_CHILD_SESSION` forever,
/// and every session it spawns — hours or days later — inherits that agent's
/// identity. Claude Code reads that flag as "you are a sub-session" and stops
/// writing its transcript, so those sessions silently keep no history and
/// never appear in `--resume`.
///
/// The macOS app strips the same set before it spawns a PTY in-process
/// (`TermioStore.sanitizedEnvironment`), but it strips by *omission*: it sends
/// the environment it wants and omission cannot unset what this process
/// already has. Removing them here is what makes both spawn paths agree.
const LAUNCHER_ENV_KEYS: &[&str] = &[
    "CLAUDECODE",
    "CLAUDE_EFFORT",
    "TERMIO_SESSION",
    "TERM_SESSION_ID",
    "TERMINAL_EMULATOR",
    "TMUX",
    "TMUX_PANE",
    "STY",
    "INSIDE_EMACS",
    "LC_TERMINAL",
    "LC_TERMINAL_VERSION",
    "KONSOLE_VERSION",
    "GNOME_TERMINAL_SERVICE",
    "WT_SESSION",
    "NO_COLOR",
    "FORCE_COLOR",
    "CLICOLOR",
    "CLICOLOR_FORCE",
];

const LAUNCHER_ENV_PREFIXES: &[&str] = &[
    "TERM_PROGRAM",
    "VSCODE_",
    "CLAUDE_CODE_",
    "ITERM_",
    "GHOSTTY_",
    "KITTY_",
    "WEZTERM_",
    "ALACRITTY_",
];

fn is_launcher_env(key: &str) -> bool {
    LAUNCHER_ENV_KEYS.contains(&key) || LAUNCHER_ENV_PREFIXES.iter().any(|p| key.starts_with(p))
}

/// The launcher variables actually present in this daemon's environment. A
/// session that wants any of them back — `TERM_PROGRAM=termio`,
/// `TERMIO_SESSION=<this session's id>` — gets them as an explicit override,
/// which is layered after the removal.
fn inherited_launcher_keys() -> Vec<std::ffi::OsString> {
    std::env::vars_os()
        .map(|(key, _)| key)
        .filter(|key| key.to_str().is_some_and(is_launcher_env))
        .collect()
}

/// UTF-8 locales to fall back on, best first. `C.UTF-8` is the one every musl
/// system and every glibc since 2.35 has; `C.utf8` is how older glibc spells the
/// same thing; `en_US.UTF-8` is the common generated locale on a machine with no
/// `C.UTF-8` at all. Each is probed, never assumed.
const UTF8_FALLBACK_LOCALES: [&str; 3] = ["C.UTF-8", "C.utf8", "en_US.UTF-8"];

/// One locale name reduced to what makes two spellings the same locale.
/// `locale -a` prints glibc's own spelling (`en_US.utf8`, `C.utf8`) while the
/// name that arrives over SSH is the canonical one (`en_US.UTF-8`).
fn normalized_locale(name: &str) -> String {
    name.chars()
        .filter(|c| *c != '-' && *c != '_')
        .flat_map(char::to_lowercase)
        .collect()
}

/// Every locale this machine can resolve, as `locale -a` lists them, read once
/// and kept for the daemon's life. Empty when the question could not be asked.
///
/// **Asking our own libc is the wrong question, and it is the mistake this
/// replaces.** The daemon that ships to a VPS is statically linked against musl,
/// whose `setlocale` accepts any name at all — musl treats every locale as UTF-8
/// and has no database to miss. So an in-process probe answers "usable" for
/// `en_US.UTF-8` on a machine where no such locale exists, and the repair below
/// never fires. The programs that suffer — `bash`, `claude`, every TUI — are
/// glibc programs resolving against the system's locale database, and `locale -a`
/// is that database enumerated. It is the only oracle that speaks for the child
/// rather than for us.
fn available_locales() -> &'static std::collections::HashSet<String> {
    static LOCALES: std::sync::OnceLock<std::collections::HashSet<String>> =
        std::sync::OnceLock::new();
    LOCALES.get_or_init(|| {
        // stderr is dropped on purpose: `locale -a` also complains about the
        // very locale we are here to fix, and its complaint is not the answer.
        let Ok(output) = Command::new("locale").arg("-a").stderr(Stdio::null()).output() else {
            return std::collections::HashSet::new();
        };
        String::from_utf8_lossy(&output.stdout)
            .lines()
            .map(str::trim)
            .filter(|line| !line.is_empty())
            .map(normalized_locale)
            .collect()
    })
}

/// Whether a child on this machine can actually resolve `name` as a locale.
///
/// A machine that cannot be asked (no `locale` binary — Alpine, a scratch
/// container) is taken at its word instead of being second-guessed: everything
/// there is musl, where every name resolves and nothing warns.
fn locale_is_usable(name: &str) -> bool {
    let available = available_locales();
    available.is_empty() || available.contains(&normalized_locale(name))
}

/// The locale the child would end up with: `LC_ALL` overrides everything,
/// `LC_CTYPE` overrides `LANG` (POSIX). Empty is unset — an exported empty
/// string selects the implementation default, not a locale named "".
fn effective_locale(lookup: &dyn Fn(&str) -> Option<String>) -> Option<String> {
    ["LC_ALL", "LC_CTYPE", "LANG"]
        .into_iter()
        .find_map(|key| lookup(key).filter(|value| !value.is_empty()))
}

/// A usable UTF-8 locale to put the child in, or `None` when the locale it
/// already has works here.
///
/// This exists because a locale is named by one machine and resolved on another.
/// macOS ships `SendEnv LANG LC_*` in `/etc/ssh/ssh_config`, so a Mac's
/// `en_US.UTF-8` arrives on a VPS whose images generate only `C.UTF-8` — and the
/// warning that follows (`setlocale: LC_ALL: cannot change locale`) is the
/// *visible* half. The invisible half is worse: a failed `setlocale` leaves the
/// program in the C locale, so a UTF-8 terminal draws a TUI's box characters as
/// mojibake.
///
/// Repaired here rather than by asking the user to edit `~/.ssh/config`: this is
/// the only place the question is answerable, because "does this locale exist" is
/// a fact about the machine the session runs on, and this code is already on it.
/// The user's ssh config stays theirs.
fn utf8_locale_floor(
    lookup: &dyn Fn(&str) -> Option<String>,
    usable: &dyn Fn(&str) -> bool,
) -> Option<&'static str> {
    if let Some(named) = effective_locale(lookup) {
        if usable(&named) {
            return None;
        }
    }
    UTF8_FALLBACK_LOCALES.into_iter().find(|name| usable(name))
}

impl Pty {
    /// Open a PTY and spawn `argv` in `cwd`. Empty argv ⇒ the user's login
    /// shell, run as a login shell (`-<shell>`).
    pub fn spawn(
        argv: &[String],
        cwd: Option<&str>,
        env: &[(String, String)],
        rows: u16,
        cols: u16,
    ) -> Result<(Pty, Child)> {
        let mut master_raw: RawFd = -1;
        let mut slave_raw: RawFd = -1;
        let mut ws = libc::winsize {
            ws_row: rows,
            ws_col: cols,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        // `openpty`'s termp/winp pointer mutability differs between macOS
        // (`*mut`) and Linux (`*const`); `as _` coerces to whichever the target
        // libc expects.
        let rc = unsafe {
            libc::openpty(
                &mut master_raw,
                &mut slave_raw,
                std::ptr::null_mut::<libc::c_char>(),
                std::ptr::null_mut::<libc::termios>() as _,
                (&mut ws as *mut libc::winsize) as _,
            )
        };
        if rc != 0 {
            bail!("openpty failed: {}", std::io::Error::last_os_error());
        }

        // The master is ours; keep it off the child and make it async-pollable.
        let master = unsafe { OwnedFd::from_raw_fd(master_raw) };
        set_cloexec(master.as_raw_fd())?;
        set_nonblocking(master.as_raw_fd())?;

        let (program, args, login_shell) = resolve_program(argv);

        let mut cmd = Command::new(&program);
        cmd.args(&args);
        if let Some(dir) = cwd {
            cmd.current_dir(dir);
        }
        // Inherit the daemon's environment, minus whatever the daemon's own
        // launcher stamped into it, then layer session overrides.
        for key in inherited_launcher_keys() {
            cmd.env_remove(key);
        }
        if std::env::var_os("TERM").is_none() {
            cmd.env("TERM", "xterm-256color");
        }
        cmd.env("TERMIOD_SESSION", "1");
        for (k, v) in env {
            cmd.env(k, v);
        }
        // After the session's own overrides, so the check sees the locale the
        // child would really start with — and so a repair is not undone by the
        // loop above re-applying the value that needed repairing.
        let session_env = env;
        let lookup = |key: &str| {
            session_env
                .iter()
                .rev()
                .find(|(k, _)| k == key)
                .map(|(_, v)| v.clone())
                .or_else(|| std::env::var(key).ok())
        };
        if let Some(locale) = utf8_locale_floor(&lookup, &locale_is_usable) {
            // `LC_ALL` is removed rather than reassigned: it overrides every
            // category at once, and the machine's own `LC_TIME`/`LC_NUMERIC`
            // are better answers than this fallback for everything but ctype.
            cmd.env_remove("LC_ALL");
            cmd.env("LANG", locale);
            cmd.env("LC_CTYPE", locale);
        }
        // Route a zsh startup through the daemon's OSC 133 shim so the VT can
        // reflow resizes under it (see `crate::shell_integration`). The user's
        // own ZDOTDIR rides along and is restored by the shim before their
        // configuration loads; a shell that is not zsh, or a shim that cannot
        // be written, changes nothing.
        if let Some(shim) = crate::shell_integration::zsh_shim_zdotdir(&program) {
            if let Some(original) = lookup("ZDOTDIR") {
                cmd.env("TERMIOD_ZSH_ZDOTDIR", original);
            }
            cmd.env("ZDOTDIR", shim);
        }
        if login_shell {
            // argv[0] = "-<shell>" marks a login shell to the shell itself.
            let base = std::path::Path::new(&program)
                .file_name()
                .and_then(|s| s.to_str())
                .unwrap_or("sh");
            cmd.arg0(format!("-{base}"));
        }

        // The child's stdio is wired inside pre_exec via login_tty; don't let
        // std pre-open pipes for it.
        cmd.stdin(Stdio::null());
        cmd.stdout(Stdio::null());
        cmd.stderr(Stdio::null());

        unsafe {
            cmd.pre_exec(move || {
                // login_tty shape: new session, take the slave as controlling
                // tty, and make it fds 0/1/2.
                if libc::setsid() < 0 {
                    return Err(std::io::Error::last_os_error());
                }
                if libc::ioctl(slave_raw, libc::TIOCSCTTY as _, 0) < 0 {
                    return Err(std::io::Error::last_os_error());
                }
                for target in 0..3 {
                    if libc::dup2(slave_raw, target) < 0 {
                        return Err(std::io::Error::last_os_error());
                    }
                }
                if slave_raw > 2 {
                    libc::close(slave_raw);
                }
                // The launcher's signal state is not the session's, for the
                // same reason its environment is not (see LAUNCHER_ENV_KEYS).
                // `exec` resets handled signals on its own, but `SIG_IGN`
                // survives it and the mask survives both fork and exec — so a
                // daemon started under an ignored SIGQUIT, or forking from a
                // thread that inherited a blocked SIGTSTP, passes that state
                // on to the sessions it spawns. Rust's own spawn preserves the
                // parent's mask deliberately, so this is ours to do.
                //
                // The mask is cleared outright, but dispositions are reset only
                // for the terminal and job-control signals — not swept over
                // 1..NSIG, whose range is not portable and where SIGKILL and
                // SIGSTOP refuse the call. So an inherited `SIG_IGN` outside
                // this list does still reach the session, and that is the line:
                // ignoring SIGWINCH or SIGCONT already matches their default,
                // and SIGUSR1/2 are a supervisor's contract with the program
                // rather than terminal semantics. SIGPIPE is reset here even
                // though Rust does it just before this closure runs, so a
                // session does not depend on Rust's broken-pipe policy.
                let mut action: libc::sigaction = std::mem::zeroed();
                action.sa_sigaction = libc::SIG_DFL;
                if libc::sigemptyset(&mut action.sa_mask) != 0 {
                    return Err(std::io::Error::last_os_error());
                }
                for signal in [
                    libc::SIGCHLD,
                    libc::SIGHUP,
                    libc::SIGINT,
                    libc::SIGPIPE,
                    libc::SIGQUIT,
                    libc::SIGTERM,
                    libc::SIGALRM,
                    libc::SIGTSTP,
                    libc::SIGTTIN,
                    libc::SIGTTOU,
                ] {
                    if libc::sigaction(signal, &action, std::ptr::null_mut()) != 0 {
                        return Err(std::io::Error::last_os_error());
                    }
                }
                let mut unblocked: libc::sigset_t = std::mem::zeroed();
                if libc::sigemptyset(&mut unblocked) != 0
                    || libc::sigprocmask(libc::SIG_SETMASK, &unblocked, std::ptr::null_mut()) != 0
                {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }

        let spawned = cmd.spawn();

        // Parent no longer needs the slave, on the failing path as much as the
        // succeeding one: a session whose directory is gone gets retried every
        // time the user clicks it, and a leaked slave per attempt runs the
        // daemon out of descriptors.
        unsafe {
            libc::close(slave_raw);
        }

        let child = match spawned {
            Ok(child) => child,
            Err(error) => {
                // A missing program and a missing working directory both come
                // back as ENOENT, and the kernel doesn't say which one it meant.
                // Name the one that is actually gone — a checkout deleted or
                // sitting on an unmounted volume is far likelier than a missing
                // shell, and blaming the shell sends the user hunting the wrong
                // thing.
                if error.kind() == std::io::ErrorKind::NotFound {
                    if let Some(dir) = cwd.filter(|dir| !std::path::Path::new(dir).is_dir()) {
                        bail!("session directory '{dir}' no longer exists");
                    }
                }
                return Err(error)
                    .with_context(|| format!("spawning session program '{program}'"));
            }
        };

        let pid = child.id() as i32;
        let master = AsyncFd::new(master)?;
        Ok((Pty { master, pid }, child))
    }

    #[cfg(test)]
    pub(crate) fn non_pty_for_resize_failure_test() -> Result<Pty> {
        let (socket, peer) = std::os::unix::net::UnixStream::pair()?;
        drop(peer);
        socket.set_nonblocking(true)?;
        let fd: OwnedFd = socket.into();
        Ok(Pty {
            master: AsyncFd::new(fd)?,
            pid: 0,
        })
    }

    /// The process group that currently owns the tty's foreground — the program
    /// the user is actually interacting with: the login shell until it runs a
    /// command, then that command, then the shell again once it exits.
    ///
    /// `tcgetpgrp` on the *master* is deliberate and portable: both XNU and
    /// Linux route TIOCGPGRP on a pty master to the slave's session, and the
    /// master side is exempt from the "must be your controlling terminal" check
    /// that would otherwise refuse the daemon. `None` when the slave has no
    /// session (the child is gone, or has not exec'd yet).
    /// Take over a PTY master that crossed an `execve` (see `crate::handoff`).
    ///
    /// There is no child to spawn and no `Child` to hand back: the process on
    /// the far side of this descriptor has been running since before the
    /// upgrade, and it is still this process's own child — `execve` keeps the
    /// pid, so the parentage the kernel recorded at `fork` is untouched. What
    /// is gone is every bit of userspace bookkeeping, which is why the pid
    /// arrives as a number and is reaped with `waitpid` rather than through
    /// `std::process::Child`.
    pub fn adopt(master: RawFd, pid: i32) -> Result<Pty> {
        let master = unsafe { OwnedFd::from_raw_fd(master) };
        // Both flags are properties of the *descriptor*, not of the open file
        // description, so neither survived the duplication that carried it
        // here. Re-establish the pair `spawn` establishes.
        set_cloexec(master.as_raw_fd())?;
        set_nonblocking(master.as_raw_fd())?;
        let master = AsyncFd::new(master)?;
        Ok(Pty { master, pid })
    }

    /// The master descriptor, for the one caller that needs the number rather
    /// than the I/O: packing this PTY into a handoff blob.
    pub fn master_fd(&self) -> RawFd {
        self.master.get_ref().as_raw_fd()
    }

    pub fn foreground_pgid(&self) -> Option<i32> {
        let pgid = unsafe { libc::tcgetpgrp(self.master.get_ref().as_raw_fd()) };
        (pgid > 0).then_some(pgid)
    }

    /// Deliver the SIGWINCH a resize would have, without a resize.
    ///
    /// For when a client was just handed a screen the daemon knows is wrong —
    /// a ring replay of bytes written into a grid the session no longer has —
    /// and the size is not changing, so no ioctl is coming to make the child
    /// repaint. A full-screen program answers by re-reading `TIOCGWINSZ`
    /// (unchanged) and redrawing from its own model; that redraw is the
    /// correct screen, and it reaches every attachment as ordinary output.
    pub fn nudge_repaint(&self) {
        if let Some(pgid) = self.foreground_pgid() {
            unsafe {
                libc::killpg(pgid, libc::SIGWINCH);
            }
        }
    }

    /// Push a new window size to the PTY (TIOCSWINSZ) and return the size the
    /// kernel actually holds afterwards.
    ///
    /// The read-back is not paranoia about the ioctl's return code: the child
    /// reflows off SIGWINCH and its own `TIOCGWINSZ`, so the kernel's copy — not
    /// the number we asked for — is the one every viewer's bytes are wrapped
    /// for. A caller that recorded its request instead would hand its clients a
    /// grid the child does not have, and nothing downstream could tell.
    pub fn resize(&self, rows: u16, cols: u16) -> Result<(u16, u16)> {
        let fd = self.master.get_ref().as_raw_fd();
        set_winsize(fd, rows, cols)?;
        get_winsize(fd)
    }

    /// Read available PTY output. `Ok(0)` means the slave closed (process
    /// gone).
    pub async fn read(&self, buf: &mut [u8]) -> std::io::Result<usize> {
        loop {
            let mut guard = self.master.readable().await?;
            let fd = self.master.get_ref().as_raw_fd();
            match guard.try_io(|_| {
                let n = unsafe { libc::read(fd, buf.as_mut_ptr() as *mut _, buf.len()) };
                if n < 0 {
                    Err(std::io::Error::last_os_error())
                } else {
                    Ok(n as usize)
                }
            }) {
                Ok(result) => return result,
                Err(_would_block) => continue,
            }
        }
    }

    /// Write client input to the PTY.
    pub async fn write_all(&self, mut data: &[u8]) -> std::io::Result<()> {
        while !data.is_empty() {
            let mut guard = self.master.writable().await?;
            let fd = self.master.get_ref().as_raw_fd();
            match guard.try_io(|_| {
                let n = unsafe { libc::write(fd, data.as_ptr() as *const _, data.len()) };
                if n < 0 {
                    Err(std::io::Error::last_os_error())
                } else {
                    Ok(n as usize)
                }
            }) {
                Ok(Ok(n)) => data = &data[n..],
                Ok(Err(e)) => return Err(e),
                Err(_would_block) => continue,
            }
        }
        Ok(())
    }
}

/// Decide the program to exec. Empty argv ⇒ `$SHELL` (or `/bin/sh`) as a login
/// shell. Otherwise run argv verbatim.
fn resolve_program(argv: &[String]) -> (String, Vec<String>, bool) {
    if argv.is_empty() {
        let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".to_string());
        (shell, Vec::new(), true)
    } else {
        (argv[0].clone(), argv[1..].to_vec(), false)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn launcher_identity_is_classified_apart_from_the_session_environment() {
        assert!(is_launcher_env("CLAUDE_CODE_CHILD_SESSION"));
        assert!(is_launcher_env("CLAUDE_CODE_SESSION_ID"));
        assert!(is_launcher_env("CLAUDECODE"));
        assert!(is_launcher_env("TERM_PROGRAM"));
        assert!(is_launcher_env("TERM_PROGRAM_VERSION"));
        assert!(is_launcher_env("TERMIO_SESSION"));
        assert!(is_launcher_env("TMUX"));

        // Everything that says where the process runs, rather than who started
        // the daemon, has to survive — a session with no PATH is unusable.
        assert!(!is_launcher_env("PATH"));
        assert!(!is_launcher_env("HOME"));
        assert!(!is_launcher_env("SHELL"));
        assert!(!is_launcher_env("TMPDIR"));
        assert!(!is_launcher_env("TERM"));
        assert!(!is_launcher_env("ANTHROPIC_API_KEY"));
    }

    /// The ordering half: removal happens *before* the session's own overrides
    /// are layered, so a session can still ask for a key the daemon inherited.
    #[tokio::test]
    async fn spawned_child_gets_the_session_identity_not_the_daemon_launcher_identity() {
        std::env::set_var("CLAUDE_CODE_CHILD_SESSION", "1");
        std::env::set_var("TERM_PROGRAM", "Apple_Terminal");

        let dump = std::env::temp_dir().join(format!("termiod-env-{}", std::process::id()));
        let argv = vec![
            "/bin/sh".to_string(),
            "-c".to_string(),
            format!("env > {}", dump.display()),
        ];
        let overrides = vec![("TERM_PROGRAM".to_string(), "termio".to_string())];
        let (_pty, mut child) =
            Pty::spawn(&argv, None, &overrides, 24, 80).expect("spawn env dump");
        child.wait().expect("child exits");

        let dumped = std::fs::read_to_string(&dump).expect("env dump");
        let _ = std::fs::remove_file(&dump);
        // Process-global, so leaving it set would follow every other test in
        // this binary into whatever it spawns.
        std::env::remove_var("CLAUDE_CODE_CHILD_SESSION");
        std::env::remove_var("TERM_PROGRAM");

        assert!(!dumped.contains("CLAUDE_CODE_CHILD_SESSION="));
        assert!(dumped.contains("TERM_PROGRAM=termio"));
        assert!(!dumped.contains("TERM_PROGRAM=Apple_Terminal"));
    }

    /// End to end through the real shell: a zsh spawned by the daemon emits
    /// the OSC 133 prompt-start mark, because `spawn` routed its startup
    /// through the shim (`crate::shell_integration`). Without the mark the VT
    /// can never reflow a resize under the shell, so this is the assertion
    /// that the whole injection chain — ZDOTDIR handoff, shim install, hook
    /// registration — actually reaches the byte stream.
    ///
    /// Skipped where zsh is not installed; the shim itself is unit-tested in
    /// `shell_integration`.
    #[tokio::test]
    async fn a_spawned_zsh_emits_prompt_marks() {
        let Some(zsh) = ["/bin/zsh", "/usr/bin/zsh"]
            .into_iter()
            .find(|path| std::path::Path::new(path).exists())
        else {
            return;
        };

        // A scratch HOME (and ZDOTDIR, exercising the shim's restore path)
        // keeps the user's real zsh configuration out of the assertion.
        let home = std::env::temp_dir().join(format!("termiod-zsh-marks-{}", std::process::id()));
        std::fs::create_dir_all(&home).expect("scratch home");
        let overrides = vec![
            ("HOME".to_string(), home.display().to_string()),
            ("ZDOTDIR".to_string(), home.display().to_string()),
        ];
        let (pty, mut child) = Pty::spawn(
            &[zsh.to_string(), "-i".to_string()],
            None,
            &overrides,
            24,
            80,
        )
        .expect("spawn zsh");

        const PROMPT_START: &[u8] = b"\x1b]133;A\x07";
        let marked = |bytes: &[u8]| bytes.windows(PROMPT_START.len()).any(|w| w == PROMPT_START);
        let mut collected = Vec::new();
        let mut buffer = [0u8; 4096];
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(15);
        while !marked(&collected) {
            match tokio::time::timeout_at(deadline, pty.read(&mut buffer)).await {
                Ok(Ok(0)) | Ok(Err(_)) | Err(_) => break,
                Ok(Ok(count)) => collected.extend_from_slice(&buffer[..count]),
            }
        }
        let _ = child.kill();
        let _ = child.wait();
        let _ = std::fs::remove_dir_all(&home);

        assert!(
            marked(&collected),
            "no OSC 133 prompt mark in zsh output: {:?}",
            String::from_utf8_lossy(&collected)
        );
    }

    /// The other half of the launcher problem: the terminal and job-control
    /// signals reach a session at their defaults, whatever the launcher left
    /// blocked or ignored.
    ///
    /// `exec` resets handled signals, so most contamination heals itself. Two
    /// kinds do not: `SIG_IGN` survives `exec`, and the signal mask survives
    /// both `fork` and `exec`. Both leave the same fingerprint — a shell that
    /// signals itself lives to reach `exit 99` — so each is staged on its own.
    ///
    /// An ignored SIGINT is process-wide and `cargo test` runs other tests on
    /// other threads throughout, so the daemon's own state goes back before the
    /// child is waited on, through a guard that a failed assert cannot skip.
    #[tokio::test]
    async fn a_session_gets_the_terminal_signals_the_launcher_blocked_or_ignored() {
        use std::os::unix::process::ExitStatusExt;

        struct RestoreDisposition(libc::sighandler_t);
        impl Drop for RestoreDisposition {
            fn drop(&mut self) {
                unsafe { libc::signal(libc::SIGINT, self.0) };
            }
        }

        struct RestoreMask(libc::sigset_t);
        impl Drop for RestoreMask {
            fn drop(&mut self) {
                unsafe { libc::pthread_sigmask(libc::SIG_SETMASK, &self.0, std::ptr::null_mut()) };
            }
        }

        let argv = vec![
            "/bin/sh".to_string(),
            "-c".to_string(),
            "kill -s INT $$; exit 99".to_string(),
        ];

        let ignored = {
            let _restore = RestoreDisposition(unsafe { libc::signal(libc::SIGINT, libc::SIG_IGN) });
            Pty::spawn(&argv, None, &[], 24, 80)
        };
        // The master is held until the child is reaped: closing it early hangs
        // up the session, and a child killed by SIGHUP would pass for a pass.
        let (_master, mut child) = ignored.expect("spawn under an ignored SIGINT");
        assert_eq!(
            child.wait().expect("the child exits").signal(),
            Some(libc::SIGINT),
            "an ignored SIGINT survives exec, so the session inherits it unless it is reset"
        );

        // The mask is per-thread, and `#[tokio::test]` runs on a single thread,
        // so this is the thread that forks.
        let blocked = {
            let _restore = RestoreMask(unsafe {
                let mut blocked: libc::sigset_t = std::mem::zeroed();
                assert_eq!(libc::sigemptyset(&mut blocked), 0);
                assert_eq!(libc::sigaddset(&mut blocked, libc::SIGINT), 0);
                let mut previous: libc::sigset_t = std::mem::zeroed();
                assert_eq!(
                    libc::pthread_sigmask(libc::SIG_BLOCK, &blocked, &mut previous),
                    0,
                    "the test asserts nothing if SIGINT was never blocked"
                );
                previous
            });
            Pty::spawn(&argv, None, &[], 24, 80)
        };
        let (_master, mut child) = blocked.expect("spawn under a blocked SIGINT");
        assert_eq!(
            child.wait().expect("the child exits").signal(),
            Some(libc::SIGINT),
            "the signal mask survives fork and exec, so a blocked SIGINT never reaches the session"
        );
    }

    /// A checkout that was deleted or is sitting on an unmounted volume fails the
    /// spawn with the same ENOENT a missing program does. The message has to name
    /// the directory: blaming `/bin/zsh` for a missing folder sent a user hunting
    /// a shell that was never broken.
    #[tokio::test]
    async fn a_missing_working_directory_is_not_reported_as_a_missing_program() {
        let missing = std::env::temp_dir().join(format!("termiod-gone-{}", std::process::id()));
        let missing = missing.to_string_lossy().to_string();

        let Err(error) = Pty::spawn(&["/bin/sh".to_string()], Some(&missing), &[], 24, 80) else {
            panic!("a spawn into a directory that does not exist must fail");
        };
        let message = format!("{error:#}");

        assert!(message.contains(&missing), "{message}");
        assert!(!message.contains("/bin/sh"), "{message}");
    }

    /// The other half: a program that really is missing still says so, so naming
    /// the directory has not just moved the misattribution the other way.
    #[tokio::test]
    async fn a_missing_program_is_still_reported_as_a_missing_program() {
        let here = std::env::temp_dir().to_string_lossy().to_string();

        let Err(error) = Pty::spawn(
            &["/nonexistent/termiod-not-a-program".to_string()],
            Some(&here),
            &[],
            24,
            80,
        ) else {
            panic!("a spawn of a program that does not exist must fail");
        };

        assert!(
            format!("{error:#}").contains("/nonexistent/termiod-not-a-program"),
            "{error:#}"
        );
    }

    /// `LC_ALL` outranks both, then `LC_CTYPE`, then `LANG` — and an exported
    /// empty string is unset, not a locale named "".
    #[test]
    fn the_effective_locale_follows_the_posix_precedence() {
        let all = |key: &str| match key {
            "LC_ALL" => Some("ja_JP.UTF-8".to_string()),
            "LC_CTYPE" => Some("de_DE.UTF-8".to_string()),
            "LANG" => Some("en_US.UTF-8".to_string()),
            _ => None,
        };
        assert_eq!(effective_locale(&all).as_deref(), Some("ja_JP.UTF-8"));

        let ctype = |key: &str| match key {
            "LC_ALL" => Some(String::new()),
            "LC_CTYPE" => Some("de_DE.UTF-8".to_string()),
            "LANG" => Some("en_US.UTF-8".to_string()),
            _ => None,
        };
        assert_eq!(effective_locale(&ctype).as_deref(), Some("de_DE.UTF-8"));

        let none = |_: &str| None;
        assert_eq!(effective_locale(&none), None);
    }

    /// The case this exists for: a Mac forwards `en_US.UTF-8` to a VPS whose
    /// image generated only `C.UTF-8`. The name looks like UTF-8 and is not
    /// usable here, which a string test cannot tell apart.
    #[test]
    fn an_unusable_locale_is_replaced_even_when_its_name_says_utf8() {
        let forwarded = |key: &str| match key {
            "LC_ALL" => Some("en_US.UTF-8".to_string()),
            _ => None,
        };
        let only_c_utf8 = |name: &str| name == "C.UTF-8";
        assert_eq!(
            utf8_locale_floor(&forwarded, &only_c_utf8),
            Some("C.UTF-8"),
            "a locale this machine cannot resolve is not a locale"
        );
    }

    /// A machine that has what it was handed is left alone — including a
    /// non-UTF-8 locale someone chose on purpose, which is theirs to choose.
    #[test]
    fn a_usable_locale_is_left_alone() {
        let lookup = |key: &str| (key == "LANG").then(|| "en_US.UTF-8".to_string());
        assert_eq!(utf8_locale_floor(&lookup, &|_| true), None);

        let latin = |key: &str| (key == "LANG").then(|| "en_US.ISO-8859-1".to_string());
        assert_eq!(utf8_locale_floor(&latin, &|_| true), None);
    }

    /// Nothing set at all — the Amazon Linux / Alpine shape — takes the floor,
    /// which is what stops a remote TUI drawing its borders as mojibake.
    #[test]
    fn an_unset_locale_takes_the_utf8_floor() {
        let unset = |_: &str| None;
        assert_eq!(utf8_locale_floor(&unset, &|_| true), Some("C.UTF-8"));
        // Older glibc spells it the other way.
        assert_eq!(
            utf8_locale_floor(&unset, &|name: &str| name == "C.utf8"),
            Some("C.utf8")
        );
        // And a machine with none of them keeps whatever it had: inventing a
        // locale that does not resolve would trade one broken value for another.
        assert_eq!(utf8_locale_floor(&unset, &|_| false), None);
    }

    /// `locale -a` prints glibc's spelling and SSH forwards the canonical one;
    /// they name the same locale and must compare equal.
    #[test]
    fn two_spellings_of_one_locale_compare_equal() {
        assert_eq!(normalized_locale("en_US.UTF-8"), normalized_locale("en_US.utf8"));
        assert_eq!(normalized_locale("C.UTF-8"), normalized_locale("C.utf8"));
        assert_ne!(normalized_locale("en_US.UTF-8"), normalized_locale("en_GB.UTF-8"));
        // Not so aggressive that different locales collapse into each other.
        assert_ne!(normalized_locale("C.UTF-8"), normalized_locale("C"));
    }

    /// The probe answers for the *child's* libc, so a machine that lists only
    /// `C`/`C.utf8` must refuse `en_US.UTF-8` — which the daemon's own musl
    /// `setlocale` would have accepted.
    #[test]
    fn the_probe_answers_from_the_machines_locale_list() {
        let listed: std::collections::HashSet<String> = ["C", "C.utf8", "POSIX"]
            .into_iter()
            .map(normalized_locale)
            .collect();
        let usable = |name: &str| listed.contains(&normalized_locale(name));

        assert!(usable("C.UTF-8"));
        assert!(!usable("en_US.UTF-8"));

        let forwarded = |key: &str| (key == "LC_ALL").then(|| "en_US.UTF-8".to_string());
        assert_eq!(utf8_locale_floor(&forwarded, &usable), Some("C.UTF-8"));
    }
}
