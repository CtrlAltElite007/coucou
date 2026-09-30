import Foundation
#if canImport(Combine)
import Combine
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@MainActor
final class GitHubWorkProvider: ObservableObject, WorkProvider {
    static let shared = GitHubWorkProvider()
    let providerID: WorkProviderID = .github
    var capabilities: WorkCapabilities { [.status, .handoff] }
    @Published private(set) var statusText = "Choose a repository in Settings."
    @Published private(set) var refreshing = false
    @Published private(set) var dispatching = false
    private var observedRepo = ""
    private var hasSnapshot = false
    private let session = URLSession(configuration: .ephemeral, delegate: WorkSessionDelegate(), delegateQueue: nil)

    func refresh() async throws {
        guard !refreshing else { return }
        let raw = UserDefaults.standard.string(forKey: "workRepository") ?? ""
        guard let repo = WorkValidation.repository(raw) else {
            WorkStore.shared.clear(.github)
            hasSnapshot = false
            observedRepo = ""
            statusText = "Enter a GitHub owner/repository in Settings."
            return
        }
        if repo != observedRepo {
            WorkStore.shared.clear(.github)
            observedRepo = repo
            hasSnapshot = false
        }
        refreshing = true
        defer { refreshing = false }
        let notify = hasSnapshot
        do {
            var count = 0
            // Latest 100 runs; each run is a cloud job, not proof of deployment.
            for page in 1...2 {
                let data = try await request(path: "/repos/\(repo)/actions/runs?per_page=50&page=\(page)")
                guard UserDefaults.standard.string(forKey: "workRepository") == repo else { return }
                guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let runs = root["workflow_runs"] as? [[String: Any]] else {
                    throw WorkError(message: "GitHub returned an unexpected run list.")
                }
                for run in runs {
                    guard let number = run["id"] as? Int else { continue }
                    let status = WorkStatus.github(status: run["status"] as? String ?? "", conclusion: run["conclusion"] as? String)
                    let conclusion = run["conclusion"] as? String ?? run["status"] as? String ?? "unknown"
                    let date = ISO8601DateFormatter().date(from: run["updated_at"] as? String ?? "") ?? .now
                    let job = WorkJob(
                        provider: .github, remoteID: "\(repo)/\(number)",
                        title: run["display_title"] as? String ?? run["name"] as? String ?? "Workflow",
                        repository: repo, branch: run["head_branch"] as? String ?? "",
                        status: status, detail: "\(run["name"] as? String ?? "Workflow") · \(conclusion)\nCommit: \(run["head_sha"] as? String ?? "")\nAttempt: \(run["run_attempt"] as? Int ?? 1)",
                        url: WorkValidation.githubURL(run["html_url"] as? String ?? ""), updatedAt: date)
                    WorkStore.shared.receive(WorkEvent(job: job, notify: notify))
                }
                count += runs.count
                if runs.count < 50 { break }
            }
            hasSnapshot = true
            statusText = "\(count) recent runs · refreshed \(Date().formatted(date: .omitted, time: .shortened))"
        } catch {
            WorkStore.shared.stale(.github)
            statusText = error.localizedDescription
            throw error
        }
    }

    func handoff(_ request: RemoteWorkRequest) async throws -> String {
        guard !dispatching else { throw WorkError(message: "A workflow dispatch is already in progress.") }
        guard let repo = WorkValidation.repository(request.repository) else {
            throw WorkError(message: "Set a valid GitHub repository first.")
        }
        let workflow = UserDefaults.standard.string(forKey: "workWorkflow") ?? ""
        let ref = UserDefaults.standard.string(forKey: "workRef") ?? ""
        guard workflow.range(of: "^[A-Za-z0-9_.-]+[.]ya?ml$", options: .regularExpression) != nil,
              !ref.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkError(message: "Set a workflow filename, branch/ref and prompt. The workflow must accept a prompt input.")
        }
        dispatching = true
        defer { dispatching = false }
        let body = try JSONSerialization.data(withJSONObject: ["ref": ref, "inputs": ["prompt": request.prompt]])
        _ = try await self.request(path: "/repos/\(repo)/actions/workflows/\(workflow)/dispatches", method: "POST", body: body)
        // GitHub returns 204 without a run ID. Never associate an arbitrary run with this dispatch.
        statusText = "Dispatch accepted. Refresh to find the run on GitHub."
        return "GitHub accepted the dispatch; a run ID was not returned."
    }

    private func request(path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        guard let token = KeychainStore.shared.get("github-token"), !token.isEmpty else {
            throw WorkError(message: "Save a GitHub token in Settings. Actions read is needed; dispatch also needs Actions write.")
        }
        guard let url = URL(string: "https://api.github.com" + path), url.host == "api.github.com" else {
            throw WorkError(message: "Invalid GitHub request.")
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw WorkError(message: "No response from GitHub.") }
        guard (200..<300).contains(response.statusCode) else {
            let description: String
            switch response.statusCode {
            case 401: description = "GitHub rejected the token."
            case 403, 429: description = "GitHub denied access or rate-limited this request. Check token permissions and retry later."
            case 404: description = "Repository or workflow unavailable. Check its name and token access."
            case 422: description = "Workflow input or ref rejected. Configure workflow_dispatch with a string prompt input."
            default: description = "GitHub request failed (HTTP \(response.statusCode))."
            }
            throw WorkError(message: description)
        }
        return data
    }
}

/// Credentials are never forwarded to a redirect target.
final class WorkSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
