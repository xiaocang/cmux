import CMUXWorkstream
import Foundation

struct SortAssistantMemoryEvent: Codable {
    enum EventType: String, Codable {
        case created
    }

    let schemaVersion: String
    let eventType: EventType
    let memoryId: String
    let text: String
    let createdAt: String
}

enum SortAssistantWorkstreamPersistence {
    static let shared = WorkstreamPersistence(fileURL: WorkstreamPersistence.defaultFileURL())
}

enum SpriteMemorySource: Equatable {
    case workspace(URL)
}

struct SpriteMemoryLoadResult {
    let memories: [SortAssistantMemory]
    let sources: [UUID: SpriteMemorySource]
}

enum SpriteWorkspaceMemoryDocument {
    static let fileName = "memory.md"
    private static let startMarker = "<!-- cmux-memory:start -->"
    private static let endMarker = "<!-- cmux-memory:end -->"
    private static let idPrefix = "<!-- cmux-memory:id="
    private static let iso8601Formatter = ISO8601DateFormatter()

    static func fileURL(directory: String?) -> URL? {
        guard let directory else { return nil }
        let expanded = (directory.trimmingCharacters(in: .whitespacesAndNewlines) as NSString)
            .expandingTildeInPath
        guard !expanded.isEmpty else { return nil }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return URL(fileURLWithPath: expanded, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
            .standardizedFileURL
    }

    static func load(directory: String?) -> SpriteMemoryLoadResult {
        guard let url = fileURL(directory: directory),
              let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) else {
            return SpriteMemoryLoadResult(memories: [], sources: [:])
        }

        var memories: [SortAssistantMemory] = []
        var sources: [UUID: SpriteMemorySource] = [:]
        for line in content.components(separatedBy: .newlines) {
            guard let id = memoryId(in: line),
                  let text = memoryText(in: line) else {
                continue
            }
            let memory = SortAssistantMemory(
                id: id,
                text: text,
                createdAt: createdAt(in: line) ?? Date.distantPast
            )
            memories.append(memory)
            sources[id] = .workspace(url)
        }

        return SpriteMemoryLoadResult(
            memories: memories.sorted { $0.createdAt > $1.createdAt },
            sources: sources
        )
    }

    @discardableResult
    static func append(_ memory: SortAssistantMemory, directory: String?) throws -> URL? {
        guard let url = fileURL(directory: directory) else { return nil }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var content = (try? String(contentsOf: url, encoding: .utf8)) ?? "# Memory\n"
        let entry = entryLine(for: memory)
        if let start = content.range(of: startMarker),
           let end = content.range(of: endMarker, range: start.upperBound..<content.endIndex) {
            var section = String(content[start.upperBound..<end.lowerBound])
            if !section.hasSuffix("\n") {
                section += "\n"
            }
            section += entry + "\n"
            content.replaceSubrange(start.upperBound..<end.lowerBound, with: section)
        } else {
            if !content.hasSuffix("\n") {
                content += "\n"
            }
            if !content.hasSuffix("\n\n") {
                content += "\n"
            }
            content += """
            \(startMarker)
            ## cmux memories

            \(entry)
            \(endMarker)
            """
            content += "\n"
        }
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @discardableResult
    static func delete(memoryId: UUID?, containing text: String?, from url: URL) throws -> Int {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        let normalizedText = text?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        var removed = 0
        let kept = content.components(separatedBy: .newlines).filter { line in
            guard line.contains(idPrefix) else { return true }
            let matchesId = memoryId != nil && Self.memoryId(in: line) == memoryId
            let matchesText = normalizedText?.isEmpty == false
                && (memoryText(in: line)?.lowercased().contains(normalizedText ?? "") == true)
            if matchesId || matchesText {
                removed += 1
                return false
            }
            return true
        }
        guard removed > 0 else { return 0 }
        try kept.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return removed
    }

    private static func entryLine(for memory: SortAssistantMemory) -> String {
        "- \(iso8601Formatter.string(from: memory.createdAt)) - \(sanitize(memory.text)) \(idPrefix)\(memory.id.uuidString) -->"
    }

    private static func memoryId(in line: String) -> UUID? {
        guard let start = line.range(of: idPrefix),
              let end = line.range(of: "-->", range: start.upperBound..<line.endIndex) else {
            return nil
        }
        let raw = line[start.upperBound..<end.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return UUID(uuidString: raw)
    }

    private static func memoryText(in line: String) -> String? {
        let withoutComment: Substring
        if let comment = line.range(of: idPrefix) {
            withoutComment = line[..<comment.lowerBound]
        } else {
            withoutComment = Substring(line)
        }
        var text = String(withoutComment)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("-") || text.hasPrefix("*") {
            text.removeFirst()
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let separator = text.range(of: " - "),
           looksLikeISO8601Prefix(String(text[..<separator.lowerBound])) {
            text = String(text[separator.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.isEmpty ? nil : text
    }

    private static func createdAt(in line: String) -> Date? {
        var text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("-") || text.hasPrefix("*") {
            text.removeFirst()
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let separator = text.range(of: " - ") else { return nil }
        let rawDate = String(text[..<separator.lowerBound])
        guard looksLikeISO8601Prefix(rawDate) else { return nil }
        return iso8601Formatter.date(from: rawDate)
    }

    private static func looksLikeISO8601Prefix(_ text: String) -> Bool {
        text.count >= 20 && text.contains("T") && text.hasSuffix("Z")
    }

    private static func sanitize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "<!--", with: "")
            .replacingOccurrences(of: "-->", with: "")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
