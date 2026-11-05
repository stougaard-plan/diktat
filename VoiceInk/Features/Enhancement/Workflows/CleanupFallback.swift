import Foundation

/// Vagt om oprydningslaget: ingen fejl, timeout eller tomt svar må koste et diktat.
/// Kalderen får enten det ryddede resultat eller en fejl og beholder i så fald den rå tekst.
enum CleanupFallback {
    enum Outcome<R> {
        case enhanced(R)
        case fellBack(Error)
    }

    static func run<R>(
        raw: String, text: (R) -> String, emptyError: Error, operation: () async throws -> R
    ) async -> Outcome<R> {
        do {
            let result = try await operation()
            let rawHasContent = !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if rawHasContent, text(result).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .fellBack(emptyError)
            }
            return .enhanced(result)
        } catch {
            return .fellBack(error)
        }
    }

    /// Teksten der leveres: det ryddede, hvis oprydningen lykkedes, ellers den rå tekst.
    static func deliveredText<R>(raw: String, outcome: Outcome<R>, text: (R) -> String) -> String {
        switch outcome {
        case .enhanced(let result): return text(result)
        case .fellBack: return raw
        }
    }
}
