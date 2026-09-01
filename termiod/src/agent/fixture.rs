//! The Stage 1 gate: one record per manifest, produced by both parsers.
//!
//! The manifest format is user-extensible, so two parsers is a real cost and
//! this is what pays it. Every manifest termio ships, plus a set of edge cases
//! that exist only to be disagreed about, is parsed here and by
//! `Tests/termioTests/AgentManifestFixtureTests.swift`, and both are asserted
//! against one golden file. A manifest the two read differently is a bug the
//! user experiences as "my agent shows up in the list but never gets hooks",
//! and it is silent — so it has to fail a build instead.
//!
//! **This is a permanent contract, not migration scaffolding.** Swift did not
//! stop parsing manifests when the installers moved to the daemon in Stage 4 —
//! it stopped *writing* from them. The app still renders the agent roster, so it
//! still needs every name, icon and command in these files, and the daemon needs
//! every path, dialect and event. Two live parsers, one format, for as long as
//! both exist. Do not delete this when the migration is forgotten.
//!
//! Regenerate the golden from **this** side:
//!
//! ```sh
//! cd termiod && UPDATE_AGENT_MANIFEST_FIXTURE=1 cargo test agent_manifest_fixture
//! ```
//!
//! The Swift test never writes it. If the two disagree, the question is which
//! parser is wrong, and a golden either side could rewrite would not make you
//! ask it.
//!
//! Two fields are deliberately compared loosely, because the difference is a
//! fact about where the code runs rather than a disagreement about the file:
//!
//! - **A bundled icon asset is not verified here.** The assets live in the app
//!   bundle; a daemon on a VPS has none. Swift raises `bundled icon asset '…' is
//!   missing` for a name that does not resolve and this cannot. The record
//!   therefore carries the icon's *kind*, and an asset and a relative path both
//!   read as `image` — which is also all `AgentIcon` retains of the difference.
//! - **Invalid regex is not detected here.** Both sides now carry status
//!   patterns as raw strings, and only the daemon compiles them
//!   (`session::status::RuleSet`). The paragraph this replaces argued the
//!   opposite — that choosing a Rust regex engine would mean choosing a
//!   *different* accepted language, a worse disagreement than none — and it was
//!   right while both sides matched. It stopped applying when Swift stopped:
//!   one matcher is one accepted language, and
//!   `session::status::tests::bundled_status_patterns_compile` is what keeps
//!   every shipped pattern inside it. See
//!   `docs/design/20260831-companion-second-protocol-retires.md` §3.4. No fixture
//!   declares a pattern that fails to compile.

use super::manifest::{AgentDefinition, AgentManifest, IconReference, ManifestError};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};

/// Repo-relative manifest sets both sides read, in this order.
const BUNDLED: [&str; 2] = [
    "Sources/termio/Resources/terminal.json",
    "Sources/termio/Resources/agents",
];
const CASES: &str = "Tests/Fixtures/agent-manifests/cases";
const GOLDEN: &str = "Tests/Fixtures/agent-manifests/expected.json";

fn repo_root() -> PathBuf {
    // `CARGO_MANIFEST_DIR` is `<repo>/termiod`.
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("termiod sits inside the repo")
        .to_path_buf()
}

/// Every manifest both parsers read, as repo-relative paths, in a stable order.
fn manifest_paths() -> Vec<String> {
    let root = repo_root();
    let mut paths = vec![BUNDLED[0].to_string()];
    for directory in [BUNDLED[1], CASES] {
        let mut names: Vec<String> = std::fs::read_dir(root.join(directory))
            .unwrap_or_else(|e| panic!("reading {directory}: {e}"))
            .filter_map(|entry| entry.ok())
            .filter_map(|entry| entry.file_name().to_str().map(str::to_string))
            .filter(|name| name.to_lowercase().ends_with(".json"))
            .collect();
        names.sort();
        paths.extend(names.into_iter().map(|name| format!("{directory}/{name}")));
    }
    paths
}

fn record(path: &str) -> Value {
    let bytes = std::fs::read(repo_root().join(path)).unwrap_or_else(|e| panic!("{path}: {e}"));
    match AgentManifest::parse(&bytes).and_then(|manifest| manifest.definition()) {
        Ok(definition) => json!({
            "file": path,
            "result": "ok",
            "definition": describe(&definition),
        }),
        Err(ManifestError::Invalid(message)) => json!({
            "file": path,
            "result": "invalid",
            "message": message,
        }),
        // The wording of a decode failure is each language's own; that it *is*
        // one is the part both must agree on.
        Err(ManifestError::Malformed(_)) => json!({
            "file": path,
            "result": "malformed",
        }),
    }
}

fn describe(agent: &AgentDefinition) -> Value {
    json!({
        "id": agent.id,
        "order": agent.order,
        "displayName": agent.display_name,
        "command": agent.command,
        "permissionBypassFlag": agent.permission_bypass_flag,
        "wireName": agent.wire_name,
        "installURL": agent.install_url,
        "skillDir": agent.skill_dir,
        "configHome": agent.config_home.as_ref().map(|home| json!({
            "env": home.env,
            "path": home.path,
        })),
        "emitsProgressStatus": agent.emits_progress_status,
        "tintHex": agent.tint_hex,
        "icon": match &agent.icon {
            IconReference::Vector(name) => format!("vector:{name}"),
            IconReference::Symbol(name) => format!("symbol:{name}"),
            IconReference::Asset(_) | IconReference::Path(_) => "image".to_string(),
            IconReference::TerminalGlyph => "terminalGlyph".to_string(),
        },
        "resume": {
            "create": agent.resume.create,
            "resume": agent.resume.resume,
            "seed": agent.resume.seed,
            "store": agent.resume.store.as_ref().map(|store| json!({
                "root": store.root,
                "isDirectory": store.is_directory,
                "name": store.name,
                "transcriptName": store.transcript_name,
            })),
            "discover": agent.resume.discover.as_ref().map(|discover| json!({
                "root": discover.root,
                "format": discover.format.as_str(),
                "id": discover.id,
                "cwd": discover.cwd,
            })),
        },
        "statusRules": agent.status_rules.as_ref().map(|rules| json!({
            "working": rules.working,
            "attention": rules.attention,
        })),
        "titleRules": agent.title_rules.as_ref().map(|rules| json!({
            "working": rules.working,
            "attention": rules.attention,
        })),
        "hooks": agent.hooks.as_ref().map(|hooks| json!({
            "type": hooks.hook_type.as_str(),
            "file": hooks.file,
            "directory": hooks.directory,
            "dialect": hooks.dialect.as_str(),
            "capturesTranscript": hooks.captures_transcript,
            "conversation": hooks.conversation,
            "tool": hooks.tool,
            "promptTitle": hooks.prompt_title,
            "events": hooks.events.iter().map(|event| json!({
                "name": event.name,
                "state": event.state,
                "matcher": event.matcher,
            })).collect::<Vec<_>>(),
        })),
    })
}

#[test]
fn agent_manifest_fixture_matches_the_golden_record() {
    let actual: Vec<Value> = manifest_paths().iter().map(|path| record(path)).collect();
    let golden = repo_root().join(GOLDEN);

    if std::env::var_os("UPDATE_AGENT_MANIFEST_FIXTURE").is_some() {
        let mut text = serde_json::to_string_pretty(&actual).expect("serializes");
        text.push('\n');
        std::fs::write(&golden, text).expect("golden written");
        return;
    }

    let expected: Vec<Value> = serde_json::from_slice(
        &std::fs::read(&golden).unwrap_or_else(|e| panic!("{}: {e}", golden.display())),
    )
    .expect("the golden record is JSON");

    // Compare file by file, so a failure names the manifest rather than dumping
    // the whole roster.
    assert_eq!(
        actual.len(),
        expected.len(),
        "the golden record covers {} manifests but {} were read — regenerate it \
         with UPDATE_AGENT_MANIFEST_FIXTURE=1",
        expected.len(),
        actual.len()
    );
    for (actual, expected) in actual.iter().zip(expected.iter()) {
        assert_eq!(
            actual,
            expected,
            "{} parses differently from the golden record",
            actual["file"].as_str().unwrap_or("?")
        );
    }
}
