import SwiftUI

/// Sprogvalg for den aktive transskriberingsmodel, øverst under Modeller. Viser det sprog optagelsen faktisk bruger,
/// og siger ærligt, om modellen kan låses til det.
struct TranscriptionLanguageSection: View {
    @EnvironmentObject private var transcriptionModelManager: TranscriptionModelManager
    @ObservedObject private var modeManager = ModeManager.shared
    @AppStorage("SelectedLanguage") private var storedLanguage = "da"

    private var resolution: ModeTranscriptionModelResolution {
        ModeRuntimeResolver.transcriptionModelResolution(transcriptionModelManager: transcriptionModelManager)
    }

    private var runtime: TranscriptionRuntimeConfiguration? {
        ModeRuntimeResolver.transcriptionConfiguration(transcriptionModelManager: transcriptionModelManager)
    }

    private func displayName(_ code: String) -> String {
        if code == "auto" { return "Automatisk" }
        let name = Locale(identifier: "da").localizedString(forIdentifier: code) ?? code
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sprog i transskriberingsmodellen").font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppMaterialCardBackground(cornerRadius: 10))
    }

    @ViewBuilder
    private var content: some View {
        if let runtime {
            let model = runtime.model
            let languages = TranscriptionLanguageSupport.languages(for: model)
            let info = TranscriptionLanguageLock.info(
                provider: model.provider.rawValue, modelName: model.name,
                language: runtime.language, isMultilingual: model.isMultilingualModel)

            HStack {
                Text("Aktiv model: \(model.displayName)")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
            }
            if languages.count > 1 {
                HStack {
                    Text("Sprog")
                    Spacer()
                    Picker("", selection: languageBinding(for: model)) {
                        ForEach(
                            languages.sorted(by: {
                                if $0.key == "auto" { return true }
                                if $1.key == "auto" { return false }
                                return $0.value < $1.value
                            }), id: \.key
                        ) { key, value in
                            Text(value).tag(key)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }
            } else {
                Text("Sprog: \(displayName(runtime.language))").font(.system(size: 13))
            }
            Text("Bruges ved næste optagelse: \(displayName(runtime.language)), mode «\(runtime.mode.name)».")
                .font(.caption).foregroundStyle(.secondary)
            Label(info.text, systemImage: info.strength == .locked ? "lock.fill" : "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(info.strength == .locked ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(overrideNotes(runtime), id: \.self) { note in
                Label(note, systemImage: "arrow.triangle.branch")
                    .font(.caption).foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text("Ingen brugbar transskriberingsmodel er valgt i den aktive mode. Vælg en model under Modes.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func overrideNotes(_ runtime: TranscriptionRuntimeConfiguration) -> [String] {
        let others = modeManager.configurations.filter { $0.isEnabled && $0.id != runtime.mode.id }
            .map { (name: $0.name, language: $0.selectedLanguage) }
        return TranscriptionLanguageLock.overrideNotes(
            effectiveModeName: runtime.mode.name, effectiveLanguage: runtime.mode.selectedLanguage,
            chosenLanguage: runtime.language, otherModes: others, displayName: displayName)
    }

    /// Ét valg sætter både standardsproget og den aktive modes sprog, så visningen og optagelsen er samme værdi.
    private func languageBinding(for model: any TranscriptionModel) -> Binding<String> {
        Binding(
            get: { runtime?.language ?? storedLanguage },
            set: { newValue in
                storedLanguage = newValue
                modeManager.updateCurrentEffectiveConfiguration { $0.selectedLanguage = newValue }
                NotificationCenter.default.post(name: .languageDidChange, object: nil)
                NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
            }
        )
    }
}
