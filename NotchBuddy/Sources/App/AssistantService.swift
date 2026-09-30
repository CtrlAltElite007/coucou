import Foundation

@MainActor
protocol AssistantProvider {
    func chat(query: String, context: PromptContext?, state: AppState) async
    func clearConversation()
}

extension ClaudeService: AssistantProvider {}

@MainActor
final class RemoteAssistant: AssistantProvider {
    func clearConversation() { CodexRemoteProvider.shared.resetChat() }

    func chat(query: String, context: PromptContext?, state: AppState) async {
        // Never read or upload a Mac file implicitly to the remote repository.
        guard context == nil else {
            state.chatHistory.append(ChatMessage(role: .assistant, content:
                "Remote chat uses the repository on your remote host. Clear the attached local context, or select Claude for the existing file/window chat."))
            state.stateOverride = nil
            return
        }
        do {
            try await CodexRemoteProvider.shared.chat(query: query)
        } catch {
            state.chatHistory.append(ChatMessage(role: .assistant, content: error.localizedDescription))
            state.stateOverride = nil
        }
    }
}

@MainActor
final class AssistantService {
    static let shared = AssistantService()
    private let remote = RemoteAssistant()

    var selected: WorkProviderID {
        WorkProviderID(rawValue: UserDefaults.standard.string(forKey: "assistantProvider") ?? "") == .claude ? .claude : .codex
    }

    private var provider: any AssistantProvider {
        if selected == .claude { return ClaudeService.shared }
        return remote
    }

    func clearConversation() {
        ClaudeService.shared.clearConversation()
        remote.clearConversation()
        AppState.shared.chatHistory = []
        AppState.shared.promptContext = nil
        AppState.shared.stateOverride = nil
    }

    func chat(query: String, context: PromptContext?, state: AppState) async {
        await provider.chat(query: query, context: context, state: state)
    }
}
