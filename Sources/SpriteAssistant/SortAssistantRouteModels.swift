import Foundation

enum SortAssistantIntent: String, Equatable, Sendable {
    case askContext = "ask_context"
    case clearSession = "clear_session"
    case explainCurrentOrder = "explain_current_order"
    case proposeSort = "propose_sort"
    case applySort = "apply_sort"
    case manualReorderFeedback = "manual_reorder_feedback"
    case rememberPreference = "remember_preference"
    case forgetPreference = "forget_preference"
    case rememberSpriteMemory = "remember_sprite_memory"
    case forgetSpriteMemory = "forget_sprite_memory"
    case undoSort = "undo_sort"
    case workspaceColor = "workspace_color"
    case normalChat = "normal_chat"

    var isSortRouted: Bool {
        self == .proposeSort || self == .applySort
    }
}

enum SortAssistantSortRoute: String, Equatable, Sendable {
    case colorGroup = "color_group"
}

struct SortAssistantRouteStep: Equatable, Sendable {
    let intent: SortAssistantIntent
    let sortRoute: SortAssistantSortRoute?

    init(
        intent: SortAssistantIntent,
        sortRoute: SortAssistantSortRoute? = nil
    ) {
        self.intent = intent
        self.sortRoute = intent.isSortRouted ? sortRoute : nil
    }

    var debugDescription: String {
        guard let sortRoute else { return intent.rawValue }
        return "\(intent.rawValue):\(sortRoute.rawValue)"
    }

    static func normalizing(
        _ steps: [SortAssistantRouteStep]?,
        fallback: SortAssistantRouteStep
    ) -> [SortAssistantRouteStep] {
        let source = (steps?.isEmpty == false) ? steps! : [fallback]
        var result: [SortAssistantRouteStep] = []
        for step in source where result.last != step {
            result.append(step)
        }
        return result.isEmpty ? [fallback] : result
    }
}

enum SortAssistantRouteAdjustmentMode: String, Equatable, Sendable {
    case append
    case replace
}

struct SortAssistantRouteAdjustment: Equatable, Sendable {
    static let empty = SortAssistantRouteAdjustment()

    let promptFragmentMode: SortAssistantRouteAdjustmentMode
    let promptFragments: [String]
    let removedPromptFragments: [String]
    let allowedToolsMode: SortAssistantRouteAdjustmentMode
    let allowedTools: [String]
    let removedAllowedTools: [String]

    init(
        promptFragmentMode: SortAssistantRouteAdjustmentMode = .append,
        promptFragments: [String] = [],
        removedPromptFragments: [String] = [],
        allowedToolsMode: SortAssistantRouteAdjustmentMode = .append,
        allowedTools: [String] = [],
        removedAllowedTools: [String] = []
    ) {
        self.promptFragmentMode = promptFragmentMode
        self.promptFragments = normalizedSortAssistantPromptFragments(promptFragments)
        self.removedPromptFragments = normalizedSortAssistantPromptFragments(removedPromptFragments)
        self.allowedToolsMode = allowedToolsMode
        self.allowedTools = normalizedSortAssistantProductionInternalTools(allowedTools)
        self.removedAllowedTools = normalizedSortAssistantProductionInternalTools(removedAllowedTools)
    }

    var isEmpty: Bool {
        promptFragmentMode == .append
            && promptFragments.isEmpty
            && removedPromptFragments.isEmpty
            && allowedToolsMode == .append
            && allowedTools.isEmpty
            && removedAllowedTools.isEmpty
    }

    var restrictsAllowedTools: Bool {
        allowedToolsMode == .replace || !removedAllowedTools.isEmpty
    }

    func applyingPromptFragments(to base: [String]) -> [String] {
        let starting = promptFragmentMode == .replace ? [] : normalizedSortAssistantPromptFragments(base)
        let removed = Set(removedPromptFragments)
        return orderedUniqueSortAssistant(starting + promptFragments).filter { !removed.contains($0) }
    }

    func applyingAllowedTools(to base: [String]) -> [String] {
        let starting = allowedToolsMode == .replace ? [] : normalizedSortAssistantInternalTools(base)
        let removed = Set(removedAllowedTools)
        return orderedUniqueSortAssistant(starting + allowedTools).filter { !removed.contains($0) }
    }

    func requestsMutatingTools(applyingTo base: [String]) -> Bool {
        applyingAllowedTools(to: base).contains { sortAssistantMutatingInternalTools.contains($0) }
    }

    var debugDescription: String {
        guard !isEmpty else { return "none" }
        let fragments = promptFragments.isEmpty ? "none" : promptFragments.joined(separator: ",")
        let removedFragments = removedPromptFragments.isEmpty ? "none" : removedPromptFragments.joined(separator: ",")
        let tools = allowedTools.isEmpty ? "none" : allowedTools.joined(separator: ",")
        let removedTools = removedAllowedTools.isEmpty ? "none" : removedAllowedTools.joined(separator: ",")
        return "promptMode=\(promptFragmentMode.rawValue) fragments=\(fragments) removeFragments=\(removedFragments) toolsMode=\(allowedToolsMode.rawValue) tools=\(tools) removeTools=\(removedTools)"
    }
}

extension Array where Element == SortAssistantRouteStep {
    var debugDescriptionJoined: String {
        let description = map(\.debugDescription).joined(separator: ">")
        return description.isEmpty ? "none" : description
    }
}

struct SortAssistantIntentDecision: Equatable, Sendable {
    let intent: SortAssistantIntent
    let confidence: Double
    let reason: String?
    let sortRoute: SortAssistantSortRoute?
    let isFallback: Bool
    let steps: [SortAssistantRouteStep]
    let routeAdjustment: SortAssistantRouteAdjustment
    let semanticRouterUnavailableReport: SortAssistantSemanticRouterUnavailableReport?

    init(
        intent: SortAssistantIntent,
        confidence: Double,
        reason: String?,
        sortRoute: SortAssistantSortRoute? = nil,
        isFallback: Bool = false,
        steps: [SortAssistantRouteStep]? = nil,
        routeAdjustment: SortAssistantRouteAdjustment = .empty,
        semanticRouterUnavailableReport: SortAssistantSemanticRouterUnavailableReport? = nil
    ) {
        let primarySortRoute = intent.isSortRouted ? sortRoute : nil
        let primaryStep = SortAssistantRouteStep(intent: intent, sortRoute: primarySortRoute)
        let normalizedSteps = SortAssistantRouteStep.normalizing(steps, fallback: primaryStep)
        let matchingStepSortRoute = normalizedSteps.first(where: { $0.intent == intent })?.sortRoute
        self.intent = intent
        self.confidence = confidence
        self.reason = reason
        self.sortRoute = primarySortRoute ?? matchingStepSortRoute
        self.isFallback = isFallback
        self.steps = normalizedSteps
        self.routeAdjustment = routeAdjustment
        self.semanticRouterUnavailableReport = semanticRouterUnavailableReport
    }

    var containsClearSession: Bool {
        intent == .clearSession || steps.contains { $0.intent == .clearSession }
    }

    var stepDebugDescription: String {
        steps.debugDescriptionJoined
    }
}

struct SortAssistantSemanticRouterIssue: Equatable, Sendable {
    enum Stage: String, Equatable, Sendable {
        case local
        case claude
    }

    let stage: Stage
    let code: String
    let detail: String?
    let status: Int?
    let timeoutSeconds: Int?

    init(
        stage: Stage,
        code: String,
        detail: String? = nil,
        status: Int? = nil,
        timeoutSeconds: Int? = nil
    ) {
        self.stage = stage
        self.code = code
        let trimmedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.detail = trimmedDetail.isEmpty ? nil : trimmedDetail
        self.status = status
        self.timeoutSeconds = timeoutSeconds
    }

    var debugDescription: String {
        var fields = [
            "stage=\(stage.rawValue)",
            "code=\(code)",
        ]
        if let status {
            fields.append("status=\(status)")
        }
        if let timeoutSeconds {
            fields.append("timeoutSeconds=\(timeoutSeconds)")
        }
        if let detail {
            fields.append("detail=\(detail)")
        }
        return fields.joined(separator: " ")
    }
}

struct SortAssistantSemanticRouterUnavailableReport: Equatable, Sendable {
    let reason: String
    let fallbackIntent: SortAssistantIntent
    let localIssue: SortAssistantSemanticRouterIssue?
    let claudeIssue: SortAssistantSemanticRouterIssue?

    var debugDescription: String {
        [
            "reason=\(reason)",
            "fallbackIntent=\(fallbackIntent.rawValue)",
            localIssue.map { "local={\($0.debugDescription)}" },
            claudeIssue.map { "claude={\($0.debugDescription)}" },
        ]
        .compactMap { $0 }
        .joined(separator: " ")
    }
}

struct SortAssistantLocalSemanticRouterTestResult: Equatable, Sendable {
    let request: String
    let decision: SortAssistantIntentDecision
    let expectedIntent: SortAssistantIntent
    let passed: Bool
}

enum SortAssistantActionMode: String, Equatable, Sendable {
    case readOnly = "read_only"
    case previewOnly = "preview_only"
    case applyAllowed = "apply_allowed"
}

enum SortAssistantMemoryWritePolicy: String, Equatable, Sendable {
    case none
    case eventLog = "event_log"
    case candidate
    case longTerm = "long_term"
}

struct SortAssistantActionRoute: Equatable, Sendable {
    let mode: SortAssistantActionMode
    let needsConfirmation: Bool
    let allowedTools: [String]
    let memoryWritePolicy: SortAssistantMemoryWritePolicy

    var runMode: SortAssistantRunMode {
        mode == .applyAllowed && !needsConfirmation ? .apply : .preview
    }

    func bypassingPreOperationConfirmation() -> SortAssistantActionRoute {
        SortAssistantActionRoute(
            mode: mode,
            needsConfirmation: false,
            allowedTools: allowedTools,
            memoryWritePolicy: memoryWritePolicy
        )
    }

    func applying(
        _ adjustment: SortAssistantRouteAdjustment,
        emptyAllowedToolsFallback: [String] = []
    ) -> SortAssistantActionRoute {
        guard !adjustment.isEmpty else { return self }
        let adjustedAllowedTools = adjustment.applyingAllowedTools(to: allowedTools)
        let nextAllowedTools = adjustedAllowedTools.isEmpty
            ? normalizedSortAssistantProductionInternalTools(emptyAllowedToolsFallback)
            : adjustedAllowedTools
        let nextHasMutatingTools = nextAllowedTools.contains { sortAssistantMutatingInternalTools.contains($0) }
        let nextMode: SortAssistantActionMode
        if nextHasMutatingTools {
            nextMode = .applyAllowed
        } else if nextAllowedTools.contains("sort_preview") {
            nextMode = .previewOnly
        } else if adjustment.restrictsAllowedTools, mode == .applyAllowed || mode == .previewOnly {
            nextMode = .readOnly
        } else {
            nextMode = mode
        }
        return SortAssistantActionRoute(
            mode: nextMode,
            needsConfirmation: nextMode == .readOnly ? false : needsConfirmation,
            allowedTools: nextAllowedTools,
            memoryWritePolicy: memoryWritePolicy
        )
    }
}
