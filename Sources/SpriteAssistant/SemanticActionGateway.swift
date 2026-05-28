import CMUXActions
import Foundation

extension ActionIntent {
    var trustDescriptor: CmuxActionTrustDescriptor {
        CmuxActionTrustDescriptor(
            schemaVersion: 2,
            actionID: "sprite.\(kind.rawValue)",
            kind: kind.rawValue,
            command: nil,
            target: trustTarget,
            workspaceCommand: nil,
            configPath: nil,
            projectRoot: nil,
            iconFingerprint: nil,
            workspaceId: primaryWorkspaceId?.uuidString,
            assistantRoute: requestedBy.route,
            normalizedArgumentsHash: Self.stableHash(arguments),
            contextSnapshotHash: Self.contextSnapshotHash(evidence)
        )
    }

    private var trustTarget: String? {
        arguments["workspaceId"]
            ?? arguments["itemId"]
            ?? arguments["itemIds"]
            ?? arguments["domain"]
    }

    private var primaryWorkspaceId: UUID? {
        if let workspaceId = arguments["workspaceId"].flatMap(UUID.init(uuidString:)) {
            return workspaceId
        }
        if let itemId = arguments["itemId"].flatMap(UUID.init(uuidString:)) {
            return itemId
        }
        return evidence.snapshotVersions.keys.sorted { $0.uuidString < $1.uuidString }.first
    }

    private static func contextSnapshotHash(_ evidence: ActionEvidence) -> String? {
        var pairs = evidence.snapshotVersions.map { workspaceId, version in
            "\(workspaceId.uuidString)=\(version)"
        }
        if let suggestionId = evidence.suggestionId {
            pairs.append("suggestion=\(suggestionId.uuidString)")
        }
        if let rankingSnapshotId = evidence.rankingSnapshotId {
            pairs.append("ranking=\(rankingSnapshotId.uuidString)")
        }
        guard !pairs.isEmpty else { return nil }
        return stableHash(pairs)
    }

    private static func stableHash(_ arguments: [String: String]) -> String? {
        guard !arguments.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(arguments) else { return nil }
        return CmuxActionTrustDescriptor.sha256Hex(data)
    }

    private static func stableHash(_ values: [String]) -> String {
        let normalized = values.sorted().joined(separator: "\u{1f}")
        return CmuxActionTrustDescriptor.sha256Hex(Data(normalized.utf8))
    }
}
