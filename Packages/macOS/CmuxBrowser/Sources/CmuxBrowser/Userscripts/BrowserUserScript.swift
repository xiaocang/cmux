import Foundation

/// A persisted browser userscript and its parsed metadata.
public struct BrowserUserScript: Codable, Sendable, Equatable, Identifiable {
    /// Stable script identifier used by management commands and storage shims.
    public var id: String

    /// Whether the script should be installed into new browser web views.
    public var enabled: Bool

    /// Original userscript source.
    public var source: String

    /// Parsed userscript header metadata.
    public var metadata: BrowserUserScriptMetadata

    /// Creates a browser userscript.
    public init(
        id: String,
        enabled: Bool,
        source: String,
        metadata: BrowserUserScriptMetadata
    ) {
        self.id = id
        self.enabled = enabled
        self.source = source
        self.metadata = metadata
    }
}
