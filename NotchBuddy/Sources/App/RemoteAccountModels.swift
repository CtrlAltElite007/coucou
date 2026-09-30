import Foundation

/// Account data returned by the remote harness. OAuth tokens never cross this interface.
struct RemoteAccountSnapshot: Decodable, Equatable, Sendable {
    struct Account: Decodable, Equatable, Sendable {
        let type: String
        let email: String?
        let planType: String?
    }
    let account: Account?
    let requiresOpenaiAuth: Bool

    var ready: Bool { !requiresOpenaiAuth || account != nil }
    var isChatGPT: Bool { account?.type == "chatgpt" }
    var label: String {
        guard let account else {
            return requiresOpenaiAuth ? "Sign in to start remote work" : "Remote provider configured"
        }
        switch account.type {
        case "chatgpt":
            return [account.email ?? "ChatGPT account", account.planType?.capitalized]
                .compactMap { $0 }.joined(separator: " · ")
        case "apiKey": return "Remote API key configured"
        case "amazonBedrock": return "Remote Amazon Bedrock configured"
        default: return "Remote account configured"
        }
    }
}

struct RemoteDeviceLogin: Decodable, Equatable, Sendable {
    let type: String
    let loginId: String
    let verificationUrl: String
    let userCode: String

    var verificationURL: URL? {
        guard type == "chatgptDeviceCode", !loginId.isEmpty, loginId.count <= 256,
              (4...64).contains(userCode.count),
              userCode.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-").contains($0)
              }),
              let url = URL(string: verificationUrl),
              url.scheme == "https", url.host == "auth.openai.com",
              url.path == "/codex/device", url.port == nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        return url
    }
}

/// Handles a completion arriving before the login/start response, and ignores other clients' logins.
struct RemoteLoginState: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case succeeded
        case failed(String)
    }
    private(set) var starting = false
    private(set) var challenge: RemoteDeviceLogin?
    private(set) var outcome: Outcome?
    private var early: [String: Outcome] = [:]

    mutating func begin() {
        self = RemoteLoginState()
        starting = true
    }

    mutating func receive(_ response: RemoteDeviceLogin) throws {
        guard starting else { return }
        guard response.verificationURL != nil else {
            throw WorkError(message: "The remote host returned an unsupported sign-in link. Use its own login client.")
        }
        starting = false
        if let result = early[response.loginId] { outcome = result }
        else { challenge = response }
        early.removeAll()
    }

    @discardableResult
    mutating func complete(id: String, success: Bool, error: String?) -> Bool {
        let result: Outcome = success ? .succeeded : .failed(error ?? "Sign-in was cancelled or expired. Try again.")
        if starting {
            if early.count < 8 { early[id] = result }
            return false
        }
        guard challenge?.loginId == id else { return false }
        challenge = nil
        outcome = result
        return true
    }
}

struct RemoteUsageWindow: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let usedPercent: Double
    let durationMinutes: Int?
    let resetsAt: Date?
    var remainingPercent: Double { max(0, min(100, 100 - usedPercent)) }

    static func parse(_ object: [String: Any]) -> [RemoteUsageWindow] {
        let buckets: [String: [String: Any]]
        if let many = object["rateLimitsByLimitId"] as? [String: [String: Any]] {
            buckets = many
        } else if let one = object["rateLimits"] as? [String: Any] {
            buckets = [one["limitId"] as? String ?? "account": one]
        } else { return [] }
        return buckets.keys.sorted().flatMap { key -> [RemoteUsageWindow] in
            let bucket = buckets[key] ?? [:]
            return ["primary", "secondary"].compactMap { windowKey in
                guard let window = bucket[windowKey] as? [String: Any],
                      let used = window["usedPercent"] as? Double, used.isFinite else { return nil }
                let minutes = window["windowDurationMins"] as? Int
                let reset = window["resetsAt"] as? Double
                let label = (bucket["limitName"] as? String ?? key) + " · " + windowKey
                return RemoteUsageWindow(id: "\(key):\(windowKey)", label: label, usedPercent: used,
                    durationMinutes: minutes,
                    resetsAt: reset.flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil })
            }
        }
    }
}
