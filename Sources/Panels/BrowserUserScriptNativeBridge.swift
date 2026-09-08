import Foundation
import AppKit
import CmuxBrowser
import ObjectiveC
import WebKit

private struct BrowserUserScriptNativeRequest: Sendable {
    var type: String
    var scriptID: String
    var token: String
    var url: String
    var method: String
    var headers: [String: String]
    var data: String?
    var anonymous: Bool
    var responseType: String
    var detailsURL: String?
    var detailsDomain: String?
    var detailsName: String?
    var detailsPath: String?
    var detailsValue: String?
    var detailsSecure: Bool?
    var detailsHTTPOnly: Bool?
    var detailsSameSite: String?
    var detailsExpirationDate: TimeInterval?
    var key: String?
    var keys: [String]
    var value: BrowserUserScriptValue?
    var values: [String: BrowserUserScriptValue]

    init?(body: Any) {
        guard let dictionary = body as? [String: Any],
              let type = dictionary["type"] as? String,
              let scriptID = dictionary["scriptId"] as? String,
              let token = dictionary["token"] as? String else {
            return nil
        }

        self.type = type
        self.scriptID = scriptID
        self.token = token
        self.url = dictionary["url"] as? String ?? ""
        self.method = (dictionary["method"] as? String ?? "GET").uppercased()
        self.data = dictionary["data"] as? String
        self.anonymous = (dictionary["anonymous"] as? Bool) ?? false
        self.responseType = dictionary["responseType"] as? String ?? ""

        var parsedHeaders: [String: String] = [:]
        if let rawHeaders = dictionary["headers"] as? [String: Any] {
            for (key, value) in rawHeaders {
                if let stringValue = value as? String {
                    parsedHeaders[key] = stringValue
                }
            }
        }
        self.headers = parsedHeaders

        let details = dictionary["details"] as? [String: Any] ?? [:]
        self.detailsURL = details["url"] as? String
        self.detailsDomain = details["domain"] as? String
        self.detailsName = details["name"] as? String
        self.detailsPath = details["path"] as? String
        self.detailsValue = details["value"] as? String
        self.detailsSecure = details["secure"] as? Bool
        self.detailsHTTPOnly = details["httpOnly"] as? Bool
        self.detailsSameSite = details["sameSite"] as? String
        if let number = details["expirationDate"] as? NSNumber {
            self.detailsExpirationDate = number.doubleValue
        } else {
            self.detailsExpirationDate = details["expirationDate"] as? TimeInterval
        }

        self.key = dictionary["key"] as? String
        if let keys = dictionary["keys"] as? [String] {
            self.keys = keys
        } else if let rawKeys = dictionary["keys"] as? [Any] {
            self.keys = rawKeys.compactMap { $0 as? String }
        } else {
            self.keys = []
        }
        if let rawValue = dictionary["value"] {
            self.value = try? BrowserUserScriptValue(jsonObject: rawValue)
        } else {
            self.value = nil
        }
        if let rawValues = dictionary["values"] as? [String: Any] {
            self.values = rawValues.compactMapValues { try? BrowserUserScriptValue(jsonObject: $0) }
        } else {
            self.values = [:]
        }
    }
}

@MainActor
final class BrowserUserScriptNativeBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let handlerName = "cmuxUserscript"

    private struct ScriptPolicy {
        var token: String
        var metadata: BrowserUserScriptMetadata
        var connects: [String]
        var grantPolicy: BrowserUserScriptGrantPolicy
    }
    // Address-only Objective-C association key; userscript state lives in each bridge instance.
    private static var bridgeAssociationKey: UInt8 = 0


    weak var panel: BrowserPanel?

    private var websiteDataStore: WKWebsiteDataStore
    private let valueStore: BrowserUserScriptValueStore
    private var policiesByScriptID: [String: ScriptPolicy] = [:]

    init(
        websiteDataStore: WKWebsiteDataStore,
        valueStore: BrowserUserScriptValueStore = .defaultStore()
    ) {
        self.websiteDataStore = websiteDataStore
        self.valueStore = valueStore
        super.init()
    }

    static func installed(
        on userContentController: WKUserContentController
    ) -> BrowserUserScriptNativeBridge? {
        objc_getAssociatedObject(
            userContentController,
            &bridgeAssociationKey
        ) as? BrowserUserScriptNativeBridge
    }

    static func installIfNeeded(
        on userContentController: WKUserContentController,
        websiteDataStore: WKWebsiteDataStore
    ) -> BrowserUserScriptNativeBridge {
        if let bridge = installed(on: userContentController) {
            bridge.websiteDataStore = websiteDataStore
            return bridge
        }

        let bridge = BrowserUserScriptNativeBridge(websiteDataStore: websiteDataStore)
        userContentController.addScriptMessageHandler(
            bridge,
            contentWorld: .page,
            name: handlerName
        )
        objc_setAssociatedObject(
            userContentController,
            &bridgeAssociationKey,
            bridge,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        return bridge
    }

    func token(for script: BrowserUserScript) -> String {
        if var policy = policiesByScriptID[script.id] {
            policy.metadata = script.metadata
            policy.connects = script.metadata.connects
            policy.grantPolicy = BrowserUserScriptGrantPolicy(grants: script.metadata.grants)
            policiesByScriptID[script.id] = policy
            return policy.token
        }
        let token = UUID().uuidString + "-" + UUID().uuidString
        policiesByScriptID[script.id] = ScriptPolicy(
            token: token,
            metadata: script.metadata,
            connects: script.metadata.connects,
            grantPolicy: BrowserUserScriptGrantPolicy(grants: script.metadata.grants)
        )
        return token
    }

    func resetPolicies() {
        policiesByScriptID.removeAll(keepingCapacity: true)
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard let request = BrowserUserScriptNativeRequest(body: message.body) else {
            replyHandler(Self.errorPayload("invalid_request"), nil)
            return
        }
        guard let policy = policy(scriptID: request.scriptID, token: request.token) else {
            replyHandler(Self.errorPayload("not_allowed"), nil)
            return
        }
        if let allowed = policy.grantPolicy.allowsNativeRequest(type: request.type),
           !allowed {
            replyHandler(Self.errorPayload("grant_not_allowed"), nil)
            return
        }
        if request.type.hasPrefix("value.") {
            handleValueRequest(request, replyHandler: replyHandler)
            return
        }
        if request.type.hasPrefix("cookie.") {
            handleCookieRequest(
                request,
                policy: policy,
                frameInfo: message.frameInfo,
                replyHandler: replyHandler
            )
            return
        }
        if request.type.hasPrefix("window.") {
            handleWindowRequest(
                request,
                policy: policy,
                replyHandler: replyHandler
            )
            return
        }
        guard request.type == "xmlhttpRequest" else {
            replyHandler(Self.errorPayload("unsupported_type"), nil)
            return
        }
        let pageURL = Self.pageURL(from: message.frameInfo)
        guard let url = URL(string: request.url),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            replyHandler(Self.errorPayload("invalid_url"), nil)
            return
        }
        guard BrowserUserScriptConnectMatcher().allows(
            url: url,
            pageURL: pageURL,
            connects: policy.connects
        ) else {
            replyHandler(Self.errorPayload("connect_not_allowed"), nil)
            return
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        if let data = request.data {
            urlRequest.httpBody = Data(data.utf8)
        }

        let configuration = request.anonymous
            ? URLSessionConfiguration.ephemeral
            : URLSessionConfiguration.default
        configuration.httpShouldSetCookies = !request.anonymous
        let connects = policy.connects
        let redirectPolicy = BrowserUserScriptRedirectPolicyDelegate { redirectURL in
            BrowserUserScriptConnectMatcher().allows(
                url: redirectURL,
                pageURL: pageURL,
                connects: connects
            )
        }
        let session = URLSession(
            configuration: configuration,
            delegate: redirectPolicy,
            delegateQueue: nil
        )

        let task = session.dataTask(with: urlRequest) { data, response, error in
            session.finishTasksAndInvalidate()
            if let error {
                replyHandler(Self.errorPayload(String(describing: error)), nil)
                return
            }

            let httpResponse = response as? HTTPURLResponse
            if let finalURL = response?.url,
               !BrowserUserScriptConnectMatcher().allows(
                   url: finalURL,
                   pageURL: pageURL,
                   connects: policy.connects
               ) {
                replyHandler(Self.errorPayload("final_url_not_allowed"), nil)
                return
            }
            let responseData = data ?? Data()
            let responseText = String(data: responseData, encoding: .utf8) ?? ""
            let headers = httpResponse?.allHeaderFields
                .map { "\($0.key): \($0.value)" }
                .sorted()
                .joined(separator: "\r\n") ?? ""
            let payload: [String: Any] = [
                "readyState": 4,
                "status": httpResponse?.statusCode ?? 0,
                "statusText": HTTPURLResponse.localizedString(forStatusCode: httpResponse?.statusCode ?? 0),
                "finalUrl": response?.url?.absoluteString ?? request.url,
                "responseText": responseText,
                "response": responseText,
                "responseHeaders": headers
            ]
            replyHandler(payload, nil)
        }
        task.resume()
    }


    private func policy(scriptID: String, token: String) -> ScriptPolicy? {
        guard let policy = policiesByScriptID[scriptID],
              policy.token == token else {
            return nil
        }
        return policy
    }

    private func handleValueRequest(
        _ request: BrowserUserScriptNativeRequest,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        let store = valueStore
        do {
            switch request.type {
            case "value.getAll":
                replyHandler(["values": Self.valuePayload(try store.values(scriptID: request.scriptID))], nil)
            case "value.list":
                replyHandler(["keys": try store.keys(scriptID: request.scriptID)], nil)
            case "value.get":
                guard let key = request.key?.nilIfEmpty else {
                    replyHandler(Self.errorPayload("missing_value_key"), nil)
                    return
                }
                let value = try store.value(scriptID: request.scriptID, key: key)?.jsonObject ?? NSNull()
                replyHandler(["value": value], nil)
            case "value.set":
                guard let key = request.key?.nilIfEmpty, let value = request.value else {
                    replyHandler(Self.errorPayload("invalid_value_details"), nil)
                    return
                }
                try store.setValue(value, scriptID: request.scriptID, key: key)
                replyHandler(["ok": true], nil)
            case "value.setMany":
                try store.setValues(request.values, scriptID: request.scriptID)
                replyHandler(["ok": true], nil)
            case "value.delete":
                guard let key = request.key?.nilIfEmpty else {
                    replyHandler(Self.errorPayload("missing_value_key"), nil)
                    return
                }
                let removed = try store.deleteValue(scriptID: request.scriptID, key: key)
                replyHandler(["ok": true, "removed": removed], nil)
            case "value.deleteMany":
                let removed = try store.deleteValues(scriptID: request.scriptID, keys: request.keys)
                replyHandler(["ok": true, "removed": removed], nil)
            default:
                replyHandler(Self.errorPayload("unsupported_value_request"), nil)
            }
        } catch {
            replyHandler(Self.errorPayload("value_store_error: \(String(describing: error))"), nil)
        }
    }

    private func handleWindowRequest(
        _ request: BrowserUserScriptNativeRequest,
        policy: ScriptPolicy,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard let panel else {
            replyHandler(Self.errorPayload("browser_panel_unavailable"), nil)
            return
        }

        switch request.type {
        case "window.close":
            guard Self.script(policy: policy, hasGrant: "window.close") else {
                replyHandler(Self.errorPayload("window_close_not_granted"), nil)
                return
            }
            panel.webViewDidRequestClose?()
            replyHandler(["ok": true], nil)
        case "window.focus":
            guard Self.script(policy: policy, hasGrant: "window.focus") else {
                replyHandler(Self.errorPayload("window_focus_not_granted"), nil)
                return
            }
            if let window = panel.webView.window {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            let focused = panel.requestExplicitWebViewFocus()
            replyHandler(["ok": focused], nil)
        default:
            replyHandler(Self.errorPayload("unsupported_window_request"), nil)
        }
    }

    private func handleCookieRequest(
        _ request: BrowserUserScriptNativeRequest,
        policy: ScriptPolicy,
        frameInfo: WKFrameInfo,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        let cookieStore = websiteDataStore.httpCookieStore
        guard let pageURL = Self.pageURL(from: frameInfo),
              let targetURL = Self.cookieTargetURL(for: request, pageURL: pageURL) else {
            replyHandler(Self.errorPayload("invalid_cookie_url"), nil)
            return
        }
        guard Self.script(policy: policy, scriptID: request.scriptID, canAccess: targetURL) else {
            replyHandler(Self.errorPayload("cookie_url_not_allowed"), nil)
            return
        }

        Task { @MainActor in
            switch request.type {
            case "cookie.list":
                let cookies = await Self.allCookies(in: cookieStore)
                    .filter { Self.cookie($0, matches: targetURL) }
                    .filter { Self.cookie($0, matchesFiltersIn: request) }
                    .map(Self.cookiePayload)
                replyHandler(["cookies": cookies], nil)
            case "cookie.set":
                guard let cookie = Self.makeCookie(from: request, targetURL: targetURL) else {
                    replyHandler(Self.errorPayload("invalid_cookie_details"), nil)
                    return
                }
                await Self.setCookie(cookie, in: cookieStore)
                replyHandler(["ok": true], nil)
            case "cookie.delete":
                guard let name = request.detailsName?.trimmingCharacters(in: .whitespacesAndNewlines),
                      name.isEmpty == false else {
                    replyHandler(Self.errorPayload("missing_cookie_name"), nil)
                    return
                }
                let cookies = await Self.allCookies(in: cookieStore)
                    .filter { Self.cookie($0, matches: targetURL) }
                    .filter { $0.name == name }
                    .filter { Self.cookie($0, matchesFiltersIn: request) }
                for cookie in cookies {
                    await Self.deleteCookie(cookie, in: cookieStore)
                }
                replyHandler(["ok": true, "deleted": cookies.count], nil)
            default:
                replyHandler(Self.errorPayload("unsupported_cookie_request"), nil)
            }
        }
    }

    private static func cookieTargetURL(for request: BrowserUserScriptNativeRequest, pageURL: URL) -> URL? {
        let rawURL = request.detailsURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = rawURL.flatMap { URL(string: $0) } ?? pageURL
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }

    private static func script(policy: ScriptPolicy, scriptID: String, canAccess url: URL) -> Bool {
        BrowserUserScriptMatcher().matches(
            script: BrowserUserScript(id: scriptID, enabled: true, source: "", metadata: policy.metadata),
            url: url
        )
    }

    private static func script(policy: ScriptPolicy, hasGrant grant: String) -> Bool {
        let requestedGrant = grant.lowercased()
        return policy.metadata.grants.contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == requestedGrant
        }
    }

    private static func allCookies(in store: WKHTTPCookieStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            store.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }

    private static func setCookie(_ cookie: HTTPCookie, in store: WKHTTPCookieStore) async {
        await withCheckedContinuation { continuation in
            store.setCookie(cookie) {
                continuation.resume()
            }
        }
    }

    private static func deleteCookie(_ cookie: HTTPCookie, in store: WKHTTPCookieStore) async {
        await withCheckedContinuation { continuation in
            store.delete(cookie) {
                continuation.resume()
            }
        }
    }

    private static func makeCookie(from request: BrowserUserScriptNativeRequest, targetURL: URL) -> HTTPCookie? {
        guard let name = request.detailsName?.trimmingCharacters(in: .whitespacesAndNewlines),
              name.isEmpty == false else {
            return nil
        }
        let host = targetURL.host ?? ""
        guard !host.isEmpty else { return nil }
        let domain = request.detailsDomain?.nilIfEmpty ?? host
        guard cookieDomain(domain, matchesHost: host) else { return nil }

        var properties: [HTTPCookiePropertyKey: Any] = [
            .originURL: targetURL,
            .name: name,
            .value: request.detailsValue ?? "",
            .domain: domain,
            .path: request.detailsPath?.nilIfEmpty ?? "/",
            .secure: request.detailsSecure ?? (targetURL.scheme?.lowercased() == "https")
        ]
        if let expirationDate = request.detailsExpirationDate {
            properties[.expires] = Date(timeIntervalSince1970: expirationDate)
        } else {
            properties[.discard] = "TRUE"
        }
        if let httpOnly = request.detailsHTTPOnly {
            properties[HTTPCookiePropertyKey("HttpOnly")] = httpOnly ? "TRUE" : "FALSE"
        }
        if let sameSite = request.detailsSameSite?.nilIfEmpty {
            properties[HTTPCookiePropertyKey("SameSite")] = sameSite
        }
        return HTTPCookie(properties: properties)
    }

    private static func cookie(_ cookie: HTTPCookie, matches url: URL) -> Bool {
        guard let host = url.host,
              cookieDomain(cookie.domain, matchesHost: host) else {
            return false
        }
        let path = url.path.isEmpty ? "/" : url.path
        return path.hasPrefix(cookie.path)
    }

    private static func cookieDomain(_ domain: String, matchesHost host: String) -> Bool {
        let normalizedDomain = domain.lowercased().trimmingCharacters(
            in: CharacterSet(charactersIn: ".")
        )
        let normalizedHost = host.lowercased().trimmingCharacters(
            in: CharacterSet(charactersIn: ".")
        )
        guard !normalizedDomain.isEmpty, !normalizedHost.isEmpty else { return false }
        if normalizedHost.contains(":") || normalizedHost.allSatisfy({ $0.isNumber || $0 == "." }) {
            return normalizedHost == normalizedDomain
        }
        return normalizedHost == normalizedDomain
            || normalizedHost.hasSuffix("." + normalizedDomain)
    }

    private static func cookie(_ cookie: HTTPCookie, matchesFiltersIn request: BrowserUserScriptNativeRequest) -> Bool {
        if let name = request.detailsName?.nilIfEmpty, cookie.name != name {
            return false
        }
        if let domain = request.detailsDomain?.nilIfEmpty {
            let expected = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let actual = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard expected == actual else { return false }
        }
        if let path = request.detailsPath?.nilIfEmpty, cookie.path != path {
            return false
        }
        return true
    }

    private static func cookiePayload(_ cookie: HTTPCookie) -> [String: Any] {
        var payload: [String: Any] = [
            "domain": cookie.domain,
            "hostOnly": !cookie.domain.hasPrefix("."),
            "httpOnly": cookie.isHTTPOnly,
            "name": cookie.name,
            "path": cookie.path,
            "sameSite": "",
            "secure": cookie.isSecure,
            "session": cookie.isSessionOnly,
            "value": cookie.value
        ]
        if let expiresDate = cookie.expiresDate {
            payload["expirationDate"] = expiresDate.timeIntervalSince1970
        }
        return payload
    }

    private static func valuePayload(_ values: [String: BrowserUserScriptValue]) -> [String: Any] {
        values.mapValues(\.jsonObject)
    }

    private static func pageURL(from frameInfo: WKFrameInfo) -> URL? {
        if let url = frameInfo.request.url {
            return url
        }
        let origin = frameInfo.securityOrigin
        guard origin.host.isEmpty == false else {
            return nil
        }
        var components = URLComponents()
        components.scheme = origin.protocol
        components.host = origin.host
        if origin.port > 0 {
            components.port = origin.port
        }
        return components.url
    }

    nonisolated private static func errorPayload(_ message: String) -> [String: Any] {
        [
            "readyState": 4,
            "status": 0,
            "statusText": message,
            "error": message
        ]
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

