import Foundation

/// Parses `.user.js` metadata and assigns stable cmux userscript ids.
public struct BrowserUserScriptParser: Sendable {
    /// Creates a parser.
    public init() {}

    /// Parses a userscript source.
    /// - Parameters:
    ///   - source: The raw `.user.js` source.
    ///   - id: Optional existing id. When omitted, a stable id is derived from
    ///     source and metadata.
    ///   - enabled: Whether the parsed script is enabled.
    /// - Returns: A userscript model with parsed metadata.
    public func parse(source: String, id: String? = nil, enabled: Bool = true) -> BrowserUserScript {
        let fields = metadataFields(in: source)
        var metadata = BrowserUserScriptMetadata()
        metadata.name = firstValue(fields, "name") ?? metadata.name
        metadata.namespace = firstValue(fields, "namespace")
        metadata.version = firstValue(fields, "version")
        metadata.description = firstValue(fields, "description")
        metadata.author = firstValue(fields, "author")
        metadata.copyright = firstValue(fields, "copyright")
        metadata.icon = firstValue(fields, "icon")
            ?? firstValue(fields, "iconurl")
            ?? firstValue(fields, "defaulticon")
        metadata.icon64 = firstValue(fields, "icon64")
            ?? firstValue(fields, "icon64url")
        metadata.homepage = firstValue(fields, "homepage")
            ?? firstValue(fields, "homepageurl")
            ?? firstValue(fields, "website")
            ?? firstValue(fields, "source")
        metadata.updateURL = firstValue(fields, "updateurl")
        metadata.downloadURL = firstValue(fields, "downloadurl")
        metadata.supportURL = firstValue(fields, "supporturl")
        metadata.antifeatures = values(fields, "antifeature")
        metadata.tags = values(fields, "tag")
        metadata.matches = values(fields, "match")
        metadata.includes = values(fields, "include")
        metadata.excludeMatches = values(fields, "exclude-match")
        metadata.excludes = values(fields, "exclude")
        metadata.grants = values(fields, "grant")
        metadata.requires = values(fields, "require")
        metadata.resources = resources(from: values(fields, "resource"))
        metadata.connects = values(fields, "connect") + values(fields, "domain")
        metadata.noframes = fields.keys.contains("noframes")
        metadata.runIn = values(fields, "run-in")
        metadata.sandbox = firstValue(fields, "sandbox")
        metadata.webRequests = values(fields, "webrequest")
        metadata.unwrap = fields.keys.contains("unwrap")
        if let runAt = firstValue(fields, "run-at") {
            metadata.runAt = BrowserUserScriptRunAt(metadataValue: runAt)
        }

        if metadata.matches.isEmpty && metadata.includes.isEmpty {
            metadata.matches = ["*://*/*"]
        }

        let resolvedID = id?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? Self.stableIdentifier(metadata: metadata, source: source)
        return BrowserUserScript(id: resolvedID, enabled: enabled, source: source, metadata: metadata)
    }

    private func metadataFields(in source: String) -> [String: [String]] {
        var fields: [String: [String]] = [:]
        var inBlock = false
        for rawLine in source.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == "// ==UserScript==" {
                inBlock = true
                continue
            }
            if line == "// ==/UserScript==" {
                break
            }
            guard inBlock, line.hasPrefix("//") else { continue }
            let body = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            guard body.hasPrefix("@") else { continue }
            let withoutAt = String(body.dropFirst())
            let split = withoutAt.firstIndex(where: { $0 == " " || $0 == "\t" })
            let key: String
            let value: String
            if let split {
                key = String(withoutAt[..<split]).lowercased()
                value = String(withoutAt[split...]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                key = withoutAt.lowercased()
                value = ""
            }
            fields[key, default: []].append(value)
        }
        return fields
    }

    private func firstValue(_ fields: [String: [String]], _ key: String) -> String? {
        values(fields, key).first
    }

    private func values(_ fields: [String: [String]], _ key: String) -> [String] {
        (fields[key] ?? []).compactMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
    }

    private func resources(from declarations: [String]) -> [String: String] {
        var resources: [String: String] = [:]
        for declaration in declarations {
            let pieces = declaration.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard pieces.count == 2 else { continue }
            resources[String(pieces[0])] = String(pieces[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return resources
    }

    private static func stableIdentifier(metadata: BrowserUserScriptMetadata, source: String) -> String {
        let base = "\(metadata.namespace ?? ""):\(metadata.name):\(source)"
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in base.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        let slug = slugify(metadata.name)
        return "\(slug)-\(String(hash, radix: 16))"
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
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
