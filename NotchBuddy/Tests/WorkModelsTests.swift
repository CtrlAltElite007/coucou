import Foundation

@main
struct WorkModelsTests {
    static func main() throws {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ name: String) {
            precondition(value(), "Failed: \(name)")
            checks += 1
        }
        expect(WorkValidation.repository(" owner/repo ") == "owner/repo", "repository normalization")
        for invalid in ["../repo", "owner/..", "owner/repo/extra", "https://github.com/a/b", "a/b?x=1", "/repo", "a/"] {
            expect(WorkValidation.repository(invalid) == nil, "reject repository path injection")
        }
        expect(WorkValidation.remoteURL("wss://agent.example/socket") != nil, "secure remote URL")
        for invalid in ["ws://agent.example", "https://agent.example", "wss://user:secret@agent.example", "wss://agent.example?token=secret", "wss://agent.example#secret", "file:///tmp/a"] {
            expect(WorkValidation.remoteURL(invalid) == nil, "reject unsafe remote URL")
        }
        expect(WorkValidation.githubURL("https://github.com/owner/repo/actions/runs/1") != nil, "GitHub deep link")
        expect(WorkValidation.githubURL("https://github.com.evil.test/owner/repo") == nil, "host suffix is not GitHub")
        expect(WorkValidation.githubURL("https://evil@github.com/path") == nil, "credential URL")
        expect(!WorkValidation.remoteDirectory("~/repo"), "no local home expansion")
        expect(!WorkValidation.remoteDirectory("/repo\nother"), "no multiline paths")
        expect(WorkValidation.remoteDirectory("/workspace/repo"), "remote absolute path")

        let statuses: [(String, String?, WorkStatus)] = [
            ("completed", "success", .succeeded), ("completed", "failure", .failed),
            ("completed", "timed_out", .failed), ("completed", "cancelled", .cancelled),
            ("completed", "neutral", .unknown), ("completed", "skipped", .unknown),
            ("queued", nil, .queued), ("waiting", nil, .needsApproval),
            ("in_progress", nil, .running), ("new_status", nil, .unknown)
        ]
        for (status, conclusion, expected) in statuses {
            expect(WorkStatus.github(status: status, conclusion: conclusion) == expected, "GitHub state mapping")
        }
        expect(WorkStatus.thread(type: "active", flags: ["waitingOnApproval"]) == .needsApproval, "approval status")
        expect(WorkStatus.thread(type: "active", flags: ["waitingOnUserInput"]) == .needsApproval, "input status")
        expect(WorkStatus.thread(type: "notLoaded") == .unknown, "unloaded is not success")

        let number = try JSONDecoder().decode(WorkRequestID.self, from: Data("1".utf8))
        let string = try JSONDecoder().decode(WorkRequestID.self, from: Data(#""1""#.utf8))
        expect(number != string && number.key != string.key, "typed request IDs do not collide")
        expect(tryDecode(Data("true".utf8)) == nil, "boolean is not request ID")
        expect(tryDecode(Data("null".utf8)) == nil, "null is not request ID")
        let encodedString = try JSONEncoder().encode(string)
        let encodedNumber = try JSONEncoder().encode(number)
        expect(tryDecode(encodedString) == string, "string ID round trip")
        expect(tryDecode(encodedNumber) == number, "number ID round trip")

        var ledger = WorkLedger()
        let date = Date(timeIntervalSince1970: 100)
        var job = WorkJob(provider: .codex, remoteID: "shared", title: "Remote", repository: "owner/repo",
                          status: .running, updatedAt: date)
        expect(!ledger.apply(WorkEvent(job: job)), "running is quiet")
        job.status = .needsApproval
        job.updatedAt = date.addingTimeInterval(1)
        expect(ledger.apply(WorkEvent(job: job)), "approval transition notifies")
        expect(!ledger.apply(WorkEvent(job: job)), "duplicate approval is quiet")
        var older = job
        older.status = .running
        older.updatedAt = date
        expect(!ledger.apply(WorkEvent(job: older)), "old snapshot rejected")
        expect(ledger.jobs.first?.status == .needsApproval, "old snapshot cannot overwrite")
        let github = WorkJob(provider: .github, remoteID: "shared", title: "Build", repository: "owner/repo",
                             status: .succeeded, updatedAt: date)
        expect(!ledger.apply(WorkEvent(job: github, notify: false)), "first snapshot is quiet")
        expect(ledger.jobs.count == 2, "provider IDs are namespaced")
        ledger.markStale(provider: .codex)
        expect(ledger.jobs.first { $0.provider == .codex }?.stale == true, "disconnect marks stale")
        expect(ledger.jobs.first { $0.provider == .github }?.stale == false, "provider isolation")
        job.status = .succeeded
        job.updatedAt = date.addingTimeInterval(2)
        expect(ledger.apply(WorkEvent(job: job)), "completion after reconnect")
        expect(ledger.jobs.first { $0.provider == .codex }?.stale == false, "fresh event clears stale")
        ledger.remove(provider: .codex)
        expect(ledger.jobs.count == 1 && ledger.jobs[0].provider == .github, "clear only selected provider")
        for value in 0..<220 {
            ledger.apply(WorkEvent(job: WorkJob(provider: .codex, remoteID: "\(value)", title: "", repository: "",
                status: .idle, updatedAt: Date(timeIntervalSince1970: Double(value))), notify: false))
        }
        expect(ledger.jobs.count == 200, "history remains bounded")
        expect(WorkValidation.handoffText(prompt: "Fix it", repository: "a/b") == "Repository: a/b\n\nFix it", "repo-aware handoff")
        print("Passed \(checks) cloud work model checks.")
    }

    static func tryDecode(_ data: Data) -> WorkRequestID? {
        try? JSONDecoder().decode(WorkRequestID.self, from: data)
    }
}
