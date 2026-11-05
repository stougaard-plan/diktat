import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ModelManagementView: View {
    @EnvironmentObject private var aiService: AIService
    @EnvironmentObject private var whisperModelManager: WhisperModelManager
    @EnvironmentObject private var transcriptionModelManager: TranscriptionModelManager
    @ObservedObject private var warmupCoordinator = WhisperModelWarmupCoordinator.shared

    @State private var activePanel: ModelManagementPanel?

    @State private var isShowingDeleteAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var deleteActionClosure: () -> Void = {}

    private enum ModelManagementPanel {
        case settings
    }

    private var isSettingsPanelOpen: Bool {
        if case .settings? = activePanel { return true }
        return false
    }

    private var isPanelOpen: Bool {
        activePanel != nil
    }

    private func closePanel() {
        activePanel = nil
    }

    private func toggleSettingsPanel() {
        activePanel = isSettingsPanelOpen ? nil : .settings
    }

    var body: some View {
        VStack(spacing: 0) {
            headerSection

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    availableModelsSection
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 600, minHeight: 500)
        .sidePanel(
            isPresented: .init(
                get: { isPanelOpen },
                set: { if !$0 { closePanel() } }
            )
        ) {
            modelPanelContent
        }
        .alert(isPresented: $isShowingDeleteAlert) {
            Alert(
                title: Text(alertTitle),
                message: Text(alertMessage),
                primaryButton: .destructive(Text("Delete"), action: deleteActionClosure),
                secondaryButton: .cancel()
            )
        }
    }

    private var headerSection: some View {
        AppScreenHeader(title: "Modeller") {
            settingsButton
        }
    }

    @ViewBuilder
    private var modelPanelContent: some View {
        switch activePanel {
        case .settings:
            settingsPanelContent
        case nil:
            EmptyView()
        }
    }

    private var settingsPanelContent: some View {
        VStack(spacing: 0) {
            AppPanelHeader(title: "Model Settings", onClose: closePanel)

            ModelSettingsPanel()
        }
    }

    private var availableModelsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            localModelsSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var settingsButton: some View {
        AppIconButton(
            systemName: "gearshape.fill",
            help: "Model Settings"
        ) {
            toggleSettingsPanel()
        }
    }

    private var localModelsSection: some View {
        VStack(spacing: 12) {
            ActiveTranscriptionModelSection()

            TranscriptionLanguageSection()

            TextCleanupSection()
                .environmentObject(aiService)

            ForEach(appleSpeechModels, id: \.id) { model in
                localModelCard(model)
            }

            ForEach(downloadableLocalModels, id: \.id) { model in
                localModelCard(model)
            }

            importLocalModelButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func localModelCard(_ model: any TranscriptionModel) -> some View {
        let isWarming =
            (model as? WhisperModel).map { whisperModel in
                warmupCoordinator.isWarming(modelNamed: whisperModel.name)
            } ?? false

        return ModelCardView(
            model: model,
            isDownloaded: whisperModelManager.availableModels.contains { $0.name == model.name },
            downloadProgress: whisperModelManager.downloadProgress,
            modelURL: whisperModelManager.availableModels.first { $0.name == model.name }?.url,
            isWarming: isWarming,
            deleteAction: {
                deleteLocalModel(model)
            },
            downloadAction: {
                if let whisperModel = model as? WhisperModel {
                    whisperModelManager.startDownload(whisperModel)
                }
            },
            cancelDownloadAction: {
                if let whisperModel = model as? WhisperModel {
                    whisperModelManager.cancelDownload(whisperModel)
                }
            }
        )
    }

    private var importLocalModelButton: some View {
        HStack(spacing: 8) {
            Button(action: { presentImportPanel() }) {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.down")
                    Text("Import Local Model…")
                        .font(.system(size: 12, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(16)
                .background(AppMaterialCardBackground(cornerRadius: 10))
            }
            .buttonStyle(.plain)

            InfoTip("Tilføj en egen Whisper-model (.bin-fil), som allerede ligger på Mac'en.")
        }
    }

    private var localModels: [any TranscriptionModel] {
        transcriptionModelManager.allAvailableModels.filter {
            ($0.provider == .whisper || $0.provider == .nativeApple || $0.provider == .fluidAudio
                || $0.provider == .transcribeCpp)
                && transcriptionModelManager.isAvailableOnCurrentOS($0)
        }
    }

    private var appleSpeechModels: [any TranscriptionModel] {
        localModels.filter { $0.provider == .nativeApple }
    }

    private var downloadableLocalModels: [any TranscriptionModel] {
        localModels.filter { $0.provider != .nativeApple }
    }

    private func deleteLocalModel(_ model: any TranscriptionModel) {
        guard let downloadedModel = whisperModelManager.availableModels.first(where: { $0.name == model.name }) else {
            return
        }

        Task {
            await whisperModelManager.deleteModel(downloadedModel)
        }
    }

    private func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "bin")!]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.resolvesAliases = true
        panel.title = String(localized: "Select a Whisper ggml .bin model")
        if panel.runModal() == .OK, let url = panel.url {
            Task { @MainActor in
                await whisperModelManager.importWhisperModel(from: url)
            }
        }
    }
}
