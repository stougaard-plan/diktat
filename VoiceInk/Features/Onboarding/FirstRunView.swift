import AVFoundation
import AppKit
import SwiftUI

/// Første opstart: tilladelser, en sprogmodel (Whisper anbefales til dansk, Parakeet V3 er valgfri) og genvejstast. Intet andet.
struct FirstRunView: View {
    @Binding var hasCompleted: Bool
    @EnvironmentObject var fluidAudioModelManager: FluidAudioModelManager
    @EnvironmentObject var whisperModelManager: WhisperModelManager
    @EnvironmentObject var transcriptionModelManager: TranscriptionModelManager

    @State private var micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var accessibilityGranted = AXIsProcessTrusted()
    @State private var hasShortcut = ShortcutStore.shortcut(for: .primaryRecording) != nil

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var model: FluidAudioModel? {
        TranscriptionModelRegistry.models
            .compactMap { $0 as? FluidAudioModel }
            .first { $0.name == StarterModeFactory.defaultTranscriptionModelName }
    }

    private var modelReady: Bool {
        model.map { fluidAudioModelManager.isFluidAudioModelDownloaded($0) } ?? false
    }

    private var whisperModel: WhisperModel? {
        TranscriptionModelRegistry.models
            .compactMap { $0 as? WhisperModel }
            .first { $0.name == FirstRunModelChoice.recommendedWhisperName }
    }

    private var installedWhisperNames: [String] { whisperModelManager.availableModels.map(\.name) }

    private var whisperInstalled: Bool { !installedWhisperNames.isEmpty }

    private var whisperDownloading: Bool {
        guard let whisperModel else { return false }
        return whisperModelManager.downloadProgress[whisperModel.name + "_main"] != nil
    }

    /// Kravet er én brugbar model. Nej til Parakeet blokerer ikke.
    private var canFinish: Bool {
        FirstRunModelChoice.isReady(parakeetReady: modelReady, installedWhisperNames: installedWhisperNames)
    }

    private var modelDownloading: Bool {
        model.map { fluidAudioModelManager.isFluidAudioModelDownloading($0) } ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Diktat")
                    .font(.system(size: 28, weight: .semibold))
                Text("Lokal diktering. Lyd og tekst sendes ikke til nogen tjeneste.")
                    .foregroundStyle(.secondary)
            }

            step(
                done: micGranted, title: "Mikrofon",
                text: "Diktat skal kunne høre dig."
            ) {
                Button("Giv adgang") {
                    AVCaptureDevice.requestAccess(for: .audio) { granted in
                        DispatchQueue.main.async { micGranted = granted }
                    }
                }
            }

            step(
                done: accessibilityGranted, title: "Hjælpemidler",
                text: "Bruges til at skrive teksten ind, hvor markøren står."
            ) {
                Button("Åbn indstillinger") {
                    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                    _ = AXIsProcessTrustedWithOptions(options)
                }
            }

            step(
                done: whisperInstalled, title: "Sprogmodel til dansk (anbefalet): Whisper large-v3-turbo-q5_0",
                text: "Hentes én gang fra huggingface.co (ca. 547 MB) og kører derefter lokalt. Kan låses til dansk. Du behøver kun én sprogmodel for at komme videre."
            ) {
                if whisperDownloading {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Hent model") {
                        if let whisperModel { whisperModelManager.startDownload(whisperModel) }
                    }
                    .disabled(whisperModel == nil)
                }
            }

            step(
                done: modelReady, title: "Valgfrit: Parakeet V3",
                text: "Hurtig, men kan ikke låses til dansk og kan vælge et andet sprog på korte klip (ca. 494 MB fra huggingface.co). Du kan trykke Færdig uden den."
            ) {
                if modelDownloading {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Hent model") {
                        if let model { fluidAudioModelManager.startDownload(model) }
                    }
                    .disabled(model == nil)
                }
            }

            step(
                done: hasShortcut, title: "Genvejstast",
                text: "Tast til at starte og stoppe diktering."
            ) {
                ShortcutRecorder(action: .primaryRecording, onShortcutChanged: {
                    hasShortcut = ShortcutStore.shortcut(for: .primaryRecording) != nil
                })
                .fixedSize(horizontal: true, vertical: false)
            }

            HStack {
                Spacer()
                Button("Færdig") { finish() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canFinish)
            }
        }
        .padding(32)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(timer) { _ in
            micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            accessibilityGranted = AXIsProcessTrusted()
            hasShortcut = ShortcutStore.shortcut(for: .primaryRecording) != nil
        }
    }

    private func step<Content: View>(
        done: Bool, title: String, text: String, @ViewBuilder action: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18))
                .foregroundStyle(done ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if !done { action() }
        }
    }

    private func finish() {
        UserDefaults.standard.set("da", forKey: "SelectedLanguage")
        let chosenName = FirstRunModelChoice.chosenModelName(
            parakeetReady: modelReady, installedWhisperNames: installedWhisperNames)
        let chosen: (any TranscriptionModel)? = TranscriptionModelRegistry.models.first { $0.name == chosenName }
        if let chosen { transcriptionModelManager.setDefaultTranscriptionModel(chosen) }
        StarterModeFactory.install(
            kinds: [.clean],
            provider: .ollama,
            modelName: nil,
            transcriptionModelName: chosenName ?? StarterModeFactory.defaultTranscriptionModelName,
            isRealtimeTranscriptionEnabled: false,
            selectedLanguage: "da"
        )
        hasCompleted = true
    }
}
