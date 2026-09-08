import Foundation
import JavaScriptCore
import Testing
@testable import CmuxBrowser

@Suite("BrowserUserScriptSourceBuilder")
struct BrowserUserScriptSourceBuilderTests {
    @Test func executesWithOnlyGrantedAPIsExposed() throws {
        let result = try runProbe(source: """
        // ==UserScript==
        // @name Grant Probe
        // @match https://example.com/*
        // @run-at document-start
        // @grant GM_getValue
        // @grant GM.setValue
        // @grant unsafeWindow
        // ==/UserScript==
        window.__grantProbe = {
          scriptName: GM_info.script.name,
          modernGetValue: typeof GM.getValue,
          modernSetValue: typeof GM.setValue,
          modernDeleteValue: typeof GM.deleteValue,
          legacyGetValue: typeof GM_getValue,
          legacySetValue: typeof GM_setValue,
          legacyDeleteValue: typeof GM_deleteValue,
          unsafeWindowMatches: unsafeWindow === globalThis
        };
        """, probeExpression: "window.__grantProbe")

        #expect(result["scriptName"] as? String == "Grant Probe")
        #expect(result["modernGetValue"] as? String == "function")
        #expect(result["modernSetValue"] as? String == "function")
        #expect(result["modernDeleteValue"] as? String == "undefined")
        #expect(result["legacyGetValue"] as? String == "function")
        #expect(result["legacySetValue"] as? String == "function")
        #expect(result["legacyDeleteValue"] as? String == "undefined")
        #expect(result["unsafeWindowMatches"] as? Bool == true)
    }

    @Test func grantNoneRunsWithoutGMAPIsButKeepsGMInfo() throws {
        let result = try runProbe(source: """
        // ==UserScript==
        // @name Grant None Probe
        // @match https://example.com/*
        // @run-at document-start
        // @grant none
        // ==/UserScript==
        window.__grantNoneProbe = {
          scriptName: GM_info.script.name,
          globalGM: typeof GM,
          legacyGetValue: typeof GM_getValue
        };
        """, probeExpression: "window.__grantNoneProbe")

        #expect(result["scriptName"] as? String == "Grant None Probe")
        #expect(result["globalGM"] as? String == "undefined")
        #expect(result["legacyGetValue"] as? String == "undefined")
    }

    @Test func modernPromiseAPIsAndWindowGrantsAreExposed() throws {
        let result = try runProbe(source: """
        // ==UserScript==
        // @name Modern Probe
        // @match https://example.com/*
        // @run-at document-start
        // @grant GM_download
        // @grant GM.notification
        // @grant window.close
        // @grant window.focus
        // ==/UserScript==
        const download = GM.download({ url: 'https://example.com/file.txt', name: 'file.txt' });
        const notification = GM.notification({ text: 'hello' });
        window.__modernProbe = {
          downloadThen: typeof download.then,
          downloadAbort: typeof download.abort,
          notificationThen: typeof notification.then,
          closeType: typeof window.close,
          focusType: typeof window.focus
        };
        """, probeExpression: "window.__modernProbe")

        #expect(result["downloadThen"] as? String == "function")
        #expect(result["downloadAbort"] as? String == "function")
        #expect(result["notificationThen"] as? String == "function")
        #expect(result["closeType"] as? String == "function")
        #expect(result["focusType"] as? String == "function")
    }

    @Test func unwrapRunsInPageGlobalScope() throws {
        let result = try runProbe(source: """
        // ==UserScript==
        // @name Unwrapped
        // @match https://example.com/*
        // @run-at document-start
        // @unwrap
        // ==/UserScript==
        var cmuxUnwrappedProbe = 42;
        window.__unwrapProbe = {
          value: window.cmuxUnwrappedProbe,
          scriptName: GM_info.script.name
        };
        """, probeExpression: "window.__unwrapProbe")

        #expect(result["value"] as? Int == 42)
        #expect(result["scriptName"] as? String == "Unwrapped")
    }

    private func runProbe(source: String, probeExpression: String) throws -> [String: Any] {
        let script = BrowserUserScriptParser().parse(source: source, id: "runtime-probe")
        let wrappedSource = BrowserUserScriptSourceBuilder().wrappedSource(for: script)
        let context = JSContext()!
        let exception = ExceptionBox()
        context.exceptionHandler = { _, value in
            exception.message = value?.toString()
        }
        context.evaluateScript(Self.browserStubs)
        context.evaluateScript(wrappedSource)
        let json = try #require(context.evaluateScript("JSON.stringify(\(probeExpression))")?.toString())
        if let message = exception.message {
            Issue.record("JavaScript exception: \(message)")
        }
        let data = try #require(json.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try #require(object)
    }

    private final class ExceptionBox {
        var message: String?
    }

    private static let browserStubs = """
    var window = this;
    var globalThis = this;
    var top = window;
    var console = { log(){}, info(){}, warn(){}, error(){}, debug(){} };
    function setTimeout(fn) { if (typeof fn === 'function') fn(); return 1; }
    function clearTimeout() {}
    function setInterval(fn) { return 1; }
    function clearInterval() {}
    function AbortController() {
      this.signal = { aborted: false };
      this.abort = () => { this.signal.aborted = true; };
    }
    function URL(raw, base) {
      var text = String(raw || '');
      if (text.indexOf('://') < 0 && base) {
        var baseText = String(base.href || base || '');
        if (text.charAt(0) === '/') {
          var origin = baseText.match(/^([a-z]+:\\/\\/[^\\/]+)/);
          text = (origin ? origin[1] : 'https://example.com') + text;
        } else {
          text = baseText.replace(/[^\\/]*$/, '') + text;
        }
      }
      var match = text.match(/^([a-z]+:)?\\/\\/([^\\/:?#]+)(?::(\\d+))?([^?#]*)/);
      if (!match) throw new Error('invalid URL: ' + text);
      this.href = text;
      this.protocol = match[1] || 'https:';
      this.hostname = match[2] || '';
      this.host = this.hostname + (match[3] ? ':' + match[3] : '');
      this.port = match[3] || '';
      this.pathname = match[4] || '/';
      this.toString = () => this.href;
    }
    var location = new URL('https://example.com/page');
    var navigator = { platform: 'MacIntel' };
    var history = { pushState(){}, replaceState(){} };
    var localStorage = {
      length: 0,
      key() { return null; },
      getItem() { return null; },
      setItem() {},
      removeItem() {}
    };
    var sessionStorage = {
      getItem() { return null; },
      setItem() {}
    };
    var document = {
      readyState: 'complete',
      cookie: '',
      documentElement: { appendChild() {} },
      head: { appendChild() {} },
      body: { appendChild() {} },
      addEventListener() {},
      querySelectorAll() { return []; },
      createElement(tagName) {
        return {
          tagName,
          style: {},
          setAttribute() {},
          appendChild() {},
          click() {},
          remove() {},
          select() {}
        };
      }
    };
    """
}
