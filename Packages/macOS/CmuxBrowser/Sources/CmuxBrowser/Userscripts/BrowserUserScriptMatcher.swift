public import Foundation

/// Evaluates userscript metadata against URLs.
public struct BrowserUserScriptMatcher: Sendable {
    /// Creates a matcher.
    public init() {}

    /// Returns whether a userscript should run for a URL.
    /// - Parameters:
    ///   - script: The script to evaluate.
    ///   - url: The current page URL.
    public func matches(script: BrowserUserScript, url: URL) -> Bool {
        guard script.enabled else { return false }
        let metadata = script.metadata
        let hasPositiveRules = !metadata.matches.isEmpty || !metadata.includes.isEmpty
        let positive = !hasPositiveRules
            || metadata.matches.contains { BrowserUserScriptMatchPattern($0)?.matches(url) == true }
            || metadata.includes.contains { BrowserUserScriptMatchPattern.wildcardMatches(pattern: $0, value: url.absoluteString) }

        guard positive else { return false }

        let excluded = metadata.excludeMatches.contains { BrowserUserScriptMatchPattern($0)?.matches(url) == true }
            || metadata.excludes.contains { BrowserUserScriptMatchPattern.wildcardMatches(pattern: $0, value: url.absoluteString) }
        return !excluded
    }
}
