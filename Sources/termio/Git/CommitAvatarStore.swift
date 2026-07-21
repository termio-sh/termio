import Foundation

/// Resolves commit-author emails to real GitHub avatars for the History rows — the
/// GitHub Desktop treatment. The lookup is GitHub's unauthenticated avatar-by-email
/// CDN endpoint (`avatars.githubusercontent.com/u/e?email=…`), which covers normal
/// emails and the `id+login@users.noreply.github.com` form alike, so one code path
/// serves both. No Gravatar fallback by design: avatars come from GitHub, initials
/// otherwise — no account, no token, and the only data leaving the machine is the
/// author email already public in the repo's history.
///
/// The endpoint answers an *unknown* email with `200` and one shared placeholder
/// image rather than a 404. A real avatar is told apart by fetching that placeholder
/// once per run (via a sentinel address no account can claim) and comparing bytes;
/// placeholder matches are cached as misses so those rows keep their initials.
///
/// Caching is per-launch and in-memory: a repo's history has a handful of distinct
/// authors, so this is a few ~1 KB fetches per run — not worth a disk cache. Fetch
/// failures are also cached as misses for the session; the feature is cosmetic, and
/// an offline launch shouldn't retry per row while scrolling.
actor CommitAvatarStore {
    static let shared = CommitAvatarStore()

    /// Email (lowercased) → avatar image bytes, with `nil` for a known miss.
    private var cache: [String: Data?] = [:]
    private var inFlight: [String: Task<Data?, Never>] = [:]
    private var placeholderTask: Task<Data?, Never>?

    /// The avatar image bytes for a commit author, or `nil` when the email has no
    /// GitHub account (or the network is down). Coalesces concurrent requests for
    /// the same email so a burst of appearing rows costs one fetch per author.
    func imageData(for email: String) async -> Data? {
        let key = email.lowercased()
        if let cached = cache[key] { return cached }
        if let running = inFlight[key] { return await running.value }
        let task = Task { await self.fetch(key) }
        inFlight[key] = task
        let data = await task.value
        cache[key] = data
        inFlight[key] = nil
        return data
    }

    private func fetch(_ email: String) async -> Data? {
        guard email.contains("@"), let url = Self.avatarURL(email),
              let data = await Self.download(url) else { return nil }
        if let placeholder = await placeholder(), data == placeholder { return nil }
        return data
    }

    /// GitHub's shared unknown-email image, fetched lazily once per run using an
    /// address in a reserved domain no account can hold. `nil` (fetch failed) means
    /// real avatars can't be told from the placeholder — but in that case the real
    /// fetches are failing too, so nothing is misclassified in practice.
    private func placeholder() async -> Data? {
        if let placeholderTask { return await placeholderTask.value }
        let task = Task<Data?, Never> {
            guard let url = Self.avatarURL("no-such-user@avatar.invalid") else { return nil }
            return await Self.download(url)
        }
        placeholderTask = task
        return await task.value
    }

    /// `s=64` covers the 15 pt row circle on a 3× display with headroom.
    private static func avatarURL(_ email: String) -> URL? {
        var components = URLComponents(string: "https://avatars.githubusercontent.com/u/e")
        components?.queryItems = [
            URLQueryItem(name: "email", value: email),
            URLQueryItem(name: "s", value: "64"),
        ]
        return components?.url
    }

    private static func download(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty
        else { return nil }
        return data
    }
}
