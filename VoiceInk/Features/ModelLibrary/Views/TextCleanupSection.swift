import SwiftUI

/// Samlet, synlig indgang til oprydning af diktat. Viser om den er til eller fra for den aktive mode,
/// hvilken model der bruges, og hvor Ollama kører. Fra er standard. Fejler oprydningen, indsættes den rå tekst.
struct TextCleanupSection: View {
    @EnvironmentObject private var aiService: AIService
    @EnvironmentObject private var enhancementService: AIEnhancementService
    @ObservedObject private var modeManager = ModeManager.shared
    @AppStorage(OllamaHostPolicy.allowRemoteKey) private var allowRemoteHost = false
    @AppStorage(OllamaHostPolicy.sendVocabularyRemoteKey) private var sendVocabularyRemote = false
    @State private var message: String?

    private var mode: ModeConfig? { modeManager.currentEffectiveConfiguration }
    private var provider: AIProvider? { mode?.selectedAIProvider.flatMap { AIProvider(rawValue: $0) } }
    private var isOn: Bool { mode?.isAIEnhancementEnabled == true }

    private var modelDescription: String {
        guard let provider else { return "ingen model valgt" }
        switch provider {
        case .ollama:
            let model = mode?.selectedAIModel ?? aiService.selectedModel(for: .ollama)
            let url = UserDefaults.standard.string(forKey: "ollamaBaseURL") ?? "http://localhost:11434"
            return "Ollama, model \(model), adresse \(url)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Oprydning af tekst").font(.headline)
                Spacer()
                Text(isOn ? "TIL" : "FRA")
                    .font(.system(size: 11, weight: .bold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(isOn ? Color.green.opacity(0.25) : Color.secondary.opacity(0.2)))
            }
            Toggle(
                "Ryd op i diktatet med en sprogmodel (mode «\(mode?.name ?? "")»)",
                isOn: Binding(get: { isOn }, set: { setEnabled($0) })
            )
            .disabled(mode == nil)
            Text(isOn ? "Bruger: \(modelDescription)" : "Slået fra. Diktatet indsættes, som modellen skrev det. Model, hvis den slås til: \(modelDescription).")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Fejler oprydningen, er den for langsom eller giver et tomt svar, indsættes den rå tekst, så intet diktat går tabt.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let message {
                Text(message).font(.caption).foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Tillad anden maskine på mit netværk (fx en anden Mac hjemme hos dig)", isOn: $allowRemoteHost)
                .onChange(of: allowRemoteHost) { _, _ in aiService.refreshOllamaAvailabilityInBackground() }
            Text(
                allowRemoteHost
                    ? "Tekst fra dine diktater sendes ukrypteret til den anden maskine. Brug kun en adresse på dit eget netværk. Offentlige adresser afvises."
                    : "Fra: Ollama skal køre på denne Mac (localhost). Andre adresser afvises."
            )
            .font(.caption).foregroundStyle(allowRemoteHost ? Color.orange : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if allowRemoteHost {
                Toggle("Send også min ordliste og navne fra skærmen til den anden maskine", isOn: $sendVocabularyRemote)
                Text(
                    sendVocabularyRemote
                        ? "Til: ordlisten (dine egne ord og navne) følger med til den anden maskine, ukrypteret."
                        : "Fra: ordlisten sendes ikke til den anden maskine. Selve diktatet og evt. markeret tekst, udklipsholder og skærmtekst følger stadig med."
                )
                .font(.caption).foregroundStyle(sendVocabularyRemote ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            LocalEnhancementServiceManagementView()
                .environmentObject(aiService)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppMaterialCardBackground(cornerRadius: 10))
    }

    private func setEnabled(_ enable: Bool) {
        message = nil
        guard enable else {
            modeManager.updateCurrentEffectiveConfiguration { $0.isAIEnhancementEnabled = false }
            return
        }
        let connected = aiService.connectedProviders
        let chosen = provider.flatMap { connected.contains($0) ? $0 : nil } ?? connected.first
        guard let chosen else {
            message = "Ingen oprydningsmodel er forbundet. Forbind Ollama herunder, før du slår oprydning til."
            return
        }
        let promptId = mode?.selectedPrompt ?? enhancementService.allPrompts.first?.id.uuidString
        if chosen == .ollama, promptId == nil {
            message = "Der mangler en prompt til oprydningen. Opret en under Modes."
            return
        }
        modeManager.updateCurrentEffectiveConfiguration {
            $0.isAIEnhancementEnabled = true
            $0.selectedAIProvider = chosen.rawValue
            if chosen == .ollama, ($0.selectedAIModel ?? "").isEmpty {
                $0.selectedAIModel = aiService.selectedModel(for: .ollama)
            }
            $0.selectedPrompt = promptId
        }
    }
}
