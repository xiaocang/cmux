import Foundation
import Testing
@testable import CmuxBrowser

@Suite("BrowserUserScriptConnectMatcher")
struct BrowserUserScriptConnectMatcherTests {
    let matcher = BrowserUserScriptConnectMatcher()

    @Test func emptyConnectRulesPreserveCompatibilityForHTTPRequests() throws {
        let url = try #require(URL(string: "https://api.example.com/data"))

        #expect(matcher.allows(url: url, pageURL: nil, connects: []))
    }

    @Test func hostRulesSupportExactWildcardAndSchemeScopedMatches() throws {
        let exact = try #require(URL(string: "https://api.example.com/data"))
        let wildcard = try #require(URL(string: "https://assets.example.com/image.png"))
        let nestedSubdomain = try #require(URL(string: "https://v1.api.example.com/data"))
        let wrongHost = try #require(URL(string: "https://other.test/data"))
        let wrongPath = try #require(URL(string: "https://api.example.com/private/data"))

        #expect(matcher.allows(url: exact, pageURL: nil, connects: ["api.example.com"]))
        #expect(matcher.allows(url: nestedSubdomain, pageURL: nil, connects: ["api.example.com"]))
        #expect(matcher.allows(url: wildcard, pageURL: nil, connects: ["*.example.com"]))
        #expect(matcher.allows(url: exact, pageURL: nil, connects: ["https://api.example.com/data*"]))
        #expect(!matcher.allows(url: wrongHost, pageURL: nil, connects: ["*.example.com"]))
        #expect(!matcher.allows(url: wrongPath, pageURL: nil, connects: ["https://api.example.com/data*"]))
    }

    @Test func selfRuleRequiresSameOrigin() throws {
        let pageURL = try #require(URL(string: "https://claude.ai/chat"))
        let sameOrigin = try #require(URL(string: "https://claude.ai/api"))
        let crossOrigin = try #require(URL(string: "https://api.claude.ai/data"))

        #expect(matcher.allows(url: sameOrigin, pageURL: pageURL, connects: ["self"]))
        #expect(!matcher.allows(url: crossOrigin, pageURL: pageURL, connects: ["self"]))
    }

    @Test func nonHTTPRequestsAreRejected() throws {
        let fileURL = try #require(URL(string: "file:///tmp/data.txt"))

        #expect(!matcher.allows(url: fileURL, pageURL: nil, connects: ["*"]))
    }
}
