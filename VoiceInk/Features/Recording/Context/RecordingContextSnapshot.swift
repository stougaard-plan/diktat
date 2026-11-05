import AppKit
import Foundation

struct RecordingContextSnapshot {
    var capturedAt = Date()
    var selectedText: String?
    var clipboardText: String?
    var screenText: String?
}

@MainActor
final class RecordingContextSnapshotStore {
    private(set) var snapshot = RecordingContextSnapshot()
    let vocabularyPreparation: RecordingVocabularyPreparation

    init(savedVocabulary: RecordingVocabulary) {
        vocabularyPreparation = RecordingVocabularyPreparation(savedVocabulary: savedVocabulary)
    }

    func updateClipboardText(_ text: String?) {
        snapshot.clipboardText = Self.normalized(text)
    }

    func updateScreenText(_ text: String?) {
        snapshot.screenText = Self.normalized(text)
    }

    private static func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

@MainActor
enum RecordingContextCaptureService {
    /// Skærmlæsning (OCR) starter KUN, hvis brugeren har slået «Skærm» til i den aktive mode
    /// (`screenCaptureEnabled`) OG macOS har givet tilladelsen. Tilladelsen alene er ikke et tilvalg.
    static func startCapture(
        into store: RecordingContextSnapshotStore,
        language: String?,
        screenCaptureEnabled: Bool,
        hasPermission: @escaping @MainActor () -> Bool = { CGPreflightScreenCaptureAccess() },
        extractText: @escaping @MainActor () async -> String? = { await ScreenCaptureService().captureAndExtractText() }
    ) -> [Task<Void, Never>] {
        guard screenCaptureEnabled else { return [] }
        let screenCapture = Task { @MainActor in
            guard hasPermission(), !Task.isCancelled else { return }
            let screenText = await extractText()
            guard !Task.isCancelled else { return }
            store.updateScreenText(screenText)
            if let text = store.snapshot.screenText {
                store.vocabularyPreparation.prepareScreenNames(in: text, language: language)
            }
        }
        return [screenCapture]
    }
}
