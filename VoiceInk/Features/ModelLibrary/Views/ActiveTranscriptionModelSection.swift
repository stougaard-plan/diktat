import SwiftUI

/// Valg af transskriberingsmodel direkte under AI-modeller. Valget gælder tilstanden «Diktering»
/// (den ligger bag genvejen), så man ikke skal ind i Tilstande. Mødetransskription har sin egen model.
struct ActiveTranscriptionModelSection: View {
    @EnvironmentObject private var transcriptionModelManager: TranscriptionModelManager
    @ObservedObject private var modeManager = ModeManager.shared

    static let dictationModeID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!

    private var dictationMode: ModeConfig? { modeManager.getConfiguration(with: Self.dictationModeID) }

    private var selectedKey: String { dictationMode?.selectedTranscriptionModelName ?? "" }

    private var usable: [any TranscriptionModel] {
        transcriptionModelManager.usableModels.sorted { $0.displayName < $1.displayName }
    }

    private var binding: Binding<String> {
        Binding(
            get: { selectedKey },
            set: { key in
                guard let model = usable.first(where: { $0.selectionKey == key }) else { return }
                apply(model)
            })
    }

    private func apply(_ model: any TranscriptionModel) {
        guard var config = modeManager.getConfiguration(with: Self.dictationModeID) else { return }
        config.selectedTranscriptionModelName = model.selectionKey
        config.selectedLanguage = TranscriptionLanguageSupport.validLanguageOrFallback(
            config.selectedLanguage, for: model, realtimeEnabled: config.isRealtimeTranscriptionEnabled)
        modeManager.updateConfiguration(config)
        if modeManager.activeConfiguration?.id == config.id { modeManager.setActiveConfiguration(config) }
        transcriptionModelManager.setDefaultTranscriptionModel(model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Aktiv transskriberingsmodel").font(.headline)
            if let mode = dictationMode {
                HStack {
                    Text("Model til «\(mode.name)»")
                    Spacer()
                    Picker("", selection: binding) {
                        if !usable.contains(where: { $0.selectionKey == selectedKey }) {
                            Text(selectedKey.isEmpty ? "Ingen valgt" : "\(selectedKey) (ikke hentet)").tag(selectedKey)
                        }
                        ForEach(usable, id: \.selectionKey) { model in
                            Text(model.displayName).tag(model.selectionKey)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 280)
                }
                Text("Gælder tilstanden «\(mode.name)», altså almindelig diktering med genvejen. Kun modeller, der er hentet, kan vælges. Mødetransskription bruger sin egen model (se Møder).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let effective = modeManager.currentEffectiveConfiguration, effective.id != mode.id {
                    Label("Lige nu er tilstanden «\(effective.name)» aktiv, så dikteringen bruger dens model, ikke denne.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(Color.orange).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Tilstanden «Diktering» findes ikke. Opret den under Tilstande, så kan modellen vælges her.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppMaterialCardBackground(cornerRadius: 10))
    }
}
