import Foundation
import Security

// MARK: - GitHub connection (OAuth Device Flow)

/// The GitHub connection for the Issues pane: an OAuth Device Flow sign-in and
/// a Keychain-held token. Device Flow is the one OAuth shape an open-source app
/// can ship — it needs only this public client id, no secret and no callback
/// server. The token asks for `repo` scope so the write milestone (issue #100)
/// won't need a re-auth.
enum GitHubIssueAuth {
    /// The termio OAuth App's public client id (owned by the termio-sh org,
    /// "Enable Device Flow" checked). Public by design — device flow needs no
    /// secret. Overridable via the environment for testing against another app.
    static var clientID: String {
        ProcessInfo.processInfo.environment["TERMIO_GITHUB_CLIENT_ID"]
            ?? "Ov23lipSynmaEBOQR1cM"
    }

    /// The user's connections page for this OAuth app — where org access is
    /// granted. A 403 on a private repo is usually an org that hasn't authorized
    /// termio, and reconnecting alone won't fix it; the grant happens here.
    static var settingsURL: URL {
        URL(string: "https://github.com/settings/connections/applications/\(clientID)")!
    }

    // MARK: Keychain

    private static let service = "sh.termio.app.issues"
    private static let account = "github"

    /// The stored token, or `nil` when the user never connected (or disconnected).
    static func storedToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func store(token: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(token.utf8)
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            Log.issues.error("keychain store failed: \(status)")
        }
    }

    static func deleteToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: Device flow

    struct DeviceCode: Sendable {
        /// The 8-character code the user types at github.com/login/device.
        let userCode: String
        let verificationURL: URL
        /// Opaque code we poll the token endpoint with.
        fileprivate let deviceCode: String
        /// Server-mandated seconds between polls.
        fileprivate let interval: Int
        fileprivate let expiresAt: Date
    }

    enum DeviceFlowError: LocalizedError {
        case denied
        case expired
        case network(String)

        var errorDescription: String? {
            switch self {
            case .denied: return "The sign-in was declined on github.com."
            case .expired: return "The code expired before it was entered. Try connecting again."
            case .network(let message): return message
            }
        }
    }

    /// Step 1: ask GitHub for a user code to show (and open the verification page).
    static func requestDeviceCode() async throws -> DeviceCode {
        let body = "client_id=\(clientID)&scope=repo"
        let json = try await postForm(
            url: URL(string: "https://github.com/login/device/code")!, body: body)
        guard let userCode = json["user_code"] as? String,
              let device = json["device_code"] as? String,
              let uri = json["verification_uri"] as? String,
              let url = URL(string: uri)
        else {
            let message = (json["error_description"] as? String) ?? "GitHub returned an unexpected reply."
            throw DeviceFlowError.network(message)
        }
        let interval = json["interval"] as? Int ?? 5
        let expiresIn = json["expires_in"] as? Int ?? 900
        return DeviceCode(
            userCode: userCode,
            verificationURL: url,
            deviceCode: device,
            interval: interval,
            expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn))
        )
    }

    /// Step 2: poll until the user approves in the browser; returns the token.
    /// Honors GitHub's pacing (`interval`, `slow_down`) and gives up at expiry.
    static func waitForToken(_ code: DeviceCode) async throws -> String {
        var interval = max(code.interval, 5)
        let body = "client_id=\(clientID)&device_code=\(code.deviceCode)"
            + "&grant_type=urn:ietf:params:oauth:grant-type:device_code"
        while Date() < code.expiresAt {
            try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            let json = try await postForm(
                url: URL(string: "https://github.com/login/oauth/access_token")!, body: body)
            if let token = json["access_token"] as? String { return token }
            switch json["error"] as? String {
            case "authorization_pending": continue
            case "slow_down": interval += 5
            case "access_denied": throw DeviceFlowError.denied
            case "expired_token": throw DeviceFlowError.expired
            default:
                let message = (json["error_description"] as? String) ?? "GitHub returned an unexpected reply."
                throw DeviceFlowError.network(message)
            }
        }
        throw DeviceFlowError.expired
    }

    private static func postForm(url: URL, body: String) async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        } catch let error as DeviceFlowError {
            throw error
        } catch {
            throw DeviceFlowError.network(error.localizedDescription)
        }
    }
}
