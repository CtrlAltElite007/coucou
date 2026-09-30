import SwiftUI
import AppKit

struct CloudWorkView: View {
    @ObservedObject private var store = WorkStore.shared
    @ObservedObject private var remote = CodexRemoteProvider.shared
    @ObservedObject private var github = GitHubWorkProvider.shared
    @AppStorage("workRepository") private var repository = ""
    @AppStorage("remoteAgentCWD") private var remoteDirectory = ""
    @State private var prompt = ""
    @State private var filter: WorkProviderID? = nil
    @State private var message = ""
    @State private var selected: WorkJob?
    @State private var dispatchConfirmation = false

    private var jobs: [WorkJob] { store.jobs.filter { filter == nil || $0.provider == filter } }

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Cloud Work", systemImage: "cloud")
                    .font(.title2.bold())
                Spacer()
                Button("Settings") { NotificationCenter.default.post(name: .openFullSettings, object: nil) }
                Button("Refresh") { Task { await refresh() } }
            }
            Text(repository.isEmpty ? "Choose a repository in Settings." : repository)
                .font(.headline)
            HStack {
                Circle().fill(remote.connected ? Color.green : Color.gray).frame(width: 8, height: 8)
                Text(remote.statusText).font(.caption)
                Spacer()
                Button(remote.connected ? "Disconnect" : "Connect remote host") {
                    if remote.connected { remote.disconnect() }
                    else { Task { await remote.connect() } }
                }.disabled(remote.connecting)
            }
            if remote.connected { RemoteAccountView() }
            Text("Codex runs on your remote host. The WebSocket integration is experimental.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Picker("Show", selection: $filter) {
                    Text("All providers").tag(WorkProviderID?.none)
                    ForEach(WorkProviderID.allCases, id: \.self) { provider in
                        Text(provider.title).tag(Optional(provider))
                    }
                }.frame(width: 240)
                Spacer()
                Text(github.statusText).font(.caption).foregroundStyle(.secondary)
            }

            if !store.approvals.isEmpty {
                GroupBox("Remote approvals") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(store.approvals) { approval in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(approval.title).bold()
                                    Text("Thread \(approval.threadID) · turn \(approval.turnID)").font(.caption).textSelection(.enabled)
                                    ScrollView {
                                        Text(approval.detail).font(.system(.caption, design: .monospaced))
                                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                    }.frame(maxHeight: 110)
                                    HStack {
                                        Button("Deny") { decide(approval, accept: false) }
                                            .disabled(approval.sending || !approval.canDecline)
                                        Button("Allow once") { decide(approval, accept: true) }
                                            .disabled(approval.sending || !approval.canAccept)
                                        if approval.sending { Text("Waiting for server confirmation…").font(.caption) }
                                    }
                                }
                            }
                        }.padding(5)
                    }.frame(maxHeight: 210)
                }
            }

            List(jobs) { job in
                Button {
                    selected = job
                    if job.provider == .codex {
                        Task {
                            do {
                                try await remote.inspect(threadID: job.remoteID)
                                selected = store.jobs.first { $0.id == job.id }
                            } catch { message = error.localizedDescription }
                        }
                    }
                } label: {
                    HStack(alignment: .top) {
                        Image(systemName: icon(job.status)).foregroundStyle(job.stale ? .gray : color(job.status))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(job.title.isEmpty ? "Untitled remote task" : job.title).lineLimit(1)
                            Text("\(job.provider.title) · \(job.repository)\(job.branch.isEmpty ? "" : " · " + job.branch)")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(job.stale ? "Stale · \(job.status.label)" : job.status.label).font(.caption)
                    }.padding(.vertical, 3)
                }.buttonStyle(.plain)
            }.frame(height: 240).overlay {
                if jobs.isEmpty { Text("Connect a remote host or refresh a configured GitHub repository.").foregroundStyle(.secondary) }
            }

            GroupBox("Send work to the cloud") {
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: $prompt).font(.body).frame(height: 75)
                    Text("Remote directory: \(remoteDirectory.isEmpty ? "not configured" : remoteDirectory). Repository labels do not clone or switch branches.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Start remote task") { startRemote() }
                            .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !remote.readyForWork || remote.submitting)
                        Button("Copy prompt & open Codex cloud") { browserHandoff() }
                            .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Run GitHub workflow…") { dispatchConfirmation = true }
                            .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || github.dispatching)
                    }
                }.padding(4)
            }
            if !message.isEmpty { Text(message).font(.caption).textSelection(.enabled) }
            if let notice = store.notices.first { Text(notice).font(.caption).foregroundStyle(.orange) }
        }
        .padding(18)
        }.frame(minWidth: 740, minHeight: 680)
        .task {
            await refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                await refresh()
            }
        }
        .sheet(item: $selected) { job in
            VStack(alignment: .leading, spacing: 12) {
                Text(job.title).font(.headline)
                Text("\(job.provider.title) · \(job.status.label)\(job.stale ? " (stale)" : "")")
                Text("ID: \(job.remoteID)").font(.caption).textSelection(.enabled)
                ScrollView {
                    Text(job.detail.isEmpty ? "No detail received." : job.detail)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    if let url = job.url { Link("Open on GitHub", destination: url) }
                    if job.provider == .codex && job.status == .running {
                        Button("Interrupt remote turn") {
                            Task {
                                do { try await remote.interrupt(threadID: job.remoteID); selected = nil }
                                catch { message = error.localizedDescription; selected = nil }
                            }
                        }
                    }
                    Spacer()
                    Button("Close") { selected = nil }
                }
            }.padding(20).frame(width: 650, height: 440)
        }
        .confirmationDialog("Dispatch the configured workflow?", isPresented: $dispatchConfirmation) {
            Button("Dispatch workflow") {
                Task {
                    do { message = try await github.handoff(workRequest) }
                    catch { message = error.localizedDescription }
                }
            }
        } message: {
            Text("Repository: \(repository)\nWorkflow: \(UserDefaults.standard.string(forKey: "workWorkflow") ?? "")\nRef: \(UserDefaults.standard.string(forKey: "workRef") ?? "")\nYour prompt will be sent as the workflow's prompt input. This may consume runner time and perform the actions defined by that workflow.")
        }
    }

    private var workRequest: RemoteWorkRequest {
        RemoteWorkRequest(prompt: prompt, repository: repository, cwd: remoteDirectory)
    }

    private func refresh() async {
        do { try await remote.refresh() } catch { message = error.localizedDescription; store.stale(.codex) }
        do { try await github.refresh() } catch { message = error.localizedDescription }
    }

    private func startRemote() {
        Task {
            do {
                let id = try await remote.handoff(workRequest)
                message = "Started remote thread \(id)."
                prompt = ""
            } catch { message = error.localizedDescription }
        }
    }

    private func decide(_ approval: WorkApproval, accept: Bool) {
        Task {
            do { try await remote.resolve(approval, accept: accept) }
            catch { message = error.localizedDescription }
        }
    }

    private func browserHandoff() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(WorkValidation.handoffText(prompt: prompt, repository: repository), forType: .string)
        NSWorkspace.shared.open(URL(string: "https://chatgpt.com/codex")!)
        message = "Prompt copied. Select the repository, paste it and submit in the browser. No task has been submitted by Coucou."
    }

    private func icon(_ status: WorkStatus) -> String {
        switch status {
        case .needsApproval: return "hand.raised"
        case .running, .queued: return "clock"
        case .succeeded: return "checkmark.circle"
        case .failed: return "exclamationmark.circle"
        default: return "circle"
        }
    }

    private func color(_ status: WorkStatus) -> Color {
        switch status {
        case .needsApproval: return .orange
        case .succeeded: return .green
        case .failed: return .red
        default: return .secondary
        }
    }
}

struct CloudWorkSettingsView: View {
    @AppStorage("assistantProvider") private var assistant = "codex"
    @State private var endpoint = UserDefaults.standard.string(forKey: "remoteAgentURL") ?? ""
    @State private var cwd = UserDefaults.standard.string(forKey: "remoteAgentCWD") ?? ""
    @State private var repository = UserDefaults.standard.string(forKey: "workRepository") ?? ""
    @State private var workflow = UserDefaults.standard.string(forKey: "workWorkflow") ?? ""
    @State private var ref = UserDefaults.standard.string(forKey: "workRef") ?? ""
    @State private var token = KeychainStore.shared.get("remote-agent-token") ?? ""
    @State private var message = ""
    @ObservedObject private var store = WorkStore.shared
    @ObservedObject private var remote = CodexRemoteProvider.shared

    var body: some View {
        GroupBox("Assistant & Cloud Work") {
            VStack(alignment: .leading, spacing: 9) {
                Picker("Assistant", selection: $assistant) {
                    Text("Codex · remote host").tag("codex")
                    Text("Claude · Anthropic API").tag("claude")
                }
                .onChange(of: assistant) { _, _ in AssistantService.shared.clearConversation() }
                TextField("Remote server (wss://host/path)", text: $endpoint)
                SecureField("Remote server bearer token", text: $token)
                TextField("Repository directory on remote host (/workspace/repo)", text: $cwd)
                TextField("GitHub owner/repository", text: $repository)
                TextField("Optional workflow filename (agent.yml)", text: $workflow)
                TextField("Workflow branch or ref", text: $ref)
                Text("Connect your personal remote host, then sign in with ChatGPT in Cloud Work. The host needs its own checkout. Connection tokens stay in Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Save cloud settings") { save() }
                    Button("Open Cloud Work") { NotificationCenter.default.post(name: .openCloudWork, object: nil) }
                }
                Toggle("Job notifications", isOn: Binding(
                    get: { store.notificationsEnabled },
                    set: { enabled in
                        if enabled { store.requestNotifications() } else { store.notificationsEnabled = false }
                    }))
                HStack {
                    Button("Inspect remote hooks") { Task { await remote.inspectHooks() } }.disabled(!remote.connected)
                    Link("Setup & limitations", destination: URL(string: "https://github.com/CtrlAltElite007/coucou/blob/main/docs/CLOUD_WORK.md")!)
                }
                if !remote.hooksSummary.isEmpty {
                    ScrollView { Text(remote.hooksSummary).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                        .frame(maxHeight: 140)
                }
                if !message.isEmpty { Text(message).font(.caption) }
            }.textFieldStyle(.roundedBorder).padding(6)
        }
    }

    private func save() {
        let cleanURL = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanRepo = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanURL.isEmpty || WorkValidation.remoteURL(cleanURL) != nil else {
            message = "Use wss:// with no credentials, query or fragment in the URL."; return
        }
        guard cwd.isEmpty || WorkValidation.remoteDirectory(cwd) else {
            message = "The remote directory must be an absolute path."; return
        }
        guard cleanRepo.isEmpty || WorkValidation.repository(cleanRepo) != nil else {
            message = "Repository must be owner/name."; return
        }
        remote.disconnect(reason: "Settings changed. Connect to the remote host again.")
        store.clear(.codex)
        store.clear(.github)
        let defaults = UserDefaults.standard
        defaults.set(cleanURL, forKey: "remoteAgentURL")
        defaults.set(cwd, forKey: "remoteAgentCWD")
        defaults.set(cleanRepo, forKey: "workRepository")
        defaults.set(workflow.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "workWorkflow")
        defaults.set(ref.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "workRef")
        if token.isEmpty { KeychainStore.shared.remove("remote-agent-token") }
        else { KeychainStore.shared.set("remote-agent-token", value: token) }
        AssistantService.shared.clearConversation()
        message = "Saved. Open Cloud Work to connect or refresh."
    }
}

struct CloudWorkIslandCard: View {
    @ObservedObject private var store = WorkStore.shared
    @ObservedObject private var remote = CodexRemoteProvider.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Cloud Work").font(.system(size: 12, weight: .semibold))
            Text(store.approvals.isEmpty ? "\(store.jobs.filter { $0.provider != .claude }.count) recent jobs" :
                    "\(store.approvals.count) pending approvals")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Button("Open workspace") {
                NotificationCenter.default.post(name: .openCloudWork, object: nil)
            }.font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(.green)
            Text(remote.connected ? "Remote host connected" : "Connect in workspace")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(.leading, 108).padding(.top, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
