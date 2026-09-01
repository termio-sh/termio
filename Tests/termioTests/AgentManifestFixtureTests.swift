import XCTest
@testable import termio

/// The Stage 1 gate of `docs/design/20260825-agent-integration-moves-to-termiod.md`.
///
/// The agent manifest schema now has two parsers: this one and
/// `termiod/src/agent/manifest.rs`. The format is user-extensible — a user drops
/// a JSON file into `~/.termio/config/agents` and it becomes a real agent — so a
/// manifest the two read differently is a bug that shows up as "my agent is in
/// the list but never gets hooks", with nothing on screen to say why.
///
/// **This is a permanent contract, not migration scaffolding.** Swift did not
/// stop parsing manifests when the installers moved into the daemon — it
/// stopped *writing* from them. This side still renders the roster, so it still
/// needs every name, icon and command; the daemon needs every path, dialect and
/// event. Two live parsers, one format, for as long as both exist.
///
/// Both parsers read the same manifests and both are asserted against one golden
/// record, `Tests/Fixtures/agent-manifests/expected.json`. Only the Rust side
/// regenerates it (`UPDATE_AGENT_MANIFEST_FIXTURE=1 cargo test agent_manifest_fixture`);
/// this side only ever checks, so a disagreement makes you decide which parser
/// is wrong instead of letting either overwrite the question.
///
/// Two fields are compared loosely, and the reasons are recorded in
/// `termiod/src/agent/fixture.rs`: a bundled icon asset cannot be verified by a
/// daemon that has no app bundle, so the record carries the icon's *kind*; and
/// status patterns are compared as source, because the daemon never compiles
/// them.
final class AgentManifestFixtureTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // termioTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
    }

    func testEveryManifestParsesTheWayTheDaemonParsesIt() throws {
        let golden = try JSONSerialization.jsonObject(
            with: Data(contentsOf: repoRoot.appendingPathComponent(
                "Tests/Fixtures/agent-manifests/expected.json")))
        let expected = try XCTUnwrap(golden as? [[String: Any]])
        let actual = try manifestPaths().map(record(for:))

        XCTAssertEqual(
            actual.count, expected.count,
            """
            the golden record covers \(expected.count) manifests but \(actual.count) were read — \
            regenerate it with UPDATE_AGENT_MANIFEST_FIXTURE=1 cargo test agent_manifest_fixture
            """)
        for (actual, expected) in zip(actual, expected) {
            let file = actual["file"] as? String ?? "?"
            XCTAssertTrue(
                NSDictionary(dictionary: actual).isEqual(to: expected),
                """
                \(file) parses differently from the golden record.
                Swift:  \(actual)
                Golden: \(expected)
                """)
        }
    }

    /// Every manifest both parsers read, as repo-relative paths, in the same
    /// order the daemon's fixture walks them.
    private func manifestPaths() throws -> [String] {
        var paths = ["Sources/termio/Resources/terminal.json"]
        for directory in ["Sources/termio/Resources/agents",
                          "Tests/Fixtures/agent-manifests/cases"] {
            let names = try FileManager.default
                .contentsOfDirectory(atPath: repoRoot.appendingPathComponent(directory).path)
                .filter { $0.lowercased().hasSuffix(".json") }
                .sorted()
            paths.append(contentsOf: names.map { "\(directory)/\($0)" })
        }
        return paths
    }

    private func record(for path: String) throws -> [String: Any] {
        let url = repoRoot.appendingPathComponent(path)
        let data = try Data(contentsOf: url)
        do {
            let manifest = try JSONDecoder().decode(AgentManifest.self, from: data)
            let definition = try manifest.definition(
                directory: url.deletingLastPathComponent(),
                resourceBundle: Bundle.termioResources)
            return ["file": path, "result": "ok", "definition": describe(definition)]
        } catch let error as AgentManifest.ManifestError {
            guard case .invalid(let message) = error else {
                return ["file": path, "result": "malformed"]
            }
            return ["file": path, "result": "invalid", "message": message]
        } catch {
            // The wording of a decode failure is each language's own; that it
            // *is* one is the part both must agree on.
            return ["file": path, "result": "malformed"]
        }
    }

    private func describe(_ agent: AgentDefinition) -> [String: Any] {
        [
            "id": agent.id,
            "order": agent.order,
            "displayName": agent.displayName,
            "command": value(agent.command),
            "permissionBypassFlag": value(agent.permissionBypassFlag),
            "wireName": agent.wireName,
            "installURL": value(agent.installURL?.absoluteString),
            "skillDir": value(agent.skillDir),
            "configHome": value(agent.configHome.map { home in
                ["env": home.env, "path": home.path] as [String: Any]
            }),
            "emitsProgressStatus": agent.emitsProgressStatus,
            "tintHex": value(agent.tintHex),
            "icon": describe(agent.icon),
            "resume": describe(agent.resumeSpec),
            "statusRules": value(agent.statusRules.map(describe)),
            "titleRules": value(agent.titleRules.map(describe)),
            "hooks": value(agent.hookSpec.map(describe)),
        ]
    }

    private func describe(_ icon: AgentIcon) -> String {
        switch icon {
        case .vector(let logo):
            switch logo {
            case .claude: return "vector:claude"
            case .codex: return "vector:codex"
            case .grok: return "vector:grok"
            }
        case .symbol(let name): return "symbol:\(name)"
        // A bundled asset and a relative path both resolve to a file URL here,
        // and the daemon cannot resolve either — the kind is what both can say.
        case .image: return "image"
        case .terminalGlyph: return "terminalGlyph"
        case .huge: return "huge"
        }
    }

    private func describe(_ resume: AgentDefinition.ResumeSpec) -> [String: Any] {
        [
            "create": value(resume.create),
            "resume": value(resume.resume),
            "seed": value(resume.seed),
            "store": value(resume.store.map { store in
                [
                    "root": store.root,
                    "isDirectory": store.isDirectory,
                    "name": store.name,
                    "transcriptName": value(store.transcriptName),
                ] as [String: Any]
            }),
            "discover": value(resume.discover.map { discover in
                [
                    "root": discover.root,
                    "format": discover.format.rawValue,
                    "id": discover.id,
                    "cwd": discover.cwd,
                ] as [String: Any]
            }),
        ]
    }

    private func describe(_ rules: AgentStatusRules) -> [String: Any] {
        ["working": rules.working, "attention": rules.attention]
    }

    private func describe(_ hooks: AgentHookSpec) -> [String: Any] {
        [
            "type": hooks.type.rawValue,
            "file": value(hooks.file),
            "directory": value(hooks.directory),
            "dialect": name(of: hooks.dialect),
            "capturesTranscript": hooks.capturesTranscript,
            "conversation": value(hooks.conversation),
            "tool": value(hooks.tool),
            "promptTitle": value(hooks.promptTitle),
            "events": hooks.events.map { event in
                ["name": event.name, "state": event.state, "matcher": value(event.matcher)]
                    as [String: Any]
            },
        ]
    }

    private func name(of dialect: HookDialect) -> String {
        switch dialect {
        case .claudeNested: return "claudeNested"
        case .cursorFlat: return "cursorFlat"
        case .copilotFlat: return "copilotFlat"
        case .kimiTOML: return "kimiTOML"
        case .openCodePlugin: return "openCodePlugin"
        case .piPlugin: return "piPlugin"
        case .ampPlugin: return "ampPlugin"
        case .clineScripts: return "clineScripts"
        }
    }

    private func value(_ any: Any?) -> Any { any ?? NSNull() }
}
