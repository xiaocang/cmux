import Foundation
import Testing
@testable import CmuxBrowser

@Suite("BrowserUserScriptParser")
struct BrowserUserScriptParserTests {
    @Test func parsesMetadataBlock() throws {
        let script = BrowserUserScriptParser().parse(source: """
        // ==UserScript==
        // @name Claude Helper
        // @namespace cmux.test
        // @version 1.2.3
        // @description Adds a helper button
        // @author cmux
        // @copyright 2026
        // @icon https://cdn.example.com/icon.svg
        // @icon64 https://cdn.example.com/icon64.png
        // @homepageURL https://example.com/home
        // @updateURL https://example.com/update.user.js
        // @downloadURL https://example.com/download.user.js
        // @supportURL https://example.com/support
        // @antifeature ads displays test ads
        // @tag ai
        // @match https://claude.ai/*
        // @match https://*.anthropic.com/*
        // @include https://example.com/path/*
        // @exclude https://claude.ai/settings*
        // @exclude-match https://*.anthropic.com/admin/*
        // @run-at document-start
        // @run-in normal-tabs
        // @sandbox JavaScript
        // @grant GM_getValue
        // @grant GM_setValue
        // @require https://cdn.example.com/a.js
        // @resource icon https://cdn.example.com/icon.png
        // @connect api.example.com
        // @connect *.anthropic.com
        // @domain legacy.example.com
        // @webRequest [{"selector":"*://api.example.com/*","action":"cancel"}]
        // @noframes
        // @unwrap
        // ==/UserScript==
        console.log("ok");
        """)

        #expect(script.metadata.name == "Claude Helper")
        #expect(script.metadata.namespace == "cmux.test")
        #expect(script.metadata.version == "1.2.3")
        #expect(script.metadata.description == "Adds a helper button")
        #expect(script.metadata.author == "cmux")
        #expect(script.metadata.copyright == "2026")
        #expect(script.metadata.icon == "https://cdn.example.com/icon.svg")
        #expect(script.metadata.icon64 == "https://cdn.example.com/icon64.png")
        #expect(script.metadata.homepage == "https://example.com/home")
        #expect(script.metadata.updateURL == "https://example.com/update.user.js")
        #expect(script.metadata.downloadURL == "https://example.com/download.user.js")
        #expect(script.metadata.supportURL == "https://example.com/support")
        #expect(script.metadata.antifeatures == ["ads displays test ads"])
        #expect(script.metadata.tags == ["ai"])
        #expect(script.metadata.matches == ["https://claude.ai/*", "https://*.anthropic.com/*"])
        #expect(script.metadata.includes == ["https://example.com/path/*"])
        #expect(script.metadata.excludes == ["https://claude.ai/settings*"])
        #expect(script.metadata.excludeMatches == ["https://*.anthropic.com/admin/*"])
        #expect(script.metadata.runAt == .documentStart)
        #expect(script.metadata.runIn == ["normal-tabs"])
        #expect(script.metadata.sandbox == "JavaScript")
        #expect(script.metadata.grants == ["GM_getValue", "GM_setValue"])
        #expect(script.metadata.requires == ["https://cdn.example.com/a.js"])
        #expect(script.metadata.resources["icon"] == "https://cdn.example.com/icon.png")
        #expect(script.metadata.connects == ["api.example.com", "*.anthropic.com", "legacy.example.com"])
        #expect(script.metadata.webRequests == ["[{\"selector\":\"*://api.example.com/*\",\"action\":\"cancel\"}]"])
        #expect(script.metadata.noframes)
        #expect(script.metadata.unwrap)
        #expect(script.id.hasPrefix("claude-helper-"))
    }

    @Test func defaultsUnnamedScriptsToAllHttpPages() {
        let script = BrowserUserScriptParser().parse(source: "console.log('raw');")

        #expect(script.metadata.name == "Untitled Userscript")
        #expect(script.metadata.matches == ["*://*/*"])
        #expect(script.metadata.runAt == .documentEnd)
        #expect(script.metadata.connects.isEmpty)
        #expect(!script.metadata.noframes)
        #expect(script.metadata.runIn.isEmpty)
        #expect(script.metadata.sandbox == nil)
        #expect(script.metadata.webRequests.isEmpty)
        #expect(!script.metadata.unwrap)
    }
}
