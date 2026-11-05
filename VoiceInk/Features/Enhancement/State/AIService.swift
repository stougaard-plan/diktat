import Combine
import Foundation

/// Kun lokale udbydere. Ingen API-nøgler, ingen skyudbydere.
enum AIProvider: String, CaseIterable {
    case ollama = "Ollama"

    var displayName: String {
        switch self {
        case .ollama: return "Ollama"
        }
    }

    var baseURL: String {
        switch self {
        case .ollama: return UserDefaults.standard.string(forKey: "ollamaBaseURL") ?? "http://localhost:11434"
        }
    }

    var defaultModel: String {
        switch self {
        case .ollama: return UserDefaults.standard.string(forKey: "ollamaSelectedModel") ?? "mistral"
        }
    }

    var availableModels: [String] {
        switch self {
        case .ollama: return []
        }
    }

    var requiresAPIKey: Bool { false }
    var supportsEnhancement: Bool { true }
    var supportsCustomModelID: Bool { false }
}

struct OllamaRefreshResult {
    let models: [OllamaModel]
    let errorMessage: String?
}

class AIService: ObservableObject {
    @Published var isAPIKeyValid: Bool = true
    @Published var selectedProvider: AIProvider {
        didSet {
            userDefaults.set(selectedProvider.rawValue, forKey: "selectedAIProvider")
            refreshValidity()
            if selectedProvider == .ollama {
                Task { await refreshOllamaAvailability() }
            }
            NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
        }
    }

    @Published private var selectedModels: [AIProvider: String] = [:]
    private let userDefaults = UserDefaults.standard
    private lazy var ollamaService = OllamaService()
    @Published private(set) var isOllamaRefreshing = false

    var connectedProviders: [AIProvider] {
        AIProvider.allCases.filter { provider in
            switch provider {
            case .ollama: return ollamaService.isConnected
            }
        }
    }

    var currentModel: String { selectedModel(for: selectedProvider) }

    func selectedModel(for provider: AIProvider) -> String {
        if let model = selectedModels[provider], !model.isEmpty { return model }
        return provider.defaultModel
    }

    func customModelID(for provider: AIProvider) -> String { "" }

    var availableModels: [String] { availableModels(for: selectedProvider) }

    func availableModels(for provider: AIProvider) -> [String] {
        provider == .ollama ? ollamaService.availableModels.map { $0.name } : provider.availableModels
    }

    init() {
        if let saved = userDefaults.string(forKey: "selectedAIProvider"), let provider = AIProvider(rawValue: saved) {
            self.selectedProvider = provider
        } else {
            self.selectedProvider = .ollama
        }
        for provider in AIProvider.allCases {
            if let saved = userDefaults.string(forKey: "\(provider.rawValue)SelectedModel"), !saved.isEmpty {
                selectedModels[provider] = saved
            }
        }
        refreshValidity()
    }

    private func refreshValidity() {
        isAPIKeyValid = true
    }

    func selectModel(_ model: String) { selectModel(model, for: selectedProvider) }

    func selectModel(_ model: String, for provider: AIProvider) {
        let resolved = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolved.isEmpty else { return }
        let value = resolved
        selectedModels[provider] = value
        userDefaults.set(value, forKey: "\(provider.rawValue)SelectedModel")
        if provider == .ollama { updateSelectedOllamaModel(value) }
        objectWillChange.send()
        NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
    }

    // MARK: - Ollama (kun localhost)

    func checkOllamaConnection(completion: @escaping (Bool) -> Void) {
        Task { [weak self] in
            guard let self else { return }
            _ = await self.refreshOllamaAvailability()
            await MainActor.run { completion(self.ollamaService.isConnected) }
        }
    }

    func refreshOllamaAvailabilityInBackground() {
        Task { [weak self] in _ = await self?.refreshOllamaAvailability() }
    }

    @MainActor
    @discardableResult
    func refreshOllamaConnectionAndModels() async -> [OllamaModel] {
        await refreshOllamaAvailability().models
    }

    @MainActor
    func refreshOllamaAvailability() async -> OllamaRefreshResult {
        guard !isOllamaRefreshing else {
            return OllamaRefreshResult(models: ollamaService.availableModels, errorMessage: nil)
        }
        isOllamaRefreshing = true
        defer {
            isOllamaRefreshing = false
            NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
        }
        switch await ollamaService.refreshConnectionAndModels() {
        case .success(let models):
            return OllamaRefreshResult(models: models, errorMessage: nil)
        case .failure(let error):
            return OllamaRefreshResult(models: [], errorMessage: error.localizedDescription)
        }
    }

    /// Ollama-adressen lige nu (bruges til at afgøre, hvad en assistentsamtale må sende).
    var ollamaBaseURLString: String { ollamaService.baseURL }

    func enhanceWithOllama(
        text: String, systemPrompt: String, model: String? = nil, timeout: TimeInterval = 30
    ) async throws -> String {
        try await ollamaService.enhance(text, withSystemPrompt: systemPrompt, model: model, timeout: timeout)
    }

    func updateOllamaBaseURL(_ newURL: String) {
        ollamaService.baseURL = newURL
        userDefaults.set(newURL, forKey: "ollamaBaseURL")
    }

    func updateSelectedOllamaModel(_ modelName: String) {
        ollamaService.selectedModel = modelName
        userDefaults.set(modelName, forKey: "ollamaSelectedModel")
    }
}
