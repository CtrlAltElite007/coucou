import Foundation
#if canImport(Combine)
import Combine
#else
// Linux cloud compiler: only observable storage is replaced; provider logic is unchanged.
protocol ObservableObject: AnyObject {}
@propertyWrapper struct Published<Value> {
    var wrappedValue: Value
    init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
#endif

// No OS notifications, real Keychain, UI, sockets or paid model calls in these fixtures.
@MainActor final class KeychainStore {
    static let shared = KeychainStore()
    func get(_ key: String) -> String? { nil }
}
struct ChatMessage {
    enum Role { case assistant }
    let role: Role
    let content: String
}
@MainActor final class AppState {
    static let shared = AppState()
    var promptContext: PromptContext?
    var stateOverride: Int?
    var chatHistory: [ChatMessage] = []
}
@MainActor final class WorkStore {
    static let shared = WorkStore()
    var approvals: [WorkApproval] = []
    var notices: [String] = []
    private var ledger = WorkLedger()
    var jobs: [WorkJob] { ledger.jobs }
    func receive(_ event: WorkEvent) { ledger.apply(event) }
    func stale(_ provider: WorkProviderID) { ledger.markStale(provider: provider) }
    func clear(_ provider: WorkProviderID) { ledger.remove(provider: provider) }
    func notice(_ message: String) { notices.append(message) }
}

struct PromptContext {}
@MainActor final class ClaudeService {
    static let shared = ClaudeService()
    func clearConversation() {}
    func chat(query: String, context: PromptContext?, state: AppState) async {}
}

@MainActor final class DeferredRemoteChat: RemoteChatClient {
    private var pending: CheckedContinuation<Void, Error>?
    private var started: CheckedContinuation<Void, Never>?
    private(set) var calls = 0
    func resetChat() {}
    func chat(query: String) async throws {
        calls += 1
        try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            started?.resume()
            started = nil
        }
    }
    func waitUntilStarted() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func fail() {
        let callback = pending
        pending = nil
        callback?.resume(throwing: WorkError(message: "Delayed failure"))
    }
}

@main
struct RemoteProviderTests {
    @MainActor
    static func main() async throws {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ name: String) {
            precondition(value(), "Failed: \(name)")
            checks += 1
        }
        let remote = CodexRemoteProvider()
        let store = WorkStore.shared
        func feed(_ method: String, _ params: [String: Any], id: Any? = nil) async throws {
            var message: [String: Any] = ["method": method, "params": params]
            if let id { message["id"] = id }
            try await remote.receive(JSONSerialization.data(withJSONObject: message))
        }

        expect(!remote.readyForWork, "a new client is not authenticated")
        do {
            _ = try await remote.handoff(RemoteWorkRequest(prompt: "test", repository: "a/b", cwd: "/repo"))
            preconditionFailure("Disconnected handoff must fail")
        } catch { checks += 1 }
        do {
            try await remote.chat(query: "test")
            preconditionFailure("Disconnected chat must fail")
        } catch { checks += 1 }

        try await feed("thread/started", ["thread": [
            "id": "thread-a", "name": "Fix build", "cwd": "/repo",
            "gitInfo": ["branch": "main", "originUrl": "https://github.com/a/b"],
            "status": ["type": "idle"]
        ]])
        expect(store.jobs.count == 1, "thread created")
        expect(store.jobs[0].branch == "main" && store.jobs[0].repository == "https://github.com/a/b", "host repo metadata")
        try await feed("turn/started", ["threadId": "thread-a", "turn": ["id": "turn-a"]])
        expect(store.jobs[0].status == .running, "turn starts running")

        try await feed("item/commandExecution/requestApproval", [
            "threadId": "thread-a", "turnId": "turn-a", "itemId": "command-a",
            "command": "swift test", "cwd": "/repo", "availableDecisions": ["accept", "decline"]
        ], id: 1)
        expect(store.approvals.count == 1 && store.approvals[0].canAccept, "command preview allows one-time review")
        expect(store.jobs[0].status == .needsApproval, "approval changes job status")
        try await feed("item/fileChange/requestApproval", [
            "threadId": "thread-a", "turnId": "turn-a", "itemId": "file-a"
        ], id: "1")
        expect(store.approvals.count == 2, "numeric and string requests remain independent")
        expect(store.approvals[1].canAccept == false, "missing file preview cannot be accepted")
        try await feed("serverRequest/resolved", ["requestId": 1])
        expect(store.approvals.count == 1 && store.approvals[0].requestID == .text("1"), "ack resolves only matching typed ID")

        try await feed("item/started", [
            "threadId": "thread-a", "turnId": "turn-a",
            "item": ["id": "file-b", "type": "fileChange",
                     "changes": [["path": "/repo/a.swift", "diff": "-old\n+new"]]]
        ])
        try await feed("item/fileChange/requestApproval", [
            "threadId": "thread-a", "turnId": "turn-a", "itemId": "file-b"
        ], id: 2)
        expect(store.approvals.last?.canAccept == true, "file changes require the prior item preview")
        expect(store.approvals.last?.detail.contains("+new") == true, "file diff is reviewable")
        try await feed("item/commandExecution/requestApproval", [
            "threadId": "thread-a", "turnId": "turn-a", "itemId": "command-b",
            "command": "test", "availableDecisions": ["decline"]
        ], id: 3)
        expect(store.approvals.last?.canAccept == false && store.approvals.last?.canDecline == true, "server decision restrictions honored")
        try await feed("item/commandExecution/requestApproval", [
            "threadId": "thread-a", "turnId": "turn-a", "itemId": "command-b",
            "command": "test", "availableDecisions": ["decline"]
        ], id: 3)
        expect(store.approvals.count == 3, "duplicate request replaces its queue entry")

        try await feed("item/tool/requestUserInput", ["threadId": "thread-a"], id: 4)
        expect(store.approvals.count == 3 && store.notices.count == 1, "unsupported request does not grant permission")
        try await feed("item/agentMessage/delta", ["threadId": "thread-a", "delta": "partial"])
        expect(store.jobs.count == 1, "unknown notifications do not create extra jobs")
        try await feed("item/completed", [
            "threadId": "thread-a", "item": ["id": "message-a", "type": "agentMessage", "text": "Fixed the build."]
        ])
        expect(store.jobs[0].detail == "Fixed the build.", "completed assistant message recorded")
        try await feed("turn/completed", ["threadId": "thread-a", "turn": ["id": "turn-a", "status": "completed"]])
        expect(store.jobs[0].status == .succeeded && store.approvals.isEmpty, "completion clears pending approvals")
        try await feed("thread/status/changed", ["threadId": "thread-a", "status": ["type": "idle"]])
        expect(store.jobs[0].status == .succeeded, "following idle event preserves completed result")
        try await feed("turn/started", ["threadId": "thread-a", "turn": ["id": "turn-b"]])
        expect(store.jobs[0].status == .running, "new turn replaces terminal status")
        try await feed("turn/completed", ["threadId": "thread-a", "turn": [
            "id": "turn-b", "status": "failed", "error": ["message": "Tool failed"]
        ]])
        expect(store.jobs[0].status == .failed && store.jobs[0].detail == "Tool failed", "failure is not completion")
        try await feed("turn/completed", ["threadId": "thread-a", "turn": ["id": "turn-c", "status": "interrupted"]])
        expect(store.jobs[0].status == .cancelled, "interrupt reported as cancelled")
        remote.disconnect()
        expect(store.jobs[0].stale && store.approvals.isEmpty && !remote.readyForWork, "disconnect invalidates cached state and actions")
        let client = DeferredRemoteChat()
        let assistant = RemoteAssistant(client: client)
        let state = AppState.shared
        let oldReply = Task { await assistant.chat(query: "old", context: nil, state: state) }
        await client.waitUntilStarted()
        assistant.clearConversation()
        state.stateOverride = 42
        client.fail()
        await oldReply.value
        expect(state.chatHistory.isEmpty && state.stateOverride == 42, "old remote failure cannot alter a new conversation")

        let newReply = Task { await assistant.chat(query: "new", context: nil, state: state) }
        await client.waitUntilStarted()
        client.fail()
        await newReply.value
        expect(state.chatHistory.last?.content == "Delayed failure" && state.stateOverride == nil, "current remote failure is displayed")
        let calls = client.calls
        await assistant.chat(query: "file", context: PromptContext(), state: state)
        expect(client.calls == calls && state.chatHistory.last?.content.contains("Clear the attached local context") == true,
               "local attachments are rejected before remote calls")
        print("Passed \(checks) remote provider protocol checks without network access.")
    }
}
