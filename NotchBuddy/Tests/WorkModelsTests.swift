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
            ("completed", "action_required", .needsApproval),
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
        ledger.markStale(provider: .codex)
        expect(!ledger.apply(WorkEvent(job: job)), "recovery with unchanged status is quiet")
        ledger.remove(provider: .codex)
        expect(ledger.jobs.count == 1 && ledger.jobs[0].provider == .github, "clear only selected provider")
        for value in 0..<220 {
            ledger.apply(WorkEvent(job: WorkJob(provider: .codex, remoteID: "\(value)", title: "", repository: "",
                status: .idle, updatedAt: Date(timeIntervalSince1970: Double(value))), notify: false))
        }
        expect(ledger.jobs.count == 200, "history remains bounded")
        expect(WorkValidation.handoffText(prompt: "Fix it", repository: "a/b") == "Repository: a/b\n\nFix it", "repo-aware handoff")

        for (wire, expected) in [("completed", WorkStatus.succeeded), ("failed", .failed),
                                 ("interrupted", .cancelled), ("inProgress", .running), ("new", .unknown)] {
            expect(WorkStatus.turn(wire) == expected, "remote turn terminal mapping")
        }
        // Auth readiness is explicit: a transport connection is not a signed-in account.
        let signedOut = try JSONDecoder().decode(RemoteAccountSnapshot.self,
            from: Data(#"{"account":null,"requiresOpenaiAuth":true}"#.utf8))
        expect(!signedOut.ready, "signed out host cannot start work")
        let custom = try JSONDecoder().decode(RemoteAccountSnapshot.self,
            from: Data(#"{"account":null,"requiresOpenaiAuth":false}"#.utf8))
        expect(custom.ready, "custom providers do not require ChatGPT")
        let signedIn = try JSONDecoder().decode(RemoteAccountSnapshot.self,
            from: Data(#"{"account":{"type":"chatgpt","email":null,"planType":"plus"},"requiresOpenaiAuth":true}"#.utf8))
        expect(signedIn.ready && signedIn.isChatGPT, "ChatGPT account without email")
        expect(signedIn.label.contains("Plus"), "plan is visible")
        let apiKey = try JSONDecoder().decode(RemoteAccountSnapshot.self,
            from: Data(#"{"account":{"type":"apiKey"},"requiresOpenaiAuth":true}"#.utf8))
        expect(apiKey.ready && !apiKey.isChatGPT, "API accounts remain supported")

        let challenge = RemoteDeviceLogin(type: "chatgptDeviceCode", loginId: "login-1",
            verificationUrl: "https://auth.openai.com/codex/device", userCode: "ABCD-1234")
        expect(challenge.verificationURL != nil, "official sign-in destination")
        for invalid in ["http://auth.openai.com/codex/device", "https://auth.openai.com.evil.test/codex/device",
                        "https://evil@auth.openai.com/codex/device", "https://auth.openai.com:443/codex/device",
                        "https://auth.openai.com/codex/device?next=evil", "https://auth.openai.com/codex/device#evil",
                        "https://auth.openai.com/other"] {
            let value = RemoteDeviceLogin(type: "chatgptDeviceCode", loginId: "login-1",
                verificationUrl: invalid, userCode: "ABCD-1234")
            expect(value.verificationURL == nil, "reject untrusted sign-in destination")
        }
        var login = RemoteLoginState()
        login.begin()
        try login.receive(challenge)
        expect(login.challenge == challenge && !login.starting, "show code after start response")
        expect(!login.complete(id: "other-client", success: true, error: nil), "ignore unrelated login completion")
        expect(login.challenge == challenge, "unrelated completion preserves pending login")
        expect(login.complete(id: "login-1", success: true, error: nil), "matching completion accepted")
        expect(login.challenge == nil && login.outcome == .succeeded, "successful login clears code")
        login.begin()
        expect(!login.complete(id: "login-1", success: true, error: nil), "buffer early completion")
        try login.receive(challenge)
        expect(login.challenge == nil && login.outcome == .succeeded, "early completion does not resurrect code")
        login.begin()
        try login.receive(challenge)
        login.complete(id: "login-1", success: false, error: "Expired")
        expect(login.outcome == .failed("Expired"), "expiry is displayed")
        login = RemoteLoginState()
        expect(!login.complete(id: "login-1", success: true, error: nil), "disconnect ignores late completion")

        let usage = RemoteUsageWindow.parse([
            "rateLimits": ["primary": ["usedPercent": 99.0]],
            "rateLimitsByLimitId": [
                "first": ["primary": ["usedPercent": 25.0, "windowDurationMins": 300, "resetsAt": 1000.0]],
                "second": ["primary": ["usedPercent": 120.0], "secondary": ["usedPercent": -2.0]]
            ]
        ])
        expect(usage.count == 3, "prefer all named quota buckets")
        expect(usage[0].remainingPercent == 75, "remaining is inverse of usage")
        expect(usage[0].resetsAt == Date(timeIntervalSince1970: 1000), "reset timestamp is seconds")
        expect(usage[1].remainingPercent == 0 && usage[2].remainingPercent == 100, "clamp quota percentages")
        expect(RemoteUsageWindow.parse(["rateLimits": ["primary": NSNull()]]).isEmpty, "missing usage is not zero")
        expect(RemoteUsageWindow.parse(["rateLimits": ["primary": ["usedPercent": Double.nan]]]).isEmpty, "reject nonfinite usage")

        print("Passed \(checks) cloud work model checks.")
    }

    static func tryDecode(_ data: Data) -> WorkRequestID? {
        try? JSONDecoder().decode(WorkRequestID.self, from: data)
    }
}
