import Foundation

/// Server-side authorization for privileged userscript bridge requests.
public struct BrowserUserScriptGrantPolicy: Sendable {
    private let grants: Set<String>

    /// Creates a policy from parsed `@grant` declarations.
    public init(grants: [String]) {
        self.grants = Set(grants.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
    }

    /// Returns whether a known native request type is granted.
    ///
    /// `nil` means the request type is not a userscript bridge operation known
    /// to this policy. Callers should reject it as unsupported.
    public func allowsNativeRequest(type: String) -> Bool? {
        guard let aliases = Self.grantAliasesByRequestType[type] else { return nil }
        guard !grants.contains("none") else { return false }
        return !grants.isDisjoint(with: aliases)
    }

    private static let valueGrantAliases: Set<String> = [
        "gm_getvalue", "gm.getvalue",
        "gm_setvalue", "gm.setvalue",
        "gm_deletevalue", "gm.deletevalue",
        "gm_listvalues", "gm.listvalues",
        "gm_setvalues", "gm.setvalues",
        "gm_getvalues", "gm.getvalues",
        "gm_deletevalues", "gm.deletevalues",
        "gm_addvaluechangelistener", "gm.addvaluechangelistener",
        "gm_removevaluechangelistener", "gm.removevaluechangelistener",
    ]

    private static let cookieGrantAliases: Set<String> = ["gm_cookie", "gm.cookie"]
    private static let requestGrantAliases: Set<String> = [
        "gm_xmlhttprequest", "gm.xmlhttprequest",
    ]

    private static let grantAliasesByRequestType: [String: Set<String>] = [
        "value.getAll": valueGrantAliases,
        "value.list": ["gm_listvalues", "gm.listvalues"],
        "value.get": ["gm_getvalue", "gm.getvalue"],
        "value.set": ["gm_setvalue", "gm.setvalue"],
        "value.setMany": ["gm_setvalues", "gm.setvalues"],
        "value.delete": ["gm_deletevalue", "gm.deletevalue"],
        "value.deleteMany": ["gm_deletevalues", "gm.deletevalues"],
        "cookie.list": cookieGrantAliases,
        "cookie.set": cookieGrantAliases,
        "cookie.delete": cookieGrantAliases,
        "xmlhttpRequest": requestGrantAliases,
    ]
}
