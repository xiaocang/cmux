public import Foundation

/// File-backed repository for installed browser userscripts.
public struct BrowserUserScriptFileStore {
    /// Directory containing `manifest.json` and `.user.js` files.
    public let directoryURL: URL

    private let fileManager: FileManager
    private let parser: BrowserUserScriptParser

    /// Creates a userscript store.
    /// - Parameters:
    ///   - directoryURL: The directory used for userscript files.
    ///   - fileManager: File manager used for reads and writes.
    ///   - parser: Parser used to read userscript metadata.
    public init(
        directoryURL: URL,
        fileManager: FileManager = .default,
        parser: BrowserUserScriptParser = BrowserUserScriptParser()
    ) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        self.parser = parser
    }

    /// Returns the conventional cmux userscript directory.
    /// - Parameter home: Home directory to anchor under.
    public static func defaultDirectoryURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appending(path: ".config/cmux/userscripts")
    }

    /// Creates a store for the conventional cmux userscript directory.
    /// - Parameter home: Home directory to anchor under.
    public static func defaultStore(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> BrowserUserScriptFileStore {
        BrowserUserScriptFileStore(directoryURL: defaultDirectoryURL(home: home))
    }

    /// Reads every installed userscript.
    public func installedScripts() throws -> [BrowserUserScript] {
        let manifest = try readManifest()
        return try manifest.scripts.compactMap { entry in
            guard let fileURL = manifestFileURL(named: entry.file),
                  fileManager.fileExists(atPath: fileURL.path) else {
                return nil
            }
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            return parser.parse(source: source, id: entry.id, enabled: entry.enabled)
        }
    }

    /// Installs or replaces a userscript.
    /// - Parameters:
    ///   - source: Raw `.user.js` source.
    ///   - id: Optional existing id. Omit to derive one from metadata and source.
    ///   - enabled: Whether the script should be enabled after install.
    /// - Returns: The installed userscript.
    @discardableResult
    public func install(source: String, id: String? = nil, enabled: Bool = true) throws -> BrowserUserScript {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let script = parser.parse(source: source, id: id, enabled: enabled)
        let fileName = fileName(for: script)
        let fileURL = directoryURL.appending(path: fileName)
        try source.write(to: fileURL, atomically: true, encoding: .utf8)

        var manifest = try readManifest()
        manifest.scripts.removeAll { $0.id == script.id }
        manifest.scripts.append(BrowserUserScriptManifestEntry(id: script.id, file: fileName, enabled: enabled))
        manifest.scripts.sort { $0.id < $1.id }
        try writeManifest(manifest)
        return script
    }

    /// Removes an installed userscript.
    /// - Parameter id: Script id.
    /// - Returns: Whether a script was removed.
    @discardableResult
    public func remove(id: String) throws -> Bool {
        var manifest = try readManifest()
        guard let index = manifest.scripts.firstIndex(where: { $0.id == id }) else { return false }
        let entry = manifest.scripts.remove(at: index)
        if let fileURL = manifestFileURL(named: entry.file),
           fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
        try writeManifest(manifest)
        return true
    }

    /// Enables or disables an installed userscript.
    /// - Parameters:
    ///   - id: Script id.
    ///   - enabled: New enabled state.
    /// - Returns: The updated script, or `nil` if no script with `id` exists.
    @discardableResult
    public func setEnabled(id: String, enabled: Bool) throws -> BrowserUserScript? {
        var manifest = try readManifest()
        guard let index = manifest.scripts.firstIndex(where: { $0.id == id }) else { return nil }
        manifest.scripts[index].enabled = enabled
        try writeManifest(manifest)
        return try installedScripts().first { $0.id == id }
    }

    private func manifestURL() -> URL {
        directoryURL.appending(path: "manifest.json")
    }

    private func readManifest() throws -> BrowserUserScriptManifest {
        let url = manifestURL()
        guard fileManager.fileExists(atPath: url.path) else {
            return BrowserUserScriptManifest()
        }
        let data = try Data(contentsOf: url)
        if data.isEmpty {
            return BrowserUserScriptManifest()
        }
        return try JSONDecoder().decode(BrowserUserScriptManifest.self, from: data)
    }

    private func writeManifest(_ manifest: BrowserUserScriptManifest) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL(), options: [.atomic])
    }

    private func fileName(for script: BrowserUserScript) -> String {
        let name = Self.slugify(script.metadata.name)
        let identifier = Self.slugify(script.id)
        let hash = Self.stableHash(script.id)
        return "\(name)-\(identifier)-\(hash).user.js"
    }

    private func manifestFileURL(named fileName: String) -> URL? {
        guard fileName.hasSuffix(".user.js"),
              URL(fileURLWithPath: fileName).lastPathComponent == fileName else {
            return nil
        }
        let directory = directoryURL.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = directoryURL
            .appending(path: fileName)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard candidate.deletingLastPathComponent() == directory else { return nil }
        return candidate
    }

    private static func slugify(_ value: String) -> String {
        var output = ""
        for scalar in value.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                for lowerScalar in String(scalar).lowercased().unicodeScalars
                    where CharacterSet.alphanumerics.contains(lowerScalar) {
                    output.unicodeScalars.append(lowerScalar)
                }
            } else if output.last != "-" {
                output.append("-")
            }
        }
        let trimmed = output.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "userscript" : String(trimmed.prefix(48))
    }
    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

}
