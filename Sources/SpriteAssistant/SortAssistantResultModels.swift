import Foundation
import SwiftUI

struct SortAssistantMessage: Identifiable, Equatable {
    enum Kind: Equatable {
        case user
        case assistant
        case progress
        case warning
        case error
    }

    let id: UUID
    let kind: Kind
    let text: String
    let accessibilityIdentifier: String?

    init(
        id: UUID = UUID(),
        kind: Kind,
        text: String,
        accessibilityIdentifier: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    var icon: String {
        switch kind {
        case .user: return "person"
        case .assistant: return "sparkles"
        case .progress: return "arrow.triangle.2.circlepath"
        case .warning: return "exclamationmark.triangle"
        case .error: return "exclamationmark.triangle"
        }
    }

    var tint: Color {
        switch kind {
        case .user: return .secondary
        case .assistant: return .accentColor
        case .progress: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }
}

struct SortAssistantProactiveSuggestionDigest: Equatable, Sendable {
    let signature: String
    let text: String
    let suggestionIds: [UUID]
    let foldedSuggestionIds: Set<UUID>
}

struct SortAssistantProactiveNotificationDigestItem: Sendable {
    let id: UUID
    let workspaceId: UUID
    let workspaceTitle: String
    let type: String
    let title: String
    let reason: String?
    let confidence: Double
}

struct SortAssistantProactiveNotificationDigestRequest: Sendable {
    let items: [SortAssistantProactiveNotificationDigestItem]
    let conversationContext: [String]
    let claudeSessionId: UUID?
    let claudeSessionReused: Bool
    let debugSession: SortAssistantDebugSession?
}

struct SortAssistantProactiveNotificationDigestResult: Sendable {
    let sentence: String
    let foldedSuggestionIds: Set<UUID>
}

struct SortAssistantDimensionQuestion: Equatable {
    let goal: String
    let mode: SortAssistantRunMode
}

struct SortAssistantWorkspaceTarget: Equatable, Sendable {
    let id: UUID
    let title: String
    let directory: String?
}

struct SortAssistantChoicePrompt: Identifiable, Equatable, Sendable {
    struct Option: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
        let subtitle: String?
        let goal: String
    }

    struct Question: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
        let message: String?
        let options: [Option]
    }

    let id: UUID
    let title: String
    let message: String?
    let options: [Option]
    let questions: [Question]
    let followUpIntent: SortAssistantIntent?
    let routeSteps: [SortAssistantRouteStep]?
    let forceApply: Bool
    let workspaceTarget: SortAssistantWorkspaceTarget?
    let explicitSlashCommand: Bool

    var isMultiQuestion: Bool {
        questions.count > 1
    }

    var forceApplyOnSubmit: Bool {
        forceApply || followUpIntent == .applySort
    }

    var intentOnSubmit: SortAssistantIntent {
        followUpIntent ?? (forceApplyOnSubmit ? .applySort : .proposeSort)
    }

    init(
        id: UUID = UUID(),
        title: String,
        message: String?,
        options: [Option],
        questions: [Question]? = nil,
        followUpIntent: SortAssistantIntent? = nil,
        routeSteps: [SortAssistantRouteStep]? = nil,
        forceApply: Bool = false,
        workspaceTarget: SortAssistantWorkspaceTarget? = nil,
        explicitSlashCommand: Bool = false
    ) {
        self.id = id
        self.title = title
        self.message = message
        self.options = options
        if let questions, !questions.isEmpty {
            self.questions = questions
        } else {
            self.questions = [
                Question(
                    id: "primary",
                    title: title,
                    message: message,
                    options: options
                )
            ]
        }
        self.followUpIntent = followUpIntent
        self.routeSteps = routeSteps?.isEmpty == false ? routeSteps : nil
        self.forceApply = forceApply
        self.workspaceTarget = workspaceTarget
        self.explicitSlashCommand = explicitSlashCommand
    }

    func preparedForFollowUp(
        intent: SortAssistantIntent,
        routeSteps: [SortAssistantRouteStep]?,
        forceApply: Bool,
        workspaceTarget: SortAssistantWorkspaceTarget?,
        explicitSlashCommand: Bool = false
    ) -> SortAssistantChoicePrompt {
        SortAssistantChoicePrompt(
            id: id,
            title: title,
            message: message,
            options: options,
            questions: questions,
            followUpIntent: followUpIntent ?? intent,
            routeSteps: self.routeSteps ?? routeSteps,
            forceApply: self.forceApply || forceApply,
            workspaceTarget: self.workspaceTarget ?? workspaceTarget,
            explicitSlashCommand: self.explicitSlashCommand || explicitSlashCommand
        )
    }
}

enum SortAssistantResultMode: Equatable, Sendable {
    case preview
    case applied
}

enum SortAssistantRunMode: Equatable, Sendable {
    case preview
    case apply

    var assistantContextValue: String {
        switch self {
        case .preview: return "preview"
        case .apply: return "applied"
        }
    }
}

enum SortAssistantResultAction: String, Codable, Hashable, CaseIterable, Sendable {
    case apply
    case partialApply = "partial_apply"
    case ignore
    case explain
    case undo
    case remember
}

struct SortAssistantSortResult: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let goal: String
    let dimensionLabel: String
    let changes: [String]
    let rationale: String?
    let patchId: UUID?
    var mode: SortAssistantResultMode
    var canUndo: Bool
    var canApply: Bool
    var canApplyPartially: Bool
    var canIgnore: Bool
    var actions: [SortAssistantResultAction]
}

struct SortAssistantMemory: Identifiable, Codable, Equatable {
    let id: UUID
    var text: String
    let createdAt: Date
}

struct SortAssistantMemoryCandidate: Identifiable, Equatable {
    enum Target: Equatable {
        case freeSort
        case sprite
    }

    let id = UUID()
    var text: String
    let sourceSummary: String?
    let target: Target

    init(text: String, sourceSummary: String?, target: Target = .freeSort) {
        self.text = text
        self.sourceSummary = sourceSummary
        self.target = target
    }
}

struct SortAssistantSemanticActionConfirmation: Identifiable, Equatable {
    let id: UUID
    let title: String
    let message: String
    let reasons: [String]
    let actionName: String
}

struct SortAssistantResultPresentation: Equatable {
    let markdown: String?
    let actions: [SortAssistantResultAction]

    static func parse(_ raw: String?) -> SortAssistantResultPresentation {
        guard let raw else {
            return SortAssistantResultPresentation(markdown: nil, actions: [])
        }
        var markdown = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var parsedActions: [SortAssistantResultAction] = []

        if markdown.hasPrefix("---\n"),
           let closingRange = markdown.range(of: "\n---", range: markdown.index(markdown.startIndex, offsetBy: 4)..<markdown.endIndex) {
            let metaBlock = String(markdown[markdown.index(markdown.startIndex, offsetBy: 4)..<closingRange.lowerBound])
            parsedActions.append(contentsOf: actions(fromFrontMatter: metaBlock))
            let bodyStart = markdown.index(closingRange.upperBound, offsetBy: 0)
            markdown = String(markdown[bodyStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let commentRange = markdown.range(of: "<!-- cmux-meta:"),
           let endRange = markdown.range(of: "-->", range: commentRange.upperBound..<markdown.endIndex) {
            let json = String(markdown[commentRange.upperBound..<endRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            parsedActions.append(contentsOf: actions(fromJSON: json))
            markdown.removeSubrange(commentRange.lowerBound..<endRange.upperBound)
            markdown = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return SortAssistantResultPresentation(
            markdown: markdown.isEmpty ? nil : markdown,
            actions: unique(parsedActions)
        )
    }

    private static func actions(fromFrontMatter metaBlock: String) -> [SortAssistantResultAction] {
        for line in metaBlock.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "-", with: "_")
            guard ["cmux_result_actions", "result_actions", "actions"].contains(key) else { continue }
            return actions(fromList: parts[1])
        }
        return []
    }

    private static func actions(fromJSON json: String) -> [SortAssistantResultAction] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        let value = object["cmux_result_actions"] ?? object["result_actions"] ?? object["actions"]
        if let list = value as? [String] {
            return list.compactMap(SortAssistantResultAction.init(rawValue:))
        }
        if let string = value as? String {
            return actions(fromList: string)
        }
        return []
    }

    private static func actions(fromList raw: String) -> [SortAssistantResultAction] {
        raw
            .trimmingCharacters(in: CharacterSet(charactersIn: " []"))
            .split { character in
                character == "," || character == " " || character == "\t"
            }
            .map { token in
                token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'[] \t"))
            }
            .compactMap(SortAssistantResultAction.init(rawValue:))
    }

    private static func unique(_ actions: [SortAssistantResultAction]) -> [SortAssistantResultAction] {
        var seen: Set<SortAssistantResultAction> = []
        return actions.filter { seen.insert($0).inserted }
    }
}
