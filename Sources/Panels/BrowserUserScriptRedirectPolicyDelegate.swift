import Foundation

/// Stops privileged userscript requests before they follow a disallowed redirect.
final class BrowserUserScriptRedirectPolicyDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    // Immutable after initialization; URLSession may invoke the delegate from its own queue.
    private let allowsRedirect: @Sendable (URL) -> Bool

    init(allowsRedirect: @escaping @Sendable (URL) -> Bool) {
        self.allowsRedirect = allowsRedirect
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, allowsRedirect(url) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
