public import Foundation

/// File-backed repository for per-userscript GM value storage.
public struct BrowserUserScriptValueStore {
    /// Directory containing one JSON value file per userscript.
    public let directoryURL: URL

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Creates a value store.
    /// - Parameters:
    ///   - directoryURL: Directory containing userscript value files.
    ///   - fileManager: File manager used for filesystem operations.
    public init(
        directoryURL: URL,
        fileManager: FileManager = .default
    ) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        self.decoder = JSONDecoder()
    }

    /// Returns the conventional cmux userscript value directory.
    /// - Parameter home: Home directory used as the root.
    /// - Returns: The default value store directory.
    public static func defaultDirectoryURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appending(path: ".config/cmux/userscripts/values")
    }

    /// Creates a value store for the conventional cmux userscript value directory.
    /// - Parameter home: Home directory used as the root.
    /// - Returns: A value store using the default directory.
    public static func defaultStore(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> BrowserUserScriptValueStore {
        BrowserUserScriptValueStore(directoryURL: defaultDirectoryURL(home: home))
    }

    /// Reads every stored value for a userscript.
    /// - Parameter scriptID: Userscript identifier.
    /// - Returns: Values keyed by GM storage key.
    public func values(scriptID: String) throws -> [String: BrowserUserScriptValue] {
        let url = try migratedFileURL(scriptID: scriptID)
        guard fileManager.fileExists(atPath: url.path) else {
            return [:]
        }
        let data = try Data(contentsOf: url)
        guard data.isEmpty == false else {
            return [:]
        }
        return try decoder.decode([String: BrowserUserScriptValue].self, from: data)
    }

    /// Lists all stored keys for a userscript.
    /// - Parameter scriptID: Userscript identifier.
    /// - Returns: Stored keys sorted lexicographically.
    public func keys(scriptID: String) throws -> [String] {
        try values(scriptID: scriptID).keys.sorted()
    }

    /// Reads one stored value.
    /// - Parameters:
    ///   - scriptID: Userscript identifier.
    ///   - key: GM storage key.
    /// - Returns: The stored value, or `nil` when absent.
    public func value(scriptID: String, key: String) throws -> BrowserUserScriptValue? {
        try values(scriptID: scriptID)[key]
    }

    /// Stores one value.
    /// - Parameters:
    ///   - value: Value to store.
    ///   - scriptID: Userscript identifier.
    ///   - key: GM storage key.
    public func setValue(_ value: BrowserUserScriptValue, scriptID: String, key: String) throws {
        var values = try values(scriptID: scriptID)
        values[key] = value
        try writeValues(values, scriptID: scriptID)
    }

    /// Stores many values.
    /// - Parameters:
    ///   - newValues: Values to merge into the existing script store.
    ///   - scriptID: Userscript identifier.
    public func setValues(_ newValues: [String: BrowserUserScriptValue], scriptID: String) throws {
        var values = try values(scriptID: scriptID)
        for (key, value) in newValues {
            values[key] = value
        }
        try writeValues(values, scriptID: scriptID)
    }

    /// Deletes one value.
    /// - Parameters:
    ///   - scriptID: Userscript identifier.
    ///   - key: GM storage key.
    /// - Returns: Whether a value was removed.
    @discardableResult
    public func deleteValue(scriptID: String, key: String) throws -> Bool {
        var values = try values(scriptID: scriptID)
        let removed = values.removeValue(forKey: key) != nil
        try writeValues(values, scriptID: scriptID)
        return removed
    }

    /// Deletes many values.
    /// - Parameters:
    ///   - scriptID: Userscript identifier.
    ///   - keys: GM storage keys to delete.
    /// - Returns: Count of removed values.
    @discardableResult
    public func deleteValues(scriptID: String, keys: [String]) throws -> Int {
        var values = try values(scriptID: scriptID)
        var removed = 0
        for key in keys {
            if values.removeValue(forKey: key) != nil {
                removed += 1
            }
        }
        try writeValues(values, scriptID: scriptID)
        return removed
    }

    private func writeValues(_ values: [String: BrowserUserScriptValue], scriptID: String) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try encoder.encode(values)
        try data.write(to: fileURL(scriptID: scriptID), options: [.atomic])
    }

    private func migratedFileURL(scriptID: String) throws -> URL {
        let url = fileURL(scriptID: scriptID)
        guard !fileManager.fileExists(atPath: url.path) else { return url }

        let legacyURL = directoryURL.appending(path: "\(Self.slugify(scriptID)).json")
        guard fileManager.fileExists(atPath: legacyURL.path) else { return url }

        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        do {
            try fileManager.moveItem(at: legacyURL, to: url)
        } catch {
            guard fileManager.fileExists(atPath: url.path) else { throw error }
        }
        return url
    }

    private func fileURL(scriptID: String) -> URL {
        let slug = Self.slugify(scriptID)
        let hash = Self.stableHash(scriptID)
        return directoryURL.appending(path: "\(slug)-\(hash).json")
    }

    private static func slugify(_ value: String) -> String {
        var output = ""
        for scalar in value.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" {
                output.unicodeScalars.append(scalar)
            } else if output.last != "-" {
                output.append("-")
            }
        }
        let trimmed = output.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "userscript" : String(trimmed.prefix(96))
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
