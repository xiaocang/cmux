import Foundation

/// Parsed metadata from a `.user.js` userscript header.
public struct BrowserUserScriptMetadata: Codable, Sendable, Equatable {
    /// Display name from `@name`.
    public var name: String

    /// Optional namespace from `@namespace`.
    public var namespace: String?

    /// Optional version from `@version`.
    public var version: String?

    /// Optional description from `@description`.
    public var description: String?

    /// Optional author from `@author`.
    public var author: String?

    /// Optional copyright declaration from `@copyright`.
    public var copyright: String?

    /// Optional icon URL from `@icon`, `@iconURL`, or `@defaulticon`.
    public var icon: String?

    /// Optional high-resolution icon URL from `@icon64` or `@icon64URL`.
    public var icon64: String?

    /// Optional homepage URL from `@homepage`, `@homepageURL`, `@website`, or `@source`.
    public var homepage: String?

    /// Optional update URL from `@updateURL`.
    public var updateURL: String?

    /// Optional download URL from `@downloadURL`.
    public var downloadURL: String?

    /// Optional support URL from `@supportURL`.
    public var supportURL: String?

    /// Raw anti-feature declarations from `@antifeature`.
    public var antifeatures: [String]

    /// Free-form tags from `@tag`.
    public var tags: [String]

    /// URL match patterns from `@match`.
    public var matches: [String]

    /// Legacy include globs from `@include`.
    public var includes: [String]

    /// URL match patterns from `@exclude-match`.
    public var excludeMatches: [String]

    /// Legacy exclude globs from `@exclude`.
    public var excludes: [String]

    /// Requested execution phase from `@run-at`.
    public var runAt: BrowserUserScriptRunAt

    /// Declared grants from `@grant`.
    public var grants: [String]

    /// External dependencies declared by `@require`.
    public var requires: [String]

    /// Resource declarations from `@resource name url`.
    public var resources: [String: String]

    /// Cross-origin hosts declared by `@connect`.
    public var connects: [String]

    /// Whether `@noframes` was declared.
    public var noframes: Bool

    /// Browser contexts requested by `@run-in`.
    public var runIn: [String]

    /// Sandbox access mode requested by `@sandbox`.
    public var sandbox: String?

    /// Raw `@webRequest` declarations.
    public var webRequests: [String]

    /// Whether `@unwrap` was declared.
    public var unwrap: Bool

    /// Creates parsed userscript metadata.
    public init(
        name: String = "Untitled Userscript",
        namespace: String? = nil,
        version: String? = nil,
        description: String? = nil,
        author: String? = nil,
        copyright: String? = nil,
        icon: String? = nil,
        icon64: String? = nil,
        homepage: String? = nil,
        updateURL: String? = nil,
        downloadURL: String? = nil,
        supportURL: String? = nil,
        antifeatures: [String] = [],
        tags: [String] = [],
        matches: [String] = [],
        includes: [String] = [],
        excludeMatches: [String] = [],
        excludes: [String] = [],
        runAt: BrowserUserScriptRunAt = .documentEnd,
        grants: [String] = [],
        requires: [String] = [],
        resources: [String: String] = [:],
        connects: [String] = [],
        noframes: Bool = false,
        runIn: [String] = [],
        sandbox: String? = nil,
        webRequests: [String] = [],
        unwrap: Bool = false
    ) {
        self.name = name
        self.namespace = namespace
        self.version = version
        self.description = description
        self.author = author
        self.copyright = copyright
        self.icon = icon
        self.icon64 = icon64
        self.homepage = homepage
        self.updateURL = updateURL
        self.downloadURL = downloadURL
        self.supportURL = supportURL
        self.antifeatures = antifeatures
        self.tags = tags
        self.matches = matches
        self.includes = includes
        self.excludeMatches = excludeMatches
        self.excludes = excludes
        self.runAt = runAt
        self.grants = grants
        self.requires = requires
        self.resources = resources
        self.connects = connects
        self.noframes = noframes
        self.runIn = runIn
        self.sandbox = sandbox
        self.webRequests = webRequests
        self.unwrap = unwrap
    }
}
