import XCTest
@testable import termio

/// The termio skill exists in three places: the app's bundled resource
/// (`Sources/termio/Resources/skills/termio/SKILL.md`, what
/// `SessionSkillInstaller` writes into each agent's skills directory), the
/// repo-root `skills/termio/SKILL.md` (the layout `npx skills add` and
/// `gh skill` discover for installs straight from GitHub), and the published
/// copy at `web/landing/public/skill.md` (https://termio.sh/skill.md). Nothing
/// at runtime ties them together, so this is the only thing that stops an edit
/// to one from silently drifting the others.
final class SessionSkillInstallerTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // termioTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
    }

    func testPublishedSkillMatchesInstalledSkill() throws {
        let source = repoRoot.appendingPathComponent(
            "Sources/termio/Resources/skills/termio/SKILL.md")
        let canonical = try String(contentsOf: source, encoding: .utf8)
        for mirror in ["skills/termio/SKILL.md", "web/landing/public/skill.md"] {
            XCTAssertEqual(
                try String(contentsOf: repoRoot.appendingPathComponent(mirror), encoding: .utf8),
                canonical,
                "\(mirror) must stay identical to the skill the app installs — update all copies together"
            )
        }
    }

    /// Exercises the resource-bundle lookup the installer relies on: a wrong
    /// `.copy` path or a renamed file would otherwise only surface as a silent
    /// per-target install failure at launch.
    func testBundledSkillResolves() throws {
        let skill = try XCTUnwrap(SessionSkillInstaller.skill)
        XCTAssertTrue(skill.hasPrefix("---\nname: termio\n"))
        XCTAssertTrue(skill.hasSuffix("\n"))
    }

    /// A manifest's `skills.dir` is the declaration the installer trusts — a user
    /// dropping a custom agent into `~/.termio/config/agents/` gets its skill
    /// installed through the same field, no code change.
    func testManifestSkillsDeclaresDirectory() throws {
        let json = """
        { "id": "custom", "name": "Custom", "skills": { "dir": "~/.custom/skills" } }
        """
        let manifest = try JSONDecoder().decode(AgentManifest.self, from: Data(json.utf8))
        XCTAssertEqual(manifest.skills?.dir, "~/.custom/skills")
    }

    /// A declared skills directory resolves to `<dir>/termio/SKILL.md` with `~`
    /// expanded — the only pure logic between the manifest and the file system.
    func testSkillFileURLExpandsTilde() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let url = SessionSkillInstaller.skillFileURL(directory: "~/custom/skills")
        XCTAssertEqual(url.lastPathComponent, "SKILL.md")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "termio")
        XCTAssertTrue(url.path.hasPrefix(home + "/custom/skills/termio/"))
    }

    /// Installation skips agents whose CLI isn't installed — a machine without
    /// Cursor must not grow a `~/.cursor/skills` directory it cannot use. The
    /// predicate is injectable, so this is testable without touching real PATHs.
    func testSkillTargetsSkipUninstalledAgents() throws {
        let bundled = AgentCatalog.shared.bundled.filter { $0.id != "terminal" }
        let all = SessionSkillInstaller.skillTargets(installed: { _ in true })
        let targeted = Set(all.map(\.name))
        for agent in bundled where agent.skillDir != nil {
            XCTAssertTrue(
                targeted.contains(agent.displayName),
                "\(agent.id) should be targeted when its CLI is installed")
        }

        let onlyClaude = SessionSkillInstaller.skillTargets(installed: { $0.id == "claudeCode" })
        XCTAssertEqual(onlyClaude.map(\.name), ["Claude Code"])

        XCTAssertTrue(SessionSkillInstaller.skillTargets(installed: { _ in false }).isEmpty)

        // Uninstall sweeps every declared directory regardless of what's installed,
        // so a skill left behind by an agent removed later still gets cleaned.
        let sweep = SessionSkillInstaller.allKnownSkillTargets
        XCTAssertGreaterThanOrEqual(sweep.count, bundled.filter { $0.skillDir != nil }.count)
    }

    /// The bundled manifests drive the installed surface: every agent declares its
    /// skills directory, verified against each vendor's documented location so a
    /// typo in a manifest can't silently install into a directory the agent never
    /// reads.
    func testBundledSkillDeclarationsMatchCatalog() throws {
        let catalog = AgentCatalog.shared
        let expected: [String: String] = [
            "claudeCode": "~/.claude/skills",
            "codex": "~/.codex/skills",
            "cursor": "~/.cursor/skills",
            "grok": "~/.grok/skills",
            "opencode": "~/.config/opencode/skills",
            "pi": "~/.pi/agent/skills",
            "amp": "~/.config/agents/skills",
            "antigravity": "~/.gemini/antigravity/skills",
            "hermes": "~/.hermes/skills",
            "kimi": "~/.kimi-code/skills",
        ]
        for (id, directory) in expected {
            let definition = catalog.definition(for: id)
            XCTAssertEqual(
                definition.skillDir, directory,
                "\(id) must declare skills at its vendor-documented directory")
        }
        // Every bundled coding agent declares skills — none should be skipped.
        let undeclared = catalog.bundled.filter { $0.skillDir == nil && $0.id != "terminal" }
        XCTAssertTrue(
            undeclared.isEmpty,
            "agents without a skills declaration: \(undeclared.map(\.id))")
    }
}
