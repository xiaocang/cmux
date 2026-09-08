public import Foundation

/// A parsed userscript `@match` pattern.
public struct BrowserUserScriptMatchPattern: Sendable, Equatable {
    /// Original pattern string.
    public let rawValue: String

    /// Parsed scheme component.
    public let scheme: String

    /// Parsed host component.
    public let host: String

    /// Parsed path glob.
    public let path: String

    /// Parses a userscript match pattern.
    /// - Parameter rawValue: A pattern such as `https://*.example.com/*`.
    public init?(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = trimmed.range(of: "://") else { return nil }
        let scheme = String(trimmed[..<separator.lowerBound]).lowercased()
        guard ["*", "http", "https", "file"].contains(scheme) else { return nil }
        let remainder = String(trimmed[separator.upperBound...])
        let slash = remainder.firstIndex(of: "/")
        let host = slash.map { String(remainder[..<$0]) } ?? remainder
        let path = slash.map { String(remainder[$0...]) } ?? "/"
        guard !path.isEmpty else { return nil }
        if scheme != "file", host.isEmpty { return nil }

        self.rawValue = trimmed
        self.scheme = scheme
        self.host = host.lowercased()
        self.path = path
    }

    /// Returns whether the pattern matches a URL.
    public func matches(_ url: URL) -> Bool {
        guard matchesScheme(url.scheme?.lowercased()) else { return false }
        guard matchesHost((url.host ?? "").lowercased()) else { return false }
        return Self.wildcardMatches(pattern: path, value: url.path.isEmpty ? "/" : url.path)
    }

    private func matchesScheme(_ urlScheme: String?) -> Bool {
        guard let urlScheme else { return false }
        if scheme == "*" {
            return urlScheme == "http" || urlScheme == "https"
        }
        return scheme == urlScheme
    }

    private func matchesHost(_ urlHost: String) -> Bool {
        if scheme == "file" {
            return true
        }
        if host == "*" {
            return true
        }
        if host.hasPrefix("*.") {
            let suffix = String(host.dropFirst(2))
            return urlHost == suffix || urlHost.hasSuffix(".\(suffix)")
        }
        return host == urlHost
    }

    static func wildcardMatches(pattern: String, value: String, caseInsensitive: Bool = false) -> Bool {
        let pattern = caseInsensitive ? pattern.lowercased() : pattern
        let value = caseInsensitive ? value.lowercased() : value
        if pattern == "*" { return true }
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 1 {
            return pattern == value
        }

        var searchStart = value.startIndex
        for (index, part) in parts.enumerated() {
            if part.isEmpty { continue }
            guard let range = value[searchStart...].range(of: part) else { return false }
            if index == 0 && !pattern.hasPrefix("*") && range.lowerBound != value.startIndex {
                return false
            }
            searchStart = range.upperBound
        }
        if !pattern.hasSuffix("*"), let last = parts.last, !last.isEmpty {
            return value.hasSuffix(last)
        }
        return true
    }
}
