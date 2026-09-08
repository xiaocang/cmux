import Foundation

/// The on-disk manifest for installed browser userscripts.
struct BrowserUserScriptManifest: Codable, Equatable {
    var version: Int
    var scripts: [BrowserUserScriptManifestEntry]

    init(version: Int = 1, scripts: [BrowserUserScriptManifestEntry] = []) {
        self.version = version
        self.scripts = scripts
    }
}
