import Foundation

enum CustomCommandTemplate: String, CaseIterable, Identifiable {
    case pasteAndPressTab
    case lowercaseAndPaste
    case removeTrailingPeriodAndPaste
    case appendToJournal

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pasteAndPressTab:
            return String(localized: "Paste and Press Tab")
        case .lowercaseAndPaste:
            return String(localized: "Lowercase and Paste")
        case .removeTrailingPeriodAndPaste:
            return String(localized: "Remove Trailing Period and Paste")
        case .appendToJournal:
            return String(localized: "Append to Journal")
        }
    }

    var command: String {
        switch self {
        case .pasteAndPressTab:
            return """
                printf "%s" "$VOICEINK_TRANSCRIPT" | pbcopy
                osascript <<'APPLESCRIPT'
                tell application "System Events"
                    keystroke "v" using command down
                    delay 1
                    key code 48
                end tell
                APPLESCRIPT
                """
        case .lowercaseAndPaste:
            return """
                printf "%s" "$VOICEINK_TRANSCRIPT" | tr '[:upper:]' '[:lower:]' | pbcopy
                osascript <<'APPLESCRIPT'
                tell application "System Events"
                    keystroke "v" using command down
                end tell
                APPLESCRIPT
                """
        case .removeTrailingPeriodAndPaste:
            return """
                printf "%s" "$VOICEINK_TRANSCRIPT" | perl -CS -pe 's/(?<!\\.)\\.(\\s*)$/$1/' | pbcopy
                osascript <<'APPLESCRIPT'
                tell application "System Events"
                    keystroke "v" using command down
                end tell
                APPLESCRIPT
                """
        case .appendToJournal:
            return """
                mkdir -p "$HOME/Documents/Diktat"
                journal="$HOME/Documents/Diktat/journal.md"
                timestamp=$(date "+%Y-%m-%d %H:%M")
                printf -- "- **%s** %s\\n" "$timestamp" "$VOICEINK_TRANSCRIPT" >> "$journal"
                """
        }
    }
}
