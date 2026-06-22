import Foundation

/// One user-defined site-search shortcut: a keyword typed in the address bar
/// that expands a query into a URL template.
///
/// The full list is stored as a JSON-encoded string under the catalog entry
/// ``BrowserCatalogSection/siteSearchShortcuts`` (UserDefaults key
/// `browserSiteSearchShortcuts`), byte-compatible with the legacy in-app
/// storage. Use ``decode(_:)`` / ``encode(_:)`` to bridge that string and
/// ``isValidShortcut(_:)`` / ``isValidURLTemplate(_:)`` to validate rows.
public struct BrowserSiteSearchShortcut: Codable, Identifiable, Equatable, Hashable, Sendable {
    /// Stable identifier; synthesized when missing from stored JSON.
    public var id: UUID
    /// Display name (e.g. `GitHub`).
    public var name: String
    /// Address-bar keyword (e.g. `gh`); must be non-empty and space-free.
    public var shortcut: String
    /// URL template containing `%s` where the query is substituted.
    public var urlTemplate: String
    /// Whether this shortcut participates in omnibar site search.
    public var isActive: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        shortcut: String,
        urlTemplate: String,
        isActive: Bool = true
    ) {
        self.id = id
        self.name = name
        self.shortcut = shortcut
        self.urlTemplate = urlTemplate
        self.isActive = isActive
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, shortcut, urlTemplate, isActive
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        shortcut = try container.decode(String.self, forKey: .shortcut)
        urlTemplate = try container.decode(String.self, forKey: .urlTemplate)
        isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive) ?? true
    }

    /// Default stored value: an empty JSON array.
    public static let emptyStorage = "[]"

    /// Encodes a shortcut list to its JSON-string storage form. Falls back to
    /// ``emptyStorage`` if encoding fails.
    public static func encode(_ shortcuts: [BrowserSiteSearchShortcut]) -> String {
        guard let data = try? JSONEncoder().encode(shortcuts),
              let encoded = String(data: data, encoding: .utf8) else {
            return emptyStorage
        }
        return encoded
    }

    /// Decodes the JSON-string storage form into a shortcut list. Returns an
    /// empty array when the value is missing or malformed.
    public static func decode(_ rawValue: String?) -> [BrowserSiteSearchShortcut] {
        guard let rawValue,
              let data = rawValue.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([BrowserSiteSearchShortcut].self, from: data) else {
            return []
        }
        return decoded
    }

    /// A shortcut keyword is valid when it is non-empty and contains no
    /// whitespace.
    public static func isValidShortcut(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !trimmed.contains(where: { $0.isWhitespace })
    }

    /// A URL template is valid when it contains `%s` and resolves to an
    /// http/https URL once the placeholder is filled.
    public static func isValidURLTemplate(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("%s"),
              let url = URL(string: trimmed.replacingOccurrences(of: "%s", with: "test")),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            return false
        }
        return true
    }
}
