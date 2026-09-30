import Foundation

@MainActor
protocol AssistantProvider {
    func chat(query: String, context: PromptContext?, state: AppState) async
    func clearConversation()
}

extension ClaudeService: AssistantProvider {}

@MainActor
protocol RemoteChatClient {
    func resetChat()
    func chat(query: String) async throws
}

extension CodexRemoteProvider: RemoteChatClient {}

@MainActor
final class RemoteAssistant: AssistantProvider {
    private var generation = UUID()
    private let client: any RemoteChatClient

    init(client: any RemoteChatClient = CodexRemoteProvider.shared) {
        self.client = client
    }

    func clearConversation() {
        generation = UUID()
        client.resetChat()
    }

    func chat(query: String, context: PromptContext?, state: AppState) async {
        // Never read or upload a Mac file implicitly to the remote repository.
        guard context == nil else {
            state.chatHistory.append(ChatMessage(role: .assistant, content:
                "Remote chat uses the repository on your remote host. Clear the attached local context, or select Claude for the existing file/window chat."))
            state.stateOverride = nil
            return
        }
        let requestGeneration = generation
        do {
            try await client.chat(query: query)
        } catch {
            guard requestGeneration == generation else { return }
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
