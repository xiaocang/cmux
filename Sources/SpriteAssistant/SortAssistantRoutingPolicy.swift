import Foundation

func orderedUniqueSortAssistant<T: Hashable>(_ values: [T]) -> [T] {
    var seen = Set<T>()
    return values.filter { seen.insert($0).inserted }
}

let sortAssistantKnownPromptFragments: [String: String] = [
    "normal_chat": "normal_chat",
    "chat": "normal_chat",
    "conversation": "normal_chat",
    "context": "context",
    "ask_context": "context",
    "askcontext": "context",
    "workspace_color": "workspace_color",
    "workspacecolor": "workspace_color",
    "workspace_colours": "workspace_color",
    "workspace_colors": "workspace_color",
    "tab_color": "workspace_color",
    "tabcolor": "workspace_color",
    "sort": "sort",
    "propose_sort": "sort",
    "apply_sort": "sort",
    "sort_color_group": "sort_color_group",
    "sortcolorgroup": "sort_color_group",
    "color_group": "sort_color_group",
    "colorgroup": "sort_color_group",
    "explain_order": "explain_order",
    "explain_current_order": "explain_order",
    "explaincurrentorder": "explain_order",
    "sort_memory": "sort_memory",
    "sortmemory": "sort_memory",
    "sprite_memory": "sprite_memory",
    "spritememory": "sprite_memory",
    "undo": "undo",
    "undo_sort": "undo",
]

let sortAssistantKnownInternalTools: Set<String> = [
    "assistant_working_context_get",
    "context_freshness_get",
    "context_collect",
    "ghpr_context",
    "ghpr_status",
    "github_context",
    "github_pr_context",
    "ghpr_refresh",
    "list_state",
    "list_lock",
    "list_pin",
    "memory_forget",
    "memory_query",
    "memory_write_candidate",
    "repository_context",
    "sort_apply",
    "sort_context",
    "sort_explain",
    "sort_preview",
    "sort_undo",
    "ranking_latest_get",
    "suggestion_accept",
    "suggestion_dismiss",
    "suggestions_active_get",
    "sprite_memory_forget",
    "sprite_memory_query",
    "sprite_memory_write",
    "workspace_color_clear",
    "workspace_color_get",
    "workspace_color_set",
    "workspace_digest_get",
    "workspace_digest_progress",
    "workspace_digest_refresh",
    "workspace_snapshot_get",
]

let sortAssistantMutatingInternalTools: Set<String> = [
    "list_lock",
    "list_pin",
    "memory_forget",
    "memory_write_candidate",
    "suggestion_accept",
    "suggestion_dismiss",
    "sort_apply",
    "sort_undo",
    "sprite_memory_forget",
    "sprite_memory_write",
    "workspace_color_clear",
    "workspace_color_set",
]

let sortAssistantDebugOnlyContextTools: Set<String> = [
    "context_collect",
    "repository_context",
    "github_context",
    "github_pr_context",
    "ghpr_context",
    "ghpr_status",
    "ghpr_refresh",
    "sort_context",
    "workspace_digest_progress",
    "workspace_digest_refresh",
]

let sortAssistantProductionAssistantTools: Set<String> = sortAssistantKnownInternalTools
    .subtracting(sortAssistantDebugOnlyContextTools)

func normalizedSortAssistantIdentifier(_ value: String) -> String {
    value
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .replacingOccurrences(of: "-", with: "_")
}

func normalizedSortAssistantPromptFragments(_ values: [String]) -> [String] {
    orderedUniqueSortAssistant(values.compactMap { value in
        sortAssistantKnownPromptFragments[normalizedSortAssistantIdentifier(value)]
    })
}

func normalizedSortAssistantInternalTools(_ values: [String]) -> [String] {
    normalizedSortAssistantInternalTools(values, allowedTools: sortAssistantKnownInternalTools)
}

func normalizedSortAssistantProductionInternalTools(_ values: [String]) -> [String] {
    normalizedSortAssistantInternalTools(values, allowedTools: sortAssistantProductionAssistantTools)
}

private func normalizedSortAssistantInternalTools(
    _ values: [String],
    allowedTools: Set<String>
) -> [String] {
    orderedUniqueSortAssistant(values.compactMap { value in
        var normalized = normalizedSortAssistantIdentifier(value)
        if normalized.hasPrefix("mcp__cmux_sprite__") {
            normalized.removeFirst("mcp__cmux_sprite__".count)
        }
        return allowedTools.contains(normalized) ? normalized : nil
    })
}

struct SortAssistantActionRouter {
    private static let contextReadTools = [
        "assistant_working_context_get",
        "workspace_snapshot_get",
        "workspace_digest_get",
        "context_freshness_get",
        "ranking_latest_get",
        "suggestions_active_get",
        "list_state",
        "sprite_memory_query",
    ]
    private static let workspaceColorTools = [
        "workspace_color_get",
        "workspace_color_set",
        "workspace_color_clear",
        "list_state",
    ]

    private static func withContextReadTools(_ tools: [String]) -> [String] {
        orderedUniqueSortAssistant(tools + contextReadTools)
    }

    func route(
        for intent: SortAssistantIntent,
        explicitSlashCommand: Bool = false
    ) -> SortAssistantActionRoute {
        let route: SortAssistantActionRoute
        switch intent {
        case .normalChat:
            route = SortAssistantActionRoute(
                mode: .readOnly,
                needsConfirmation: false,
                allowedTools: [],
                memoryWritePolicy: .none
            )
        case .askContext, .clearSession, .explainCurrentOrder:
            route = SortAssistantActionRoute(
                mode: .readOnly,
                needsConfirmation: false,
                allowedTools: Self.withContextReadTools(["memory_query", "sort_explain", "list_state"]),
                memoryWritePolicy: .none
            )
        case .proposeSort:
            route = SortAssistantActionRoute(
                mode: .previewOnly,
                needsConfirmation: true,
                allowedTools: Self.withContextReadTools(["memory_query", "sort_preview", "sort_explain", "list_state"]),
                memoryWritePolicy: .eventLog
            )
        case .applySort:
            route = SortAssistantActionRoute(
                mode: .applyAllowed,
                needsConfirmation: false,
                allowedTools: Self.withContextReadTools(["memory_query", "sort_preview", "sort_apply", "sort_undo", "list_state"]),
                memoryWritePolicy: .eventLog
            )
        case .manualReorderFeedback:
            route = SortAssistantActionRoute(
                mode: .readOnly,
                needsConfirmation: false,
                allowedTools: Self.withContextReadTools(["memory_write_candidate", "memory_query"]),
                memoryWritePolicy: .candidate
            )
        case .rememberPreference:
            route = SortAssistantActionRoute(
                mode: .readOnly,
                needsConfirmation: true,
                allowedTools: Self.withContextReadTools(["memory_write_candidate", "memory_query"]),
                memoryWritePolicy: .candidate
            )
        case .forgetPreference:
            route = SortAssistantActionRoute(
                mode: .readOnly,
                needsConfirmation: true,
                allowedTools: ["memory_forget", "memory_query"],
                memoryWritePolicy: .longTerm
            )
        case .rememberSpriteMemory:
            route = SortAssistantActionRoute(
                mode: .readOnly,
                needsConfirmation: false,
                allowedTools: Self.withContextReadTools(["sprite_memory_write", "sprite_memory_query"]),
                memoryWritePolicy: .longTerm
            )
        case .forgetSpriteMemory:
            route = SortAssistantActionRoute(
                mode: .readOnly,
                needsConfirmation: true,
                allowedTools: ["sprite_memory_forget", "sprite_memory_query"],
                memoryWritePolicy: .longTerm
            )
        case .undoSort:
            route = SortAssistantActionRoute(
                mode: .applyAllowed,
                needsConfirmation: false,
                allowedTools: ["sort_undo", "list_state"],
                memoryWritePolicy: .eventLog
            )
        case .workspaceColor:
            route = SortAssistantActionRoute(
                mode: .applyAllowed,
                needsConfirmation: false,
                allowedTools: Self.workspaceColorTools,
                memoryWritePolicy: .none
            )
        }

        guard explicitSlashCommand, intent.isSortRouted else {
            return route
        }
        return route.bypassingPreOperationConfirmation()
    }

    func route(
        for steps: [SortAssistantRouteStep],
        explicitSlashCommand: Bool = false
    ) -> SortAssistantActionRoute {
        guard steps.count > 1 else {
            return route(for: steps.first?.intent ?? .normalChat, explicitSlashCommand: explicitSlashCommand)
        }

        let routes = steps.map { step in
            route(for: step.intent, explicitSlashCommand: explicitSlashCommand)
        }
        let mode: SortAssistantActionMode
        if routes.contains(where: { $0.mode == .applyAllowed }) {
            mode = .applyAllowed
        } else if routes.contains(where: { $0.mode == .previewOnly }) {
            mode = .previewOnly
        } else {
            mode = .readOnly
        }

        return SortAssistantActionRoute(
            mode: mode,
            needsConfirmation: routes.contains { $0.needsConfirmation },
            allowedTools: orderedUniqueSortAssistant(routes.flatMap { $0.allowedTools }),
            memoryWritePolicy: Self.strongestMemoryWritePolicy(routes.map(\.memoryWritePolicy))
        )
    }

    private static func strongestMemoryWritePolicy(
        _ policies: [SortAssistantMemoryWritePolicy]
    ) -> SortAssistantMemoryWritePolicy {
        policies.max { lhs, rhs in
            memoryWritePolicyRank(lhs) < memoryWritePolicyRank(rhs)
        } ?? .none
    }

    private static func memoryWritePolicyRank(_ policy: SortAssistantMemoryWritePolicy) -> Int {
        switch policy {
        case .none:
            return 0
        case .eventLog:
            return 1
        case .candidate:
            return 2
        case .longTerm:
            return 3
        }
    }
}
