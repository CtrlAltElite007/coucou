import Foundation

enum WorkProviderID: String, Codable, CaseIterable, Sendable {
    case codex, claude, github
    var title: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .github: return "GitHub Actions"
        }
    }
}

enum WorkStatus: String, Codable, Sendable {
    case unknown, idle, queued, running, needsApproval, succeeded, failed, cancelled
    var label: String {
        switch self {
        case .unknown: return "Status unknown"
        case .idle: return "Idle"
        case .queued: return "Queued"
        case .running: return "Running"
        case .needsApproval: return "Needs attention"
        case .succeeded: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }
    var isAlert: Bool { self == .needsApproval || self == .succeeded || self == .failed }
    static func github(status: String, conclusion: String?) -> Self {
        if status == "completed" {
            switch conclusion {
            case "success": return .succeeded
            case "failure", "timed_out", "startup_failure": return .failed
            case "cancelled": return .cancelled
            case "action_required": return .needsApproval
            // Neutral/skipped are not successful executions.
            default: return .unknown
            }
        }
        switch status {
        case "queued", "requested", "pending": return .queued
        case "waiting", "action_required": return .needsApproval
        case "in_progress": return .running
        default: return .unknown
        }
    }
    static func thread(type: String, flags: [String] = []) -> Self {
        switch type {
        case "active": return flags.contains("waitingOnApproval") || flags.contains("waitingOnUserInput") ? .needsApproval : .running
        case "idle": return .idle
        case "systemError": return .failed
        default: return .unknown
        }
    }
}

struct WorkJob: Identifiable, Equatable, Sendable {
    let provider: WorkProviderID
    let remoteID: String
    var title: String
    var repository: String
    var branch: String = ""
    var status: WorkStatus
    var detail: String = ""
    var url: URL? = nil
    var updatedAt: Date = .now
    var stale: Bool = false
    var id: String { "\(provider.rawValue):\(remoteID)" }
}

struct WorkEvent: Sendable {
    let job: WorkJob
    var notify: Bool = true
}

/// IDs must retain their JSON type: numeric 1 and string "1" are different requests.
enum WorkRequestID: Hashable, Codable, Sendable {
    case number(Int)
    case text(String)
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let number = try? value.decode(Int.self) { self = .number(number) }
        else { self = .text(try value.decode(String.self)) }
    }
    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .number(let number): try value.encode(number)
        case .text(let text): try value.encode(text)
        }
    }
    var key: String {
        switch self {
        case .number(let value): return "n:\(value)"
        case .text(let value): return "s:\(value)"
        }
    }
}

struct WorkApproval: Identifiable, Sendable {
    let requestID: WorkRequestID
    let connectionID: UUID
    let threadID: String
    let turnID: String
    let title: String
    let detail: String
    let canAccept: Bool
    let canDecline: Bool
    var sending = false
    var id: String { "\(connectionID):\(requestID.key)" }
}

struct WorkCapabilities: OptionSet, Sendable {
    let rawValue: Int
    static let status = Self(rawValue: 1 << 0)
    static let handoff = Self(rawValue: 1 << 1)
    static let approvals = Self(rawValue: 1 << 2)
}

struct RemoteWorkRequest: Sendable {
    let prompt: String
    let repository: String
    let cwd: String
}

@MainActor
protocol WorkProvider: AnyObject {
    var providerID: WorkProviderID { get }
    var capabilities: WorkCapabilities { get }
    func refresh() async throws
    func handoff(_ request: RemoteWorkRequest) async throws -> String
}

struct WorkError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

enum WorkValidation {
    static func repository(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." &&
                  $0.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil }) else { return nil }
        return value
    }

    static func remoteURL(_ input: String) -> URL? {
        guard let url = URL(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "wss", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        return url
    }

    static func githubURL(_ input: String) -> URL? {
        guard let url = URL(string: input), url.scheme == "https", url.host == "github.com",
              url.user == nil, url.password == nil, url.port == nil else { return nil }
        return url
    }

    static func remoteDirectory(_ input: String) -> Bool {
        input.hasPrefix("/") && !input.contains("\n") && !input.contains("\0")
    }

    static func handoffText(prompt: String, repository: String) -> String {
        repository.isEmpty ? prompt : "Repository: \(repository)\n\n\(prompt)"
    }
}

/// Pure reducer shared by all event sources. Snapshots never turn unknown into success.
struct WorkLedger {
    private(set) var jobs: [WorkJob] = []

    @discardableResult
    mutating func apply(_ event: WorkEvent) -> Bool {
        let old = jobs.first { $0.id == event.job.id }
        if let old, old.updatedAt > event.job.updatedAt { return false }
        jobs.removeAll { $0.id == event.job.id }
        jobs.append(event.job)
        jobs.sort { $0.updatedAt > $1.updatedAt }
        jobs = Array(jobs.prefix(200))
        return event.notify && event.job.status.isAlert &&
            old?.status != event.job.status
    }

    mutating func markStale(provider: WorkProviderID) {
        for index in jobs.indices where jobs[index].provider == provider {
            jobs[index].stale = true
        }
    }

    mutating func remove(provider: WorkProviderID) {
        jobs.removeAll { $0.provider == provider }
    }
}
