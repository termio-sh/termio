//! Shell integration: OSC 133 prompt marks for the sessions the daemon spawns.
//!
//! A resize while a shell holds the terminal can only reflow safely if the
//! host knows which rows are the prompt — zsh's SIGWINCH redisplay repaints
//! against the old wrap points, and rewrapping under it duplicates the prompt
//! (`termiod_vt::VtTerminal::resize_for_shell` holds the other half of this).
//! Shells do not announce their prompt rows on their own; Ghostty and Kitty
//! solve it by pointing one zsh startup at their own `ZDOTDIR` so the shell
//! sources a hook file that emits the marks. This module is that mechanism
//! with termiod as the owner: written from scratch, because Ghostty's script
//! is GPLv3 via Kitty's and this repository is MIT.
//!
//! Only zsh is instrumented. It is the login shell these sessions almost
//! always run, and it is the shell whose redisplay produced the duplicated
//! prompt this exists to prevent. A shell without marks loses nothing it had:
//! the VT falls back to the truncating resize that was previously
//! unconditional.

use std::path::{Path, PathBuf};

/// The `.zshenv` shim one zsh startup is pointed at. It hands the borrowed
/// `ZDOTDIR` back before the user's own configuration runs, so the only thing
/// that changes about the shell is the marks it emits.
///
/// The prompt-start mark lives in `PS1` (invisibly, via `%{ %}`) rather than
/// being printed from the hook, because zle's own SIGWINCH redraw reprints
/// `PS1`: a printed mark would survive only until the first resize repaint,
/// and the second resize would find an unmarked prompt and truncate again.
const ZSH_SHIM: &str = r#"# termiod routes one zsh startup through this directory (ZDOTDIR) so the
# session's shell emits OSC 133 prompt marks -- the rows the host must know
# to blank before it may reflow the screen on resize. The borrowed ZDOTDIR
# is handed back immediately, before the user's own configuration runs, so
# nothing else about the shell changes and a nested zsh is left alone.

if [[ -n "${TERMIOD_ZSH_ZDOTDIR+set}" ]]; then
    builtin export ZDOTDIR="$TERMIOD_ZSH_ZDOTDIR"
    builtin unset TERMIOD_ZSH_ZDOTDIR
else
    builtin unset ZDOTDIR
fi

if [[ -f "${ZDOTDIR:-$HOME}/.zshenv" ]]; then
    builtin source "${ZDOTDIR:-$HOME}/.zshenv"
fi

[[ -o interactive ]] || return 0

# $? seen by the first precmd hook is the command's exit status; by the time
# a later hook runs it is whatever the hooks before it returned. Capture it
# in a hook registered before any theme's, for the close-out mark below.
typeset -g _termiod_exit_status=0
typeset -g _termiod_command_running=''
_termiod_capture_status() { _termiod_exit_status=$?; }

_termiod_preexec() {
    builtin print -rn -- $'\e]133;C\a'
    _termiod_command_running=1
}

# Close the previous command with its status, then make sure PS1 opens with
# the prompt-start mark, wrapped in %{ %} so zsh's width math never sees it.
_termiod_mark_prompt() {
    if [[ -n "$_termiod_command_running" ]]; then
        builtin print -rn -- $'\e]133;D;'"${_termiod_exit_status}"$'\a'
        _termiod_command_running=''
    fi
    if [[ "$PS1" != *$'\e]133;A\a'* ]]; then
        PS1="%{"$'\e]133;A\a'"%}${PS1}"
    fi
}

# Themes rewrite PS1 from their own precmd hooks, and hooks run in
# registration order -- a marker registered here, at .zshenv time, would run
# before anything .zshrc registers and have its mark stripped every cycle.
# So the first prompt re-registers the marker at the end of the list, where
# it runs after every theme, and steps out of the way.
_termiod_arm() {
    add-zsh-hook -d precmd _termiod_arm
    precmd_functions+=(_termiod_mark_prompt)
    _termiod_mark_prompt
}

autoload -Uz add-zsh-hook
add-zsh-hook precmd _termiod_capture_status
add-zsh-hook precmd _termiod_arm
add-zsh-hook preexec _termiod_preexec
"#;

/// The `ZDOTDIR` to point a zsh session at, or `None` when `program` is not
/// zsh or the shim could not be written. `None` never fails the spawn: a
/// session without marks resizes the way every session did before this
/// existed.
pub fn zsh_shim_zdotdir(program: &str) -> Option<PathBuf> {
    let name = Path::new(program)
        .file_name()
        .and_then(|name| name.to_str())?
        .trim_start_matches('-');
    if name != "zsh" {
        return None;
    }
    let dir = match crate::paths::state_dir() {
        Ok(state) => state.join("shell-integration").join("zsh"),
        Err(error) => {
            eprintln!("termiod: shell integration disabled, no state dir: {error}");
            return None;
        }
    };
    match install_shim(&dir) {
        Ok(()) => Some(dir),
        Err(error) => {
            eprintln!(
                "termiod: shell integration disabled, cannot write {}: {error}",
                dir.display()
            );
            None
        }
    }
}

/// Write the shim if it is missing or stale. Byte-compared first so steady
/// state is a read, not a write — sessions spawn far more often than this
/// file changes, and the shim must always match the daemon that wrote it.
fn install_shim(dir: &Path) -> std::io::Result<()> {
    let path = dir.join(".zshenv");
    if std::fs::read(&path).is_ok_and(|current| current == ZSH_SHIM.as_bytes()) {
        return Ok(());
    }
    std::fs::create_dir_all(dir)?;
    std::fs::write(&path, ZSH_SHIM)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_zsh_is_instrumented() {
        for program in ["/bin/bash", "bash", "fish", "/usr/bin/dash", "claude"] {
            assert_eq!(zsh_shim_zdotdir(program), None, "{program} must not get the shim");
        }
    }

    #[test]
    fn shim_is_installed_and_kept_current() {
        let dir = std::env::temp_dir().join(format!("termiod-shim-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);

        install_shim(&dir).expect("install");
        let path = dir.join(".zshenv");
        let written = std::fs::read_to_string(&path).expect("read shim");
        assert_eq!(written, ZSH_SHIM);

        // A stale shim (an older daemon's) is replaced, not trusted.
        std::fs::write(&path, "stale").expect("stale write");
        install_shim(&dir).expect("reinstall");
        assert_eq!(std::fs::read_to_string(&path).expect("reread"), ZSH_SHIM);

        let _ = std::fs::remove_dir_all(&dir);
    }
}
