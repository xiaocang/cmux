import Foundation

/// Errors thrown when converting userscript values.
public enum BrowserUserScriptValueError: Error, Sendable, Equatable {
    /// The supplied object cannot be represented as JSON.
    case unsupportedValue
}
