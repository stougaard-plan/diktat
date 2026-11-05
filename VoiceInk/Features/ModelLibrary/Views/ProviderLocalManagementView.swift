import AppKit
import SwiftUI

struct LocalEnhancementServiceManagementView: View {
    @EnvironmentObject private var aiService: AIService

    @State private var isOllamaExpanded = false
    @State private var ollamaBaseURL = UserDefaults.standard.string(forKey: "ollamaBaseURL") ?? "http://localhost:11434"
    @State private var selectedOllamaModel = UserDefaults.standard.string(forKey: "ollamaSelectedModel") ?? "mistral"
    @State private var ollamaUserRefreshError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Ollama")
                    .font(.system(size: 15, weight: .semibold))
            }
            .padding(.top, 8)

            VStack(spacing: 0) {
                LocalProviderDisclosureRow(
                    title: Text(verbatim: "Ollama"),
                    subtitle: ollamaModelNames.isEmpty ? Text("Local server") : Text(localModelCountLabel),
                    systemImage: "server.rack",
                    statusTitle: ollamaStatusTitle,
                    isExpanded: $isOllamaExpanded
                ) {
                    ollamaConfiguration
                }

            }
            .background(AppMaterialCardBackground(cornerRadius: 11))
        }
        .onAppear {
            selectedOllamaModel = aiService.selectedModel(for: .ollama)
        }
    }

    private var ollamaModelNames: [String] {
        aiService.availableModels(for: .ollama)
    }

    private var localModelCountLabel: String {
        let count = ollamaModelNames.count
        return String(localized: "\(count) models")
    }

    private var ollamaStatusTitle: Text {
        if aiService.isOllamaRefreshing {
            return Text("Checking")
        }

        if !aiService.connectedProviders.contains(.ollama) {
            return Text("Disconnected")
        }

        return ollamaModelNames.isEmpty ? Text("No models") : Text(localModelCountLabel)
    }

    private var ollamaActionTitle: LocalizedStringKey {
        aiService.connectedProviders.contains(.ollama) ? "Refresh" : "Connect"
    }

    private var ollamaConfiguration: some View {
        LocalProviderExpandedContent {
            LocalProviderFormRow(title: "Server") {
                HStack(spacing: 8) {
                    TextField("", text: $ollamaBaseURL, prompt: Text(verbatim: "http://localhost:11434"))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                        .disabled(aiService.isOllamaRefreshing)
                        .onChange(of: ollamaBaseURL) { _, _ in
                            ollamaUserRefreshError = nil
                        }

                    Button {
                        ollamaUserRefreshError = nil
                        aiService.updateOllamaBaseURL(ollamaBaseURL)
                        checkOllamaConnectionFromUserAction()
                    } label: {
                        if aiService.isOllamaRefreshing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text(ollamaActionTitle)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(aiService.isOllamaRefreshing)
                }
            }

            if let ollamaUserRefreshError {
                Text(ollamaUserRefreshError)
                    .font(.caption)
                    .foregroundStyle(AppTheme.Status.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, LocalProviderMetrics.labelWidth + 12)
            }

            if !ollamaModelNames.isEmpty {
                Divider()
                    .padding(.leading, LocalProviderMetrics.labelWidth + 12)

                LocalProviderFormRow(title: "Model") {
                    Picker("Model", selection: $selectedOllamaModel) {
                        ForEach(ollamaModelNames, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 320, alignment: .leading)
                    .onChange(of: selectedOllamaModel) { _, newValue in
                        aiService.updateSelectedOllamaModel(newValue)
                        aiService.selectModel(newValue, for: .ollama)
                    }
                }
            }
        }
    }

    private func checkOllamaConnectionFromUserAction() {
        Task { @MainActor in
            let result = await aiService.refreshOllamaAvailability()
            let models = result.models.map(\.name)

            ollamaUserRefreshError = result.errorMessage

            if !models.contains(selectedOllamaModel), let firstModel = models.first {
                selectedOllamaModel = firstModel
                aiService.selectModel(firstModel, for: .ollama)
            }
        }
    }
}

private enum LocalProviderMetrics {
    static let labelWidth: CGFloat = 72
}

private struct LocalProviderDisclosureRow<Content: View>: View {
    let title: Text
    let subtitle: Text
    let systemImage: String
    let statusTitle: Text
    @Binding var isExpanded: Bool
    let content: () -> Content

    init(
        title: Text,
        subtitle: Text,
        systemImage: String,
        statusTitle: Text,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.statusTitle = statusTitle
        self._isExpanded = isExpanded
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.smooth(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: systemImage)
                        .font(.system(size: 14, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(AppTheme.Surface.control)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7)
                                        .stroke(AppTheme.Border.control.opacity(0.3), lineWidth: 1)
                                )
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        title
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)

                        subtitle
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 12)

                    statusTitle
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                    .padding(.leading, 58)

                content()
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 14)
                    .transition(.opacity)
            }
        }
    }
}

private struct LocalProviderExpandedContent<Content: View>: View {
    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LocalProviderFormRow<Content: View>: View {
    let title: LocalizedStringKey
    let content: () -> Content

    init(title: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: LocalProviderMetrics.labelWidth, alignment: .leading)

            content()

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
