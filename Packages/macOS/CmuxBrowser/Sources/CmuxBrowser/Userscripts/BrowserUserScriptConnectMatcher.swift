public import Foundation

/// Evaluates Tampermonkey-style `@connect` declarations for privileged requests.
public struct BrowserUserScriptConnectMatcher: Sendable {
    /// Creates a matcher.
    public init() {}

    /// Returns whether a userscript may connect to `url`.
    /// - Parameters:
    ///   - url: The outbound request URL.
    ///   - pageURL: The page origin used for the `self` rule.
    ///   - connects: Parsed `@connect` declarations. An empty list is treated as
    ///     permissive for compatibility with scripts written before cmux enforced
    ///     connect metadata.
    public func allows(url: URL, pageURL: URL?, connects: [String]) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return false
        }

        let rules = connects.compactMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
        guard !rules.isEmpty else { return true }
        return rules.contains { ruleAllows(rule: $0, url: url, pageURL: pageURL) }
    }

    private func ruleAllows(rule: String, url: URL, pageURL: URL?) -> Bool {
        let lowercasedRule = rule.lowercased()
        if lowercasedRule == "*" {
            return true
        }
        if lowercasedRule == "self" {
            return sameOrigin(url, pageURL)
        }
        if let separator = lowercasedRule.range(of: "://") {
            return schemeRuleAllows(rule: lowercasedRule, separator: separator, url: url)
        }
        return hostRuleAllows(rule: lowercasedRule, url: url)
    }

    private func schemeRuleAllows(rule: String, separator: Range<String.Index>, url: URL) -> Bool {
        let schemeRule = String(rule[..<separator.lowerBound])
        guard schemeRule == "*" || schemeRule == url.scheme?.lowercased() else {
            return false
        }

        let remainder = String(rule[separator.upperBound...])
        let slashIndex = remainder.firstIndex(of: "/")
        let hostAndPort = slashIndex.map { String(remainder[..<$0]) } ?? remainder
        guard hostAndPort.isEmpty == false else { return false }
        let pathRule = slashIndex.map { String(remainder[$0...]) }

        guard hostAndPort == "*" || hostRuleAllows(rule: hostAndPort, url: url) else {
            return false
        }
        guard let pathRule, pathRule.isEmpty == false else { return true }
        let path = url.path.isEmpty ? "/" : url.path
        return BrowserUserScriptMatchPattern.wildcardMatches(pattern: pathRule, value: path)
    }

    private func hostRuleAllows(rule: String, url: URL) -> Bool {
        guard let urlHost = normalizedHost(url.host) else { return false }
        let (hostRule, portRule) = splitHostPort(rule)
        if let portRule, portRule != normalizedPort(url) {
            return false
        }
        if hostRule == "*" {
            return true
        }
        if hostRule.hasPrefix("*.") {
            let suffix = String(hostRule.dropFirst(2))
            return urlHost == suffix || urlHost.hasSuffix(".\(suffix)")
        }
        if hostRule.contains("*") {
            return BrowserUserScriptMatchPattern.wildcardMatches(
                pattern: hostRule,
                value: urlHost,
                caseInsensitive: true
            )
        }
        return urlHost == hostRule || urlHost.hasSuffix(".\(hostRule)")
    }

    private func sameOrigin(_ url: URL, _ pageURL: URL?) -> Bool {
        guard let pageURL,
              url.scheme?.lowercased() == pageURL.scheme?.lowercased(),
              normalizedHost(url.host) == normalizedHost(pageURL.host),
              normalizedPort(url) == normalizedPort(pageURL) else {
            return false
        }
        return true
    }

    private func normalizedHost(_ host: String?) -> String? {
        guard let host else { return nil }
        let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return normalized.nilIfEmpty
    }

    private func normalizedPort(_ url: URL) -> Int {
        if let port = url.port {
            return port
        }
        switch url.scheme?.lowercased() {
        case "http":
            return 80
        case "https":
            return 443
        default:
            return -1
        }
    }

    private func splitHostPort(_ value: String) -> (host: String, port: Int?) {
        guard let colon = value.lastIndex(of: ":"),
              value[value.index(after: colon)...].allSatisfy(\.isNumber),
              value[..<colon].contains(":") == false else {
            return (value, nil)
        }
        let host = String(value[..<colon])
        let port = Int(value[value.index(after: colon)...])
        return (host, port)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
