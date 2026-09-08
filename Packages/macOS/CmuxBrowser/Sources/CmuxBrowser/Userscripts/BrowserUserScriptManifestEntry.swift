import Foundation

/// A manifest row pointing at one userscript source file.
struct BrowserUserScriptManifestEntry: Codable, Equatable {
    var id: String
    var file: String
    var enabled: Bool
}
