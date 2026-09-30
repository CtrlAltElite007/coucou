import Foundation
#if canImport(Combine)
import Combine
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A client only: the harness, credentials, shell, repository and tools stay on the remote host.
/// WebSocket app-server transport is experimental. No local CLI is spawned.
@MainActor
final class CodexRemoteProvider: ObservableObject, WorkProvider {
    static let shared = CodexRemoteProvider()
    let providerID: WorkProviderID = .codex
    let capabilities: WorkCapabilities = [.status, .handoff, .approvals]
    @Published private(set) var connected = false
    @Published private(set) var connecting = false
    @Published private(set) var statusText = "Not connected"
    @Published private(set) var submitting = false
    @Published private(set) var chatBusy = false
    @Published private(set) var hooksSummary = ""
    @Published private(set) var account: RemoteAccountSnapshot?
    @Published private(set) var accountMessage = "Connect a remote host to check its account."
    @Published private(set) var accountBusy = false
    @Published private(set) var login = RemoteLoginState()
    @Published private(set) var usageWindows: [RemoteUsageWindow] = []
    @Published private(set) var usageMessage = ""
    private var accountRevision = UUID()
    private var loginOperation = UUID()
    var readyForWork: Bool { connected && account?.ready == true && !accountBusy && !login.starting && login.challenge == nil }

    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var receiver: Task<Void, Never>?
    private var connectionID = UUID()
    private var nextID = 0
    private var pending: [WorkRequestID: CheckedContinuation<Data, Error>] = [:]
    private var timeouts: [WorkRequestID: Task<Void, Never>] = [:]
    private var items: [String: String] = [:]
    private var activeTurns: [String: String] = [:]
    private var completedTurns: Set<String> = []
    private var chatThread: String?
    private var chatGeneration = UUID()
    private var deliveredMessages: Set<String> = []
    private var isRefreshing = false

    func connect() async {
        guard !connecting, !connected else { return }
        guard let url = WorkValidation.remoteURL(UserDefaults.standard.string(forKey: "remoteAgentURL") ?? ""),
              let token = KeychainStore.shared.get("remote-agent-token"), !token.isEmpty else {
            statusText = "Save a secure wss:// endpoint and bearer token in Settings."
            return
        }
        disconnect()
        connecting = true
        statusText = "Connecting…"
        let generation = connectionID
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: config, delegate: WorkSessionDelegate(), delegateQueue: nil)
        self.session = session
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 4 * 1024 * 1024
        self.socket = socket
        socket.resume()
        receiver = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    guard let self, self.connectionID == generation else { return }
                    let data: Data
                    switch message {
                    case .string(let text): data = Data(text.utf8)
                    case .data(let value): data = value
                    @unknown default: continue
                    }
                    try await self.receive(data)
                }
            } catch {
                guard let self, self.connectionID == generation else { return }
                self.disconnect(reason: "Connection lost. Remote work may still be running; reconnect to refresh.")
            }
        }
        do {
            _ = try await rpc("initialize", params: [
                "clientInfo": ["name": "coucou", "title": "Coucou", "version": "0.2.0"]
            ])
            try await send(["method": "initialized", "params": [:]])
            guard connectionID == generation else { return }
            connecting = false
            connected = true
            statusText = "Connected to remote host · experimental"
            await refreshAccount()
            try await refresh()
        } catch {
            guard connectionID == generation else { return }
            disconnect(reason: error.localizedDescription)
        }
    }

    func disconnect(reason: String = "Disconnected") {
        connectionID = UUID()
        connected = false
        connecting = false
        statusText = reason
        accountRevision = UUID()
        loginOperation = UUID()
        account = nil
        accountBusy = false
        accountMessage = "Connect a remote host to check its account."
        login = RemoteLoginState()
        usageWindows = []
        usageMessage = ""
        receiver?.cancel()
        receiver = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        let callbacks = Array(pending.values)
        pending.removeAll()
        timeouts.values.forEach { $0.cancel() }
        timeouts.removeAll()
        callbacks.forEach { $0.resume(throwing: WorkError(message: "Disconnected. Request outcome may be unknown; refresh before retrying.")) }
        WorkStore.shared.approvals.removeAll()
        WorkStore.shared.stale(.codex)
        activeTurns.removeAll()
        completedTurns.removeAll()
        items.removeAll()
        resetChat()
    }

    func refreshAccount() async {
        guard connected else { return }
        let generation = connectionID
        let revision = UUID()
        accountRevision = revision
        accountMessage = "Checking remote account…"
        do {
            let result = try await rpc("account/read", params: ["refreshToken": false])
            guard connectionID == generation, accountRevision == revision else { return }
            let snapshot = try JSONDecoder().decode(RemoteAccountSnapshot.self,
                from: JSONSerialization.data(withJSONObject: result))
            account = snapshot
            accountMessage = snapshot.label
            if snapshot.isChatGPT { await refreshUsage() }
            else { usageWindows = []; usageMessage = "" }
        } catch {
            guard connectionID == generation, accountRevision == revision else { return }
            account = nil
            usageWindows = []
            accountMessage = "Account check failed: \(error.localizedDescription)"
        }
    }

    func refreshUsage() async {
        guard connected, account?.isChatGPT == true else { return }
        let generation = connectionID
        let revision = accountRevision
        do {
            let result = try await rpc("account/rateLimits/read", params: [:])
            guard generation == connectionID, revision == accountRevision else { return }
            usageWindows = RemoteUsageWindow.parse(result)
            usageMessage = usageWindows.isEmpty ? "Usage limits are unavailable." : ""
        } catch {
            guard generation == connectionID, revision == accountRevision else { return }
            usageWindows = []
            usageMessage = "Usage limits are unavailable on this host."
        }
    }

    func signIn() async {
        guard connected, !accountBusy, !login.starting, login.challenge == nil,
              account?.requiresOpenaiAuth == true, account?.account == nil else { return }
        let generation = connectionID
        let operation = UUID()
        loginOperation = operation
        login.begin()
        accountBusy = true
        defer { if operation == loginOperation { accountBusy = false } }
        do {
            let result = try await rpc("account/login/start", params: ["type": "chatgptDeviceCode"])
            guard generation == connectionID, operation == loginOperation else { return }
            let response = try JSONDecoder().decode(RemoteDeviceLogin.self,
                from: JSONSerialization.data(withJSONObject: result))
            do { try login.receive(response) }
            catch {
                // Cancel the exact attempt if the host returned an untrusted verification URL.
                _ = try? await rpc("account/login/cancel", params: ["loginId": response.loginId])
                throw error
            }
            if login.outcome != nil { await finishSignIn() }
        } catch {
            guard generation == connectionID, operation == loginOperation else { return }
            login = RemoteLoginState()
            accountMessage = "Sign-in could not start: \(error.localizedDescription)"
        }
    }

    func cancelSignIn() async {
        guard connected, !accountBusy, let challenge = login.challenge else { return }
        let generation = connectionID
        let operation = loginOperation
        accountBusy = true
        defer { if operation == loginOperation { accountBusy = false } }
        do {
            _ = try await rpc("account/login/cancel", params: ["loginId": challenge.loginId])
            guard generation == connectionID, operation == loginOperation else { return }
            login = RemoteLoginState()
            await refreshAccount()
        } catch {
            guard generation == connectionID, operation == loginOperation else { return }
            accountMessage = "Cancellation was not confirmed: \(error.localizedDescription)"
        }
    }

    func signOut() async {
        guard connected, !accountBusy, !submitting, !chatBusy else { return }
        let generation = connectionID
        let operation = UUID()
        loginOperation = operation
        accountBusy = true
        resetChat()
        defer { if operation == loginOperation { accountBusy = false } }
        do {
            _ = try await rpc("account/logout", params: [:])
            guard generation == connectionID, operation == loginOperation else { return }
            login = RemoteLoginState()
            account = nil
            usageWindows = []
            await refreshAccount()
        } catch {
            guard generation == connectionID, operation == loginOperation else { return }
            account = nil
            accountMessage = "Sign-out outcome is unknown. Check the remote account before continuing."
        }
    }

    private func finishSignIn() async {
        guard let outcome = login.outcome else { return }
        let generation = connectionID
        let operation = loginOperation
        switch outcome {
        case .succeeded:
            await refreshAccount()
        case .failed(let reason):
            await refreshAccount()
            guard generation == connectionID, operation == loginOperation else { return }
            accountMessage = "Sign-in did not finish: \(reason)"
        }
    }

    func resetChat() {
        chatGeneration = UUID()
        chatThread = nil
        deliveredMessages.removeAll()
        if chatBusy { AppState.shared.stateOverride = nil }
        chatBusy = false
    }

    func refresh() async throws {
        guard connected, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let generation = connectionID
        let snapshotStarted = Date()
        var cursor: String?
        // Bounded pagination: at most the latest 200 threads in this remote directory.
        for _ in 0..<4 {
            try Task.checkCancellation()
            var params: [String: Any] = [
                "limit": 50, "sortKey": "updated_at",
                "sourceKinds": ["cli", "vscode", "exec", "appServer", "unknown"]
            ]
            let cwd = UserDefaults.standard.string(forKey: "remoteAgentCWD") ?? ""
            if !cwd.isEmpty { params["cwd"] = cwd }
            if let cursor { params["cursor"] = cursor }
            let result = try await rpc("thread/list", params: params)
            guard connectionID == generation else { return }
            for thread in result["data"] as? [[String: Any]] ?? [] {
                if let id = thread["id"] as? String,
                   let existing = WorkStore.shared.jobs.first(where: { $0.provider == .codex && $0.remoteID == id }),
                   existing.updatedAt > snapshotStarted { continue }
                recordThread(thread, notify: false)
            }
            cursor = result["nextCursor"] as? String
            if cursor == nil { break }
        }
    }

    func inspectHooks() async {
        guard connected else { return }
        do {
            let cwd = UserDefaults.standard.string(forKey: "remoteAgentCWD") ?? ""
            let result = try await rpc("hooks/list", params: cwd.isEmpty ? [:] : ["cwds": [cwd]])
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            hooksSummary = String(decoding: data.prefix(32_000), as: UTF8.self)
        } catch {
            hooksSummary = "Hook discovery is unavailable on this remote version: \(error.localizedDescription)"
        }
    }

    func handoff(_ request: RemoteWorkRequest) async throws -> String {
        guard connected else { throw WorkError(message: "Connect a remote host in Cloud Work, or use the browser handoff.") }
        guard readyForWork else { throw WorkError(message: "Check the remote account or sign in with ChatGPT in Cloud Work first.") }
        guard !submitting else { throw WorkError(message: "A handoff is already being submitted.") }
        guard WorkValidation.remoteDirectory(request.cwd) else {
            throw WorkError(message: "Set the absolute repository directory on the remote host.")
        }
        guard !request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkError(message: "Enter a task first.")
        }
        submitting = true
        defer { submitting = false }
        let result = try await rpc("thread/start", params: [
            "cwd": request.cwd, "approvalPolicy": "on-request", "sandbox": "workspace-write"
        ])
        guard let thread = result["thread"] as? [String: Any], let id = thread["id"] as? String else {
            throw WorkError(message: "The remote host did not return a thread ID.")
        }
        recordThread(thread, notify: false)
        do {
            try await startTurn(threadID: id, prompt: WorkValidation.handoffText(prompt: request.prompt, repository: request.repository))
        } catch {
            update(id, status: .unknown, detail: "Submission outcome unknown. Refresh this thread before retrying.")
            throw error
        }
        return id
    }

    func chat(query: String) async throws {
        guard readyForWork else { throw WorkError(message: "Connect and sign in to the remote host in Cloud Work first.") }
        guard !chatBusy else { throw WorkError(message: "Wait for the current remote reply.") }
        chatBusy = true
        let generation = chatGeneration
        do {
            if let thread = chatThread {
                try await startTurn(threadID: thread, prompt: query)
            } else {
                let request = RemoteWorkRequest(
                    prompt: query,
                    repository: UserDefaults.standard.string(forKey: "workRepository") ?? "",
                    cwd: UserDefaults.standard.string(forKey: "remoteAgentCWD") ?? "")
                // Save the ID before turn/start so early streamed replies cannot be lost.
                guard connected, WorkValidation.remoteDirectory(request.cwd) else {
                    throw WorkError(message: "Connect a remote host and set its repository directory in Cloud Work.")
                }
                let result = try await rpc("thread/start", params: [
                    "cwd": request.cwd, "approvalPolicy": "on-request", "sandbox": "workspace-write"
                ])
                guard generation == chatGeneration else { return }
                guard let thread = result["thread"] as? [String: Any], let id = thread["id"] as? String else {
                    throw WorkError(message: "Missing remote thread ID.")
                }
                chatThread = id
                recordThread(thread, notify: false)
                try await startTurn(threadID: id, prompt: WorkValidation.handoffText(prompt: query, repository: request.repository))
            }
        } catch {
            if generation == chatGeneration { chatBusy = false }
            throw error
        }
    }

    private func startTurn(threadID: String, prompt: String) async throws {
        let result = try await rpc("turn/start", params: [
            "threadId": threadID, "input": [["type": "text", "text": prompt]]
        ])
        if let turn = result["turn"] as? [String: Any], let id = turn["id"] as? String,
           turn["status"] as? String == "inProgress", !completedTurns.contains("\(threadID):\(id)") {
            activeTurns[threadID] = id
            update(threadID, status: .running)
        }
    }

    func interrupt(threadID: String) async throws {
        guard let turn = activeTurns[threadID] else {
            throw WorkError(message: "No active turn is known. Refresh or inspect this thread first.")
        }
        _ = try await rpc("turn/interrupt", params: ["threadId": threadID, "turnId": turn])
    }

    func inspect(threadID: String) async throws {
        let snapshotStarted = Date()
        let result = try await rpc("thread/read", params: ["threadId": threadID, "includeTurns": true])
        guard let thread = result["thread"] as? [String: Any] else { return }
        if let current = WorkStore.shared.jobs.first(where: { $0.provider == .codex && $0.remoteID == threadID }),
           current.updatedAt > snapshotStarted { return }
        recordThread(thread, notify: false)
        if let turn = (thread["turns"] as? [[String: Any]])?.last {
            let status = turn["status"] as? String ?? ""
            if status == "inProgress", let id = turn["id"] as? String { activeTurns[threadID] = id }
            else { activeTurns.removeValue(forKey: threadID) }
            update(threadID, status: .turn(status), notify: false)
            let messages = (turn["items"] as? [[String: Any]] ?? []).compactMap { item -> String? in
                item["type"] as? String == "agentMessage" ? item["text"] as? String : nil
            }
            if !messages.isEmpty { update(threadID, detail: messages.joined(separator: "\n\n"), notify: false) }
        }
    }

    func resolve(_ approval: WorkApproval, accept: Bool) async throws {
        guard connected, approval.connectionID == connectionID,
              let index = WorkStore.shared.approvals.firstIndex(where: { $0.id == approval.id }),
              !WorkStore.shared.approvals[index].sending,
              accept ? approval.canAccept : approval.canDecline else {
            throw WorkError(message: "This approval is no longer actionable.")
        }
        WorkStore.shared.approvals[index].sending = true
        do {
            try await send(["id": jsonID(approval.requestID), "result": ["decision": accept ? "accept" : "decline"]])
            // Do not remove until serverRequest/resolved acknowledges it.
        } catch {
            disconnect(reason: "Approval delivery was not confirmed. Reconnect before taking further action.")
            throw error
        }
    }

    private func rpc(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        guard let requestSocket = socket else { throw WorkError(message: "Remote host is disconnected.") }
        let requestConnection = connectionID
        nextID += 1
        let id = WorkRequestID.number(nextID)
        let data = try JSONSerialization.data(withJSONObject: ["id": nextID, "method": method, "params": params])
        let response: Data = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            timeouts[id] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self, self.pending[id] != nil else { return }
                self.disconnect(reason: "Remote request timed out. Its outcome may be unknown; reconnect to check before retrying.")
            }
            Task { [weak self] in
                do {
                    guard self?.connectionID == requestConnection else { return }
                    try await requestSocket.send(.string(String(decoding: data, as: UTF8.self)))
                } catch {
                    guard let self else { return }
                    self.timeouts.removeValue(forKey: id)?.cancel()
                    self.pending.removeValue(forKey: id)?.resume(throwing: error)
                }
            }
        }
        return (try JSONSerialization.jsonObject(with: response) as? [String: Any]) ?? [:]
    }

    private func send(_ object: [String: Any]) async throws {
        guard let socket else { throw WorkError(message: "Disconnected") }
        let data = try JSONSerialization.data(withJSONObject: object)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func decodeID(_ value: Any?) -> WorkRequestID? {
        guard let value, let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else { return nil }
        return try? JSONDecoder().decode(WorkRequestID.self, from: data)
    }

    private func jsonID(_ id: WorkRequestID) -> Any {
        switch id {
        case .number(let value): return value
        case .text(let value): return value
        }
    }

    func receive(_ data: Data) async throws {
        guard let message = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let id = decodeID(message["id"])
        if let method = message["method"] as? String {
            let params = message["params"] as? [String: Any] ?? [:]
            if let id {
                await serverRequest(id: id, method: method, params: params)
            } else {
                notification(method, params: params)
            }
        } else if let id, let callback = pending.removeValue(forKey: id) {
            timeouts.removeValue(forKey: id)?.cancel()
            if let error = message["error"] as? [String: Any] {
                callback.resume(throwing: WorkError(message: error["message"] as? String ?? "Remote request failed."))
            } else {
                callback.resume(returning: try JSONSerialization.data(withJSONObject: message["result"] as? [String: Any] ?? [:]))
            }
        }
    }

    private func serverRequest(id: WorkRequestID, method: String, params: [String: Any]) async {
        guard method == "item/commandExecution/requestApproval" || method == "item/fileChange/requestApproval",
              let thread = params["threadId"] as? String, let turn = params["turnId"] as? String else {
            // Unsupported elicitation/permissions are never implicitly accepted.
            try? await send(["id": jsonID(id), "error": [
                "code": -32601, "message": "This client cannot answer this request. Use a full remote client."
            ]])
            WorkStore.shared.notice("A remote request needs a full client: \(method)")
            return
        }
        let key = "\(thread):\(params["itemId"] as? String ?? "")"
        let network = params["networkApprovalContext"] as? [String: Any]
        let title = network == nil ? (method.contains("fileChange") ? "Review file changes" : "Run remote command") : "Allow remote network access"
        var detail = params["command"] as? String ?? items[key] ?? "No command or patch preview supplied."
        if let network {
            detail = "Network request\n" + ((try? JSONSerialization.data(withJSONObject: network, options: .prettyPrinted)).map { String(decoding: $0, as: UTF8.self) } ?? "")
        }
        if let cwd = params["cwd"] as? String { detail += "\nDirectory: \(cwd)" }
        if let root = params["grantRoot"] as? String { detail += "\nRequested root: \(root)" }
        if let reason = params["reason"] as? String { detail += "\nReason: \(reason)" }
        let decisions = params["availableDecisions"] as? [Any]
        let strings = decisions?.compactMap { $0 as? String }
        let approval = WorkApproval(
            requestID: id, connectionID: connectionID, threadID: thread, turnID: turn,
            title: title, detail: detail, canAccept: (strings?.contains("accept") ?? true) && (network != nil || params["command"] is String || items[key] != nil),
            canDecline: strings?.contains("decline") ?? true)
        WorkStore.shared.approvals.removeAll { $0.id == approval.id }
        WorkStore.shared.approvals.append(approval)
        update(thread, status: .needsApproval, detail: title)
    }

    private func notification(_ method: String, params: [String: Any]) {
        if method == "account/login/completed", let id = params["loginId"] as? String {
            if login.complete(id: id, success: params["success"] as? Bool == true, error: params["error"] as? String) {
                Task { await finishSignIn() }
            }
            return
        }
        if method == "account/updated" {
            accountRevision = UUID()
            account = nil
            usageWindows = []
            resetChat()
            Task { await refreshAccount() }
            return
        }
        if method == "account/rateLimits/updated" {
            guard account?.isChatGPT == true else { return }
            let incoming = RemoteUsageWindow.parse(params)
            // A single-bucket notification must not discard other known buckets.
            let changed = Set(incoming.map { $0.id.split(separator: ":").dropLast().joined(separator: ":") })
            usageWindows.removeAll { changed.contains($0.id.split(separator: ":").dropLast().joined(separator: ":")) }
            usageWindows += incoming
            usageWindows.sort { $0.id < $1.id }
            return
        }
        if method == "thread/started", let thread = params["thread"] as? [String: Any] {
            recordThread(thread, notify: false)
            return
        }
        if method == "serverRequest/resolved", let id = decodeID(params["requestId"]) {
            WorkStore.shared.approvals.removeAll { $0.requestID == id && $0.connectionID == connectionID }
            return
        }
        guard let thread = params["threadId"] as? String else { return }
        switch method {
        case "thread/status/changed":
            let status = params["status"] as? [String: Any] ?? [:]
            update(thread, status: .thread(type: status["type"] as? String ?? "", flags: status["activeFlags"] as? [String] ?? []))
        case "turn/started":
            if let turn = params["turn"] as? [String: Any], let id = turn["id"] as? String {
                activeTurns[thread] = id
            }
            update(thread, status: .running)
        case "turn/completed":
            let turn = params["turn"] as? [String: Any] ?? [:]
            let status = turn["status"] as? String
            let final = WorkStatus.turn(status ?? "")
            if let id = turn["id"] as? String {
                completedTurns.insert("\(thread):\(id)")
                if completedTurns.count > 500 { completedTurns = ["\(thread):\(id)"] }
            }
            activeTurns.removeValue(forKey: thread)
            WorkStore.shared.approvals.removeAll { $0.threadID == thread }
            let error = (turn["error"] as? [String: Any])?["message"] as? String
            update(thread, status: final, detail: error)
            if thread == chatThread {
                chatBusy = false
                AppState.shared.stateOverride = nil
                if let error { AppState.shared.chatHistory.append(ChatMessage(role: .assistant, content: error)) }
            }
        case "item/started", "item/completed":
            guard let item = params["item"] as? [String: Any], let itemID = item["id"] as? String else { return }
            let type = item["type"] as? String ?? ""
            if type == "commandExecution" || type == "fileChange" {
                let bytes = (try? JSONSerialization.data(withJSONObject: item, options: [.prettyPrinted, .sortedKeys])) ?? Data()
                items["\(thread):\(itemID)"] = String(decoding: bytes, as: UTF8.self)
                // Completed previews cannot be needed by a later approval for this item.
                if method == "item/completed" { items.removeValue(forKey: "\(thread):\(itemID)") }
            }
            if type == "agentMessage", method == "item/completed", let text = item["text"] as? String {
                update(thread, detail: text, notify: false)
                if thread == chatThread, deliveredMessages.insert(itemID).inserted {
                    AppState.shared.chatHistory.append(ChatMessage(role: .assistant, content: text))
                }
            }
        case "hook/started", "hook/completed":
            let run = params["run"] as? [String: Any] ?? [:]
            update(thread, detail: "Remote hook: \(run["eventName"] as? String ?? "lifecycle") · \(method == "hook/completed" ? "finished" : "running")", notify: false)
        case "thread/closed", "thread/archived":
            update(thread, status: .unknown, detail: "Thread is no longer subscribed.", notify: false)
        default: break
        }
    }

    private func recordThread(_ thread: [String: Any], notify: Bool) {
        guard let id = thread["id"] as? String else { return }
        let status = thread["status"] as? [String: Any] ?? [:]
        let git = thread["gitInfo"] as? [String: Any] ?? [:]
        let old = WorkStore.shared.jobs.first { $0.provider == .codex && $0.remoteID == id }
        var mappedStatus = WorkStatus.thread(type: status["type"] as? String ?? "", flags: status["activeFlags"] as? [String] ?? [])
        if mappedStatus == .idle, let old, (old.status == .succeeded || old.status == .failed || old.status == .cancelled) {
            mappedStatus = old.status
        }
        let job = WorkJob(
            provider: .codex, remoteID: id,
            title: thread["name"] as? String ?? thread["preview"] as? String ?? old?.title ?? "Remote task",
            repository: git["originUrl"] as? String ?? thread["cwd"] as? String ?? old?.repository ?? "",
            branch: git["branch"] as? String ?? "",
            status: mappedStatus,
            detail: old?.detail ?? "")
        WorkStore.shared.receive(WorkEvent(job: job, notify: notify))
    }

    private func update(_ id: String, status: WorkStatus? = nil, detail: String? = nil, notify: Bool = true) {
        var job = WorkStore.shared.jobs.first { $0.provider == .codex && $0.remoteID == id }
            ?? WorkJob(provider: .codex, remoteID: id, title: "Remote task", repository: "", status: .unknown)
        if let status {
            let completed = job.status == .succeeded || job.status == .failed || job.status == .cancelled
            if !(status == .idle && completed) { job.status = status }
        }
        if let detail { job.detail = String(detail.prefix(32_000)) }
        job.updatedAt = .now
        job.stale = false
        WorkStore.shared.receive(WorkEvent(job: job, notify: notify))
    }
}
