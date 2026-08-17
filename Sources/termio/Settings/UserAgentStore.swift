import AppKit
import Foundation

/// Creates, opens and deletes user agent manifests
/// (`~/.termio[-dev]/config/agents/<id>.json`).
///
/// Custom agents are authored in the manifest itself rather than in a Settings
/// form: the file models status regexes, hooks and resume, and a sheet that only
/// covered name and command would teach the wrong ceiling. Settings seeds a valid
/// starter manifest and hands the file to the user's editor.
enum UserAgentStore {
    /// Written into the seed file so the editor window says where the rest of the
    /// keys are documented.
    private static let referenceURL = "https://termio.sh/docs/custom-agents"

    static func file(for id: String) -> URL {
        AgentCatalog.userAgentsDirectory.appendingPathComponent("\(id).json")
    }

    /// Writes a starter manifest under a fresh id and returns it. The seeded
    /// command is a placeholder, so the agent appears in the list right away
    /// carrying the "not on your PATH" hint until the file names a real CLI.
    @discardableResult
    static func createTemplate() throws -> (id: String, file: URL) {
        let name = "My Agent"
        let id = uniqueID(for: name)
        let directory = AgentCatalog.userAgentsDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let manifest = """
            {
              "id": "\(id)",
              "name": "\(name)",
              "command": "\(id)",
              "icon": { "symbol": "sparkles" },
              "//": "Icons, live status, hooks, skills and resume are all set here — \(referenceURL)"
            }

            """
        let url = file(for: id)
        try Data(manifest.utf8).write(to: url, options: .atomic)
        return (id, url)
    }

    /// Opens the manifest in whatever the user edits JSON with. Falls back to the
    /// folder when the file was renamed by hand out from under the catalog.
    static func open(id: String) {
        let url = file(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(AgentCatalog.userAgentsDirectory)
        }
    }

    static func reveal(id: String) {
        let url = file(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(AgentCatalog.userAgentsDirectory)
        }
    }

    static func delete(id: String) throws {
        try FileManager.default.removeItem(at: file(for: id))
    }

    /// A filename-safe slug from the display name, suffixed until it collides with
    /// no known agent id (bundled or user).
    private static func uniqueID(for name: String) -> String {
        let allowed = CharacterSet.alphanumerics
        var slug = name.lowercased()
            .map { character -> Character in
                character.unicodeScalars.allSatisfy(allowed.contains) ? character : "-"
            }
            .reduce(into: "") { partial, character in
                // Collapse runs of separators so "My  Agent!" → "my-agent".
                if character == "-" && partial.hasSuffix("-") { return }
                partial.append(character)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.isEmpty { slug = "agent" }
        let taken = Set(AgentDefinition.allCases.map(\.id))
        if !taken.contains(slug) { return slug }
        for counter in 2... where !taken.contains("\(slug)-\(counter)") {
            return "\(slug)-\(counter)"
        }
        fatalError("unreachable: the counter loop always returns")
    }
}
