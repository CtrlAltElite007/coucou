import SwiftUI
import UserNotifications

@MainActor
final class WorkStore: ObservableObject {
    static let shared = WorkStore()
    @Published private(set) var jobs: [WorkJob] = []
    @Published var approvals: [WorkApproval] = []
    @Published var notices: [String] = []
    @Published var notificationsEnabled = UserDefaults.standard.bool(forKey: "workNotifications") {
        didSet { UserDefaults.standard.set(notificationsEnabled, forKey: "workNotifications") }
    }
    private var ledger = WorkLedger()

    func receive(_ event: WorkEvent) {
        let alert = ledger.apply(event)
        jobs = ledger.jobs
        updatePill()
        guard alert else { return }
        if notificationsEnabled {
            let content = UNMutableNotificationContent()
            content.title = "\(event.job.provider.title): \(event.job.status.label)"
            content.body = event.job.title
            let request = UNNotificationRequest(identifier: event.job.id, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { _ in }
        }
    }

    func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { allowed, _ in
            Task { @MainActor in self.notificationsEnabled = allowed }
        }
    }

    func stale(_ provider: WorkProviderID) {
        ledger.markStale(provider: provider)
        jobs = ledger.jobs
        updatePill()
    }

    func clear(_ provider: WorkProviderID) {
        ledger.remove(provider: provider)
        jobs = ledger.jobs
        updatePill()
    }

    func notice(_ message: String) {
        notices.insert(message, at: 0)
        notices = Array(notices.prefix(10))
    }

    private func updatePill() {
        let state = AppState.shared
        guard let index = state.tasks.firstIndex(where: { $0.id == "integration_cloud" }) else { return }
        let live = jobs.filter { !$0.stale && $0.provider != .claude }
        let attention = live.contains { $0.status == .needsApproval }
        let running = live.contains { $0.status == .running || $0.status == .queued }
        state.tasks[index].state = attention ? .approval : (running ? .working : .idle)
        state.tasks[index].pillBadge = attention ? .approval : nil
        state.tasks[index].steps = [attention ? "A remote job needs attention" :
            (running ? "Work is running in the cloud" : "Open your remote workspace")]
        state.tasks[index].stepIndex = 0
    }
}

/// Compatibility adapter observes the existing hook flow; Claude's reply socket remains its owner.
@MainActor
enum ClaudeWorkAdapter {
    static func receive(name: String, payload: [String: Any]) {
        guard let id = payload["session_id"] as? String, !id.isEmpty else { return }
        let cwd = payload["cwd"] as? String ?? ""
        let status: WorkStatus
        switch name {
        case "SessionStart", "SessionEnd": status = .idle
        case "UserPromptSubmit", "PreToolUse", "PostToolUse": status = .running
        case "PermissionRequest": status = .needsApproval
        case "Stop": status = .succeeded
        case "StopFailure": status = .failed
        default: return
        }
        WorkStore.shared.receive(WorkEvent(job: WorkJob(
            provider: .claude, remoteID: id, title: URL(fileURLWithPath: cwd).lastPathComponent,
            repository: cwd, status: status, detail: name), notify: false))
    }
}

extension Notification.Name {
    static let openCloudWork = Notification.Name("openCloudWork")
}
