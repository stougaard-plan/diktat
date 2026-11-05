import Foundation
import SwiftUI

/// Enkelt SF Symbol-ikon pr. model. Ingen udbyder-logoer (alt er lokalt).
struct ModelProviderIcon: View {
    let modelName: String
    let kind: ModelInsightKind
    var size: CGFloat = 24

    private var systemImage: String {
        let lower = modelName.lowercased()
        switch kind {
        case .transcription:
            if lower.contains("apple") { return "apple.logo" }
            if lower.contains("parakeet") || lower.contains("nemotron") { return "waveform" }
            return "captions.bubble.fill"
        case .enhancement:
            return "server.rack"
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: max(7, size * 0.25))
                .fill(AppTheme.Surface.control)
                .overlay(
                    RoundedRectangle(cornerRadius: max(7, size * 0.25))
                        .stroke(AppTheme.Border.control.opacity(0.2), lineWidth: 1)
                )
            Image(systemName: systemImage)
                .font(.system(size: max(12, size * 0.54), weight: .semibold))
                .foregroundStyle(Color.secondary)
        }
        .frame(width: size, height: size)
        .help(modelName)
    }
}
