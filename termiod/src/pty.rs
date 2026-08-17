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
        // Inherit the daemon's environment, then layer session overrides.
        if std::env::var_os("TERM").is_none() {
            cmd.env("TERM", "xterm-256color");
        }
        cmd.env("TERMIOD_SESSION", "1");
        for (k, v) in env {
            cmd.env(k, v);
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
                Ok(())
            });
        }

        let child = cmd
            .spawn()
            .with_context(|| format!("spawning session program '{program}'"))?;

        // Parent no longer needs the slave.
        unsafe {
            libc::close(slave_raw);
        }

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

    /// Push a new window size to the PTY (TIOCSWINSZ). The kernel delivers
    /// SIGWINCH to the foreground process group.
    pub fn resize(&self, rows: u16, cols: u16) -> Result<()> {
        set_winsize(self.master.get_ref().as_raw_fd(), rows, cols)
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
