import Foundation

/// A userscript `@run-at` phase.
public enum BrowserUserScriptRunAt: String, Codable, Sendable, Equatable {
    /// Run as early as WebKit allows during document creation.
    case documentStart = "document-start"

    /// Run after the document has loaded enough for end-of-document scripts.
    case documentEnd = "document-end"

    /// Run after the document reaches an idle callback or a short fallback delay.
    case documentIdle = "document-idle"

    /// Parses a userscript metadata value.
    /// - Parameter value: The raw `@run-at` metadata value.
    public init(metadataValue value: String) {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "document-start":
            self = .documentStart
        case "document-idle":
            self = .documentIdle
        default:
            self = .documentEnd
        }
    }
}
