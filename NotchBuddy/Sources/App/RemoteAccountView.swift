import SwiftUI
import AppKit

struct RemoteAccountView: View {
    @ObservedObject private var remote = CodexRemoteProvider.shared
    @State private var signOutConfirmation = false
    @State private var showUsage = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: remote.account?.ready == true ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                    Text(remote.accountMessage).font(.callout).textSelection(.enabled)
                    Spacer()
                    if remote.accountBusy || remote.login.starting {
                        ProgressView().controlSize(.small)
                    } else if remote.login.challenge == nil {
                        if remote.account?.requiresOpenaiAuth == true && remote.account?.account == nil {
                            Button("Sign in with ChatGPT") { Task { await remote.signIn() } }
                                .buttonStyle(.borderedProminent)
                        }
                        Button("Check account") { Task { await remote.refreshAccount() } }
                            .disabled(!remote.connected)
                        if remote.account?.account != nil {
                            Button("Sign out…") { signOutConfirmation = true }
                                .disabled(remote.chatBusy || remote.submitting)
                        }
                    }
                }
                if let challenge = remote.login.challenge, let url = challenge.verificationURL {
                    HStack(spacing: 12) {
                        Text(challenge.userCode)
                            .font(.system(.title3, design: .monospaced).bold())
                            .textSelection(.enabled)
                            .accessibilityLabel("One-time sign-in code: \(challenge.userCode)")
                        Button("Copy code") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(challenge.userCode, forType: .string)
                        }
                        Link("Open OpenAI sign-in", destination: url)
                        Spacer()
                        Button("Cancel sign-in") { Task { await remote.cancelSignIn() } }
                            .disabled(remote.accountBusy)
                    }
                    Text("Enter this code on OpenAI's page to sign in on your personal remote host. This window updates when sign-in finishes.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if remote.account?.account == nil {
                    Text("Use your ChatGPT account. Your remote host stores the login; Coucou never reads your desktop session.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if remote.account?.isChatGPT == true {
                    DisclosureGroup("Account usage", isExpanded: $showUsage) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(remote.usageWindows) { window in
                                HStack {
                                    Text(window.label).font(.caption)
                                    Spacer()
                                    Text("\(Int(window.remainingPercent))% remaining").font(.caption.monospacedDigit())
                                    if let minutes = window.durationMinutes {
                                        Text("\(minutes) min window").font(.caption).foregroundStyle(.secondary)
                                    }
                                    if let reset = window.resetsAt {
                                        Text("Resets \(reset.formatted(date: .abbreviated, time: .shortened))")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                ProgressView(value: window.remainingPercent, total: 100)
                            }
                            if !remote.usageMessage.isEmpty { Text(remote.usageMessage).font(.caption) }
                            Button("Refresh usage") { Task { await remote.refreshUsage() } }
                                .controlSize(.small)
                        }.padding(.top, 6)
                    }
                }
            }.padding(4)
        } label: {
            Label("Remote account", systemImage: "lock.shield")
        }
        .confirmationDialog("Sign out of the remote host?", isPresented: $signOutConfirmation) {
            Button("Sign out of remote host", role: .destructive) { Task { await remote.signOut() } }
        } message: {
            Text("This removes the account from the connected host and can affect other clients and running tasks using that host. It does not sign out the ChatGPT desktop app.")
        }
    }
}
