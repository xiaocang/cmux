import Foundation
import Testing
@testable import CmuxBrowser

@Suite("BrowserUserScriptMatcher")
struct BrowserUserScriptMatcherTests {
    let matcher = BrowserUserScriptMatcher()
    let parser = BrowserUserScriptParser()

    @Test func matchPatternsSupportWildcardHostsAndExcludes() throws {
        let script = parser.parse(source: """
        // ==UserScript==
        // @name Match Test
        // @match https://*.example.com/app/*
        // @exclude-match https://admin.example.com/app/*
        // ==/UserScript==
        """)

        #expect(matcher.matches(script: script, url: try #require(URL(string: "https://example.com/app/home"))))
        #expect(matcher.matches(script: script, url: try #require(URL(string: "https://docs.example.com/app/home"))))
        #expect(!matcher.matches(script: script, url: try #require(URL(string: "http://docs.example.com/app/home"))))
        #expect(!matcher.matches(script: script, url: try #require(URL(string: "https://admin.example.com/app/home"))))
    }

    @Test func includeAndExcludeGlobsUseFullURL() throws {
        let script = parser.parse(source: """
        // ==UserScript==
        // @name Include Test
        // @include https://*/docs/*
        // @exclude https://example.com/docs/private*
        // ==/UserScript==
        """)

        #expect(matcher.matches(script: script, url: try #require(URL(string: "https://example.com/docs/index?q=1"))))
        #expect(!matcher.matches(script: script, url: try #require(URL(string: "https://example.com/docs/private?q=1"))))
        #expect(!matcher.matches(script: script, url: try #require(URL(string: "https://example.com/blog/index"))))
    }

    @Test func disabledScriptsDoNotMatch() throws {
        let script = parser.parse(source: """
        // ==UserScript==
        // @name Disabled Test
        // @match *://*/*
        // ==/UserScript==
        """, enabled: false)

        #expect(!matcher.matches(script: script, url: try #require(URL(string: "https://example.com/"))))
    }
}
