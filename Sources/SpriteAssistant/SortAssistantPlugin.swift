import CMUXPluginAPI
import Foundation

final class CMUXSpriteAssistantPlugin: CMUXPlugin {
    let manifest = CMUXPluginManifest(
        id: CMUXBuiltinPluginID.spriteAssistant,
        name: String(localized: "sortAssistant.plugin.name", defaultValue: "cmux Sprite Assistant"),
        version: "0.1.0",
        activation: ["onAppStart"],
        permissions: [
            "commands:register",
            "window-overlay:contribute",
            "workspace:read",
            "workspace:write",
        ]
    )

    private var disposables: [CMUXPluginDisposable] = []

    func activate(context: CMUXPluginContext) {
        registerWindowOverlays(context: context)
        registerSocketCommands(context: context)
    }

    func deactivate() {
        disposables.forEach { $0.dispose() }
        disposables.removeAll()
    }

    private func registerWindowOverlays(context: CMUXPluginContext) {
        disposables.append(
            context.windowOverlays.registerWindowOverlay(
                CMUXWindowOverlayContribution(
                    id: CMUXBuiltinWindowOverlayID.spriteAssistant,
                    title: String(localized: "sortAssistant.plugin.overlay.title", defaultValue: "Sprite Assistant"),
                    placement: .windowRootFloating,
                    priority: 100,
                    metadata: [
                        "renderer": CMUXBuiltinWindowOverlayRenderer.spriteAssistant,
                    ]
                )
            )
        )
    }

    private func registerSocketCommands(context: CMUXPluginContext) {
        disposables.append(
            context.commands.registerSocketCommand(
                CMUXSocketCommandContribution(
                    id: "memory.query",
                    title: String(localized: "sortAssistant.plugin.command.memoryQuery", defaultValue: "Query Free Sort Memories")
                ) { _ in
                    runOnMainSync {
                        .ok(SortAssistantCoordinator.shared.socketMemoryQuery())
                    }
                }
            )
        )

        disposables.append(
            context.commands.registerSocketCommand(
                CMUXSocketCommandContribution(
                    id: "memory.write_candidate",
                    title: String(localized: "sortAssistant.plugin.command.memoryWriteCandidate", defaultValue: "Create Free Sort Memory Candidate")
                ) { input in
                    guard let text = CMUXPluginParams.string(input.params, "text", "memory") else {
                        throw CMUXSocketCommandError(
                            code: "invalid_params",
                            message: String(localized: "sortAssistant.plugin.error.memoryWriteCandidateText", defaultValue: "memory.write_candidate requires params.text")
                        )
                    }
                    return runOnMainSync {
                        .ok(SortAssistantCoordinator.shared.socketWriteMemoryCandidate(
                            text: text,
                            sourceSummary: CMUXPluginParams.string(input.params, "sourceSummary", "source_summary")
                        ))
                    }
                }
            )
        )

        disposables.append(
            context.commands.registerSocketCommand(
                CMUXSocketCommandContribution(
                    id: "memory.forget",
                    title: String(localized: "sortAssistant.plugin.command.memoryForget", defaultValue: "Forget Free Sort Memory")
                ) { input in
                    runOnMainSync {
                        .ok(SortAssistantCoordinator.shared.socketForgetMemory(
                            id: CMUXPluginParams.string(input.params, "id", "memoryId", "memory_id"),
                            text: CMUXPluginParams.string(input.params, "text", "contains")
                        ))
                    }
                }
            )
        )

        disposables.append(
            context.commands.registerSocketCommand(
                CMUXSocketCommandContribution(
                    id: "sprite.memory.query",
                    title: String(localized: "sortAssistant.plugin.command.spriteMemoryQuery", defaultValue: "Query Sprite Workspace Memory")
                ) { input in
                    runOnMainSync {
                        .ok(SortAssistantCoordinator.shared.socketSpriteMemoryQuery(
                            directory: CMUXPluginParams.string(input.params, "directory", "cwd", "workspaceDirectory", "workspace_directory")
                        ))
                    }
                }
            )
        )

        disposables.append(
            context.commands.registerSocketCommand(
                CMUXSocketCommandContribution(
                    id: "sprite.memory.write",
                    title: String(localized: "sortAssistant.plugin.command.spriteMemoryWrite", defaultValue: "Write Sprite Workspace Memory")
                ) { input in
                    guard let text = CMUXPluginParams.string(input.params, "text", "memory") else {
                        throw CMUXSocketCommandError(
                            code: "invalid_params",
                            message: String(localized: "sortAssistant.plugin.error.spriteMemoryWriteText", defaultValue: "sprite.memory.write requires params.text")
                        )
                    }
                    return runOnMainSync {
                        .ok(SortAssistantCoordinator.shared.socketWriteSpriteMemory(
                            text: text,
                            sourceSummary: CMUXPluginParams.string(input.params, "sourceSummary", "source_summary"),
                            directory: CMUXPluginParams.string(input.params, "directory", "cwd", "workspaceDirectory", "workspace_directory")
                        ))
                    }
                }
            )
        )

        disposables.append(
            context.commands.registerSocketCommand(
                CMUXSocketCommandContribution(
                    id: "sprite.memory.write_candidate",
                    title: String(localized: "sortAssistant.plugin.command.spriteMemoryWrite", defaultValue: "Write Sprite Workspace Memory")
                ) { input in
                    guard let text = CMUXPluginParams.string(input.params, "text", "memory") else {
                        throw CMUXSocketCommandError(
                            code: "invalid_params",
                            message: String(localized: "sortAssistant.plugin.error.spriteMemoryWriteCandidateText", defaultValue: "sprite.memory.write_candidate requires params.text")
                        )
                    }
                    return runOnMainSync {
                        .ok(SortAssistantCoordinator.shared.socketWriteSpriteMemory(
                            text: text,
                            sourceSummary: CMUXPluginParams.string(input.params, "sourceSummary", "source_summary"),
                            directory: CMUXPluginParams.string(input.params, "directory", "cwd", "workspaceDirectory", "workspace_directory")
                        ))
                    }
                }
            )
        )

        disposables.append(
            context.commands.registerSocketCommand(
                CMUXSocketCommandContribution(
                    id: "sprite.memory.forget",
                    title: String(localized: "sortAssistant.plugin.command.spriteMemoryForget", defaultValue: "Forget Sprite Workspace Memory")
                ) { input in
                    runOnMainSync {
                        .ok(SortAssistantCoordinator.shared.socketForgetSpriteMemory(
                            id: CMUXPluginParams.string(input.params, "id", "memoryId", "memory_id"),
                            text: CMUXPluginParams.string(input.params, "text", "contains"),
                            directory: CMUXPluginParams.string(input.params, "directory", "cwd", "workspaceDirectory", "workspace_directory")
                        ))
                    }
                }
            )
        )

        disposables.append(
            context.commands.registerSocketCommand(
                CMUXSocketCommandContribution(
                    id: "sort.context",
                    title: String(localized: "sortAssistant.plugin.command.sortContext", defaultValue: "Sprite Sort Context")
                ) { input in
                    try runOnMainSyncThrowing {
                        guard let payload = SortAssistantCoordinator.shared.socketSortContext(
                            goal: CMUXPluginParams.string(input.params, "goal", "userIntent", "user_intent") ?? ""
                        ) else {
                            throw Self.unavailable()
                        }
                        return .ok(["context": payload])
                    }
                }
            )
        )

        disposables.append(
            context.commands.registerSocketCommand(
                CMUXSocketCommandContribution(
                    id: "sort.preview",
                    title: String(localized: "sortAssistant.plugin.command.sortPreview", defaultValue: "Preview Sprite Sort Patch")
                ) { input in
                    try runOnMainSyncThrowing {
                        guard let payload = SortAssistantCoordinator.shared.socketSortPreview(
                            goal: CMUXPluginParams.string(input.params, "goal") ?? "",
                            itemIds: Self.uuidArray(input.params["itemIds"] ?? input.params["item_ids"])
                        ) else {
                            throw Self.unavailable()
                        }
                        return .ok(payload)
                    }
                }
            )
        )

        disposables.append(
            context.commands.registerSocketCommand(
                CMUXSocketCommandContribution(
                    id: "sort.apply",
                    title: String(localized: "sortAssistant.plugin.command.sortApply", defaultValue: "Apply Sprite Sort Patch")
                ) { input in
                    try runOnMainSyncThrowing {
                        guard let payload = SortAssistantCoordinator.shared.socketSortApply(
                            patchId: Self.uuid(input.params["patchId"] ?? input.params["patch_id"]),
                            itemIds: Self.uuidArray(input.params["itemIds"] ?? input.params["item_ids"])
                        ) else {
                            throw Self.unavailable()
                        }
                        return .ok(payload)
                    }
                }
            )
        )

        disposables.append(
            context.commands.registerSocketCommand(
                CMUXSocketCommandContribution(
                    id: "sort.undo",
                    title: String(localized: "sortAssistant.plugin.command.sortUndo", defaultValue: "Undo Sprite Sort")
                ) { _ in
                    try runOnMainSyncThrowing {
                        guard let payload = SortAssistantCoordinator.shared.socketSortUndo() else {
                            throw CMUXSocketCommandError(
                                code: "not_found",
                                message: String(localized: "sortAssistant.plugin.error.noSortToUndo", defaultValue: "No assistant sort is available to undo")
                            )
                        }
                        return .ok(payload)
                    }
                }
            )
        )

        disposables.append(
            context.commands.registerSocketCommand(
                CMUXSocketCommandContribution(
                    id: "sort.explain",
                    title: String(localized: "sortAssistant.plugin.command.sortExplain", defaultValue: "Explain Sprite Sort")
                ) { _ in
                    runOnMainSync {
                        .ok(SortAssistantCoordinator.shared.socketSortExplain())
                    }
                }
            )
        )

        disposables.append(
            context.commands.registerSocketCommand(
                CMUXSocketCommandContribution(
                    id: "list.state",
                    title: String(localized: "sortAssistant.plugin.command.listState", defaultValue: "Sprite Sort List State")
                ) { _ in
                    try runOnMainSyncThrowing {
                        guard let payload = SortAssistantCoordinator.shared.socketListState() else {
                            throw Self.unavailable()
                        }
                        return .ok(payload)
                    }
                }
            )
        )

        disposables.append(
            context.commands.registerSocketCommand(
                CMUXSocketCommandContribution(
                    id: "assistant.working_context.get",
                    title: String(localized: "sortAssistant.plugin.command.assistantWorkingContext", defaultValue: "Sprite Assistant Working Context")
                ) { _ in
                    try runOnMainSyncThrowing {
                        guard let payload = SortAssistantCoordinator.shared.socketAssistantWorkingContext() else {
                            throw Self.unavailable()
                        }
                        return .ok(payload)
                    }
                }
            )
        )

        disposables.append(
            context.commands.registerSocketCommand(
                CMUXSocketCommandContribution(
                    id: "workspace.snapshot.get",
                    title: String(localized: "sortAssistant.plugin.command.workspaceSnapshot", defaultValue: "Sprite Workspace Snapshot")
                ) { input in
                    try runOnMainSyncThrowing {
                        guard let payload = SortAssistantCoordinator.shared.socketWorkspaceSnapshot(
                            workspaceId: CMUXPluginParams.string(input.params, "workspaceId", "workspace_id")
                        ) else {
                            throw Self.unavailable()
                        }
                        return .ok(payload)
                    }
                }
            )
        )

        disposables.append(
            context.commands.registerSocketCommand(
                CMUXSocketCommandContribution(
                    id: "context.freshness.get",
                    title: String(localized: "sortAssistant.plugin.command.contextFreshness", defaultValue: "Sprite Context Freshness")
                ) { input in
                    try runOnMainSyncThrowing {
                        guard let payload = SortAssistantCoordinator.shared.socketContextFreshness(
                            workspaceId: CMUXPluginParams.string(input.params, "workspaceId", "workspace_id")
                        ) else {
                            throw Self.unavailable()
                        }
                        return .ok(payload)
                    }
                }
            )
        )

        disposables.append(
            context.commands.registerSocketCommand(
                CMUXSocketCommandContribution(
                    id: "suggestions.active.get",
                    title: String(localized: "sortAssistant.plugin.command.activeSuggestions", defaultValue: "Sprite Active Suggestions")
                ) { _ in
                    try runOnMainSyncThrowing {
                        guard let payload = SortAssistantCoordinator.shared.socketActiveSuggestions() else {
                            throw Self.unavailable()
                        }
                        return .ok(payload)
                    }
                }
            )
        )

        disposables.append(
            context.commands.registerSocketCommand(
                CMUXSocketCommandContribution(
                    id: "context.agent.collect",
                    title: String(localized: "sortAssistant.plugin.command.contextAgentCollect", defaultValue: "ContextAgent Collect")
                ) { input in
                    try runOnMainSyncThrowing {
                        guard let payload = SortAssistantCoordinator.shared.socketContextAgentCollect(
                            workspaceId: CMUXPluginParams.string(input.params, "workspaceId", "workspace_id"),
                            providerIds: CMUXPluginParams.array(input.params["providerIds"] ?? input.params["provider_ids"]),
                            reason: CMUXPluginParams.string(input.params, "reason")
                        ) else {
                            throw Self.unavailable()
                        }
                        return .ok(payload)
                    }
                }
            )
        )

        disposables.append(
            context.commands.registerSocketCommand(
                CMUXSocketCommandContribution(
                    id: "proactive.suggestions.refresh",
                    title: String(localized: "sortAssistant.plugin.command.proactiveSuggestionsRefresh", defaultValue: "Refresh Proactive Suggestions")
                ) { _ in
                    try runOnMainSyncThrowing {
                        guard let payload = SortAssistantCoordinator.shared.socketProactiveSuggestionsRefresh() else {
                            throw Self.unavailable()
                        }
                        return .ok(payload)
                    }
                }
            )
        )

        disposables.append(
            context.commands.registerSocketCommand(
                CMUXSocketCommandContribution(
                    id: "proactive.signal.report",
                    title: String(localized: "sortAssistant.plugin.command.proactiveSignalReport", defaultValue: "Report Proactive Signal")
                ) { input in
                    try runOnMainSyncThrowing {
                        guard let payload = SortAssistantCoordinator.shared.socketReportProactiveSignal(
                            workspaceId: CMUXPluginParams.string(input.params, "workspaceId", "workspace_id"),
                            status: CMUXPluginParams.string(input.params, "status", "state"),
                            title: CMUXPluginParams.string(input.params, "title"),
                            rankReason: CMUXPluginParams.string(input.params, "rankReason", "rank_reason"),
                            nextAction: CMUXPluginParams.string(input.params, "nextAction", "next_action"),
                            summary: CMUXPluginParams.string(input.params, "summary"),
                            priorityScore: CMUXPluginParams.double(input.params["priorityScore"] ?? input.params["priority_score"]),
                            userAttentionNeeded: CMUXPluginParams.double(input.params["userAttentionNeeded"] ?? input.params["user_attention_needed"] ?? input.params["attention"]),
                            source: CMUXPluginParams.string(input.params, "source")
                        ) else {
                            throw Self.unavailable()
                        }
                        return .ok(payload)
                    }
                }
            )
        )

        disposables.append(
            context.commands.registerSocketCommand(
                CMUXSocketCommandContribution(
                    id: "suggestion.accept",
                    title: String(localized: "sortAssistant.plugin.command.suggestionAccept", defaultValue: "Accept Sprite Suggestion")
                ) { input in
                    guard let suggestionId = Self.uuid(input.params["suggestionId"] ?? input.params["suggestion_id"]) else {
                        throw CMUXSocketCommandError(
                            code: "invalid_params",
                            message: String(localized: "sortAssistant.plugin.error.suggestionAcceptId", defaultValue: "suggestion.accept requires params.suggestionId")
                        )
                    }
                    return try runOnMainSyncThrowing {
                        guard let payload = SortAssistantCoordinator.shared.socketAcceptSuggestion(suggestionId: suggestionId) else {
                            throw Self.unavailable()
                        }
                        return .ok(payload)
                    }
                }
            )
        )

        disposables.append(
            context.commands.registerSocketCommand(
                CMUXSocketCommandContribution(
                    id: "suggestion.dismiss",
                    title: String(localized: "sortAssistant.plugin.command.suggestionDismiss", defaultValue: "Dismiss Sprite Suggestion")
                ) { input in
                    guard let suggestionId = Self.uuid(input.params["suggestionId"] ?? input.params["suggestion_id"]) else {
                        throw CMUXSocketCommandError(
                            code: "invalid_params",
                            message: String(localized: "sortAssistant.plugin.error.suggestionDismissId", defaultValue: "suggestion.dismiss requires params.suggestionId")
                        )
                    }
                    return try runOnMainSyncThrowing {
                        guard let payload = SortAssistantCoordinator.shared.socketDismissSuggestion(suggestionId: suggestionId) else {
                            throw Self.unavailable()
                        }
                        return .ok(payload)
                    }
                }
            )
        )

        disposables.append(
            context.commands.registerSocketCommand(
                CMUXSocketCommandContribution(
                    id: "ranking.latest.get",
                    title: String(localized: "sortAssistant.plugin.command.latestRanking", defaultValue: "Sprite Latest Ranking")
                ) { _ in
                    try runOnMainSyncThrowing {
                        guard let payload = SortAssistantCoordinator.shared.socketLatestRanking() else {
                            throw Self.unavailable()
                        }
                        return .ok(payload)
                    }
                }
            )
        )

        disposables.append(
            context.commands.registerSocketCommand(
                CMUXSocketCommandContribution(
                    id: "github.context",
                    title: String(localized: "sortAssistant.plugin.command.githubContext", defaultValue: "Sprite GitHub Context")
                ) { input in
                    try runOnMainSyncThrowing {
                        guard let payload = SortAssistantCoordinator.shared.socketGitHubContext(
                            workspaceId: CMUXPluginParams.string(input.params, "workspaceId", "workspace_id"),
                            includeAllWorkspaces: CMUXPluginParams.bool(input.params["includeAllWorkspaces"] ?? input.params["include_all_workspaces"]) ?? false
                        ) else {
                            throw Self.unavailable()
                        }
                        return .ok(payload)
                    }
                }
            )
        )

        disposables.append(
            context.commands.registerSocketCommand(
                CMUXSocketCommandContribution(
                    id: "sprite.workspace_color.get",
                    title: String(localized: "sortAssistant.plugin.command.workspaceColorGet", defaultValue: "Sprite Workspace Color Get")
                ) { input in
                    try runOnMainSyncThrowing {
                        guard let payload = SortAssistantCoordinator.shared.socketWorkspaceColorGet(
                            workspaceId: CMUXPluginParams.string(input.params, "workspaceId", "workspace_id"),
                            includePalette: CMUXPluginParams.bool(input.params["includePalette"] ?? input.params["include_palette"]) ?? false
                        ) else {
                            throw Self.unavailable()
                        }
                        return .ok(payload)
                    }
                }
            )
        )

        disposables.append(
            context.commands.registerSocketCommand(
                CMUXSocketCommandContribution(
                    id: "sprite.workspace_color.set",
                    title: String(localized: "sortAssistant.plugin.command.workspaceColorSet", defaultValue: "Sprite Workspace Color Set")
                ) { input in
                    guard let color = CMUXPluginParams.string(input.params, "color") else {
                        throw CMUXSocketCommandError(
                            code: "invalid_params",
                            message: String(localized: "sortAssistant.plugin.error.workspaceColorSetColor", defaultValue: "sprite.workspace_color.set requires params.color")
                        )
                    }
                    return try runOnMainSyncThrowing {
                        guard let payload = SortAssistantCoordinator.shared.socketWorkspaceColorSet(
                            workspaceId: CMUXPluginParams.string(input.params, "workspaceId", "workspace_id"),
                            color: color
                        ) else {
                            throw Self.unavailable()
                        }
                        return .ok(payload)
                    }
                }
            )
        )

        disposables.append(
            context.commands.registerSocketCommand(
                CMUXSocketCommandContribution(
                    id: "sprite.workspace_color.clear",
                    title: String(localized: "sortAssistant.plugin.command.workspaceColorClear", defaultValue: "Sprite Workspace Color Clear")
                ) { input in
                    try runOnMainSyncThrowing {
                        guard let payload = SortAssistantCoordinator.shared.socketWorkspaceColorClear(
                            workspaceId: CMUXPluginParams.string(input.params, "workspaceId", "workspace_id")
                        ) else {
                            throw Self.unavailable()
                        }
                        return .ok(payload)
                    }
                }
            )
        )

        disposables.append(
            context.commands.registerSocketCommand(
                CMUXSocketCommandContribution(
                    id: "list.lock",
                    title: String(localized: "sortAssistant.plugin.command.listLock", defaultValue: "Lock Sprite Sort List Item")
                ) { input in
                    guard let itemId = Self.uuid(input.params["itemId"] ?? input.params["item_id"]) else {
                        throw CMUXSocketCommandError(
                            code: "invalid_params",
                            message: String(localized: "sortAssistant.plugin.error.listLockItemId", defaultValue: "list.lock requires params.itemId")
                        )
                    }
                    let locked = CMUXPluginParams.bool(input.params["locked"]) ?? true
                    return runOnMainSync {
                        .ok(SortAssistantCoordinator.shared.socketSetLocked(itemId: itemId, locked: locked))
                    }
                }
            )
        )

        disposables.append(
            context.commands.registerSocketCommand(
                CMUXSocketCommandContribution(
                    id: "list.pin",
                    title: String(localized: "sortAssistant.plugin.command.listPin", defaultValue: "Pin Sprite Sort List Item")
                ) { input in
                    guard let itemId = Self.uuid(input.params["itemId"] ?? input.params["item_id"]) else {
                        throw CMUXSocketCommandError(
                            code: "invalid_params",
                            message: String(localized: "sortAssistant.plugin.error.listPinItemId", defaultValue: "list.pin requires params.itemId")
                        )
                    }
                    return try runOnMainSyncThrowing {
                        guard let payload = SortAssistantCoordinator.shared.socketSetPinned(
                            itemId: itemId,
                            pinned: CMUXPluginParams.bool(input.params["pinned"]) ?? true
                        ) else {
                            throw Self.unavailable()
                        }
                        return .ok(payload)
                    }
                }
            )
        )
    }

    private static func uuid(_ value: Any?) -> UUID? {
        guard let value, !(value is NSNull) else { return nil }
        if let uuid = value as? UUID {
            return uuid
        }
        if let string = value as? String {
            return UUID(uuidString: string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func uuidArray(_ value: Any?) -> [UUID]? {
        guard let value, !(value is NSNull) else { return nil }
        if let strings = value as? [String] {
            return strings.compactMap(UUID.init(uuidString:))
        }
        if let values = value as? [Any] {
            return values.compactMap(uuid)
        }
        if let string = value as? String {
            let ids = string
                .split { $0 == "," || $0 == " " || $0 == "\n" || $0 == "\t" }
                .compactMap { UUID(uuidString: String($0)) }
            return ids.isEmpty ? nil : ids
        }
        return nil
    }

    private static func unavailable() -> CMUXSocketCommandError {
        CMUXSocketCommandError(
            code: "unavailable",
            message: String(localized: "sortAssistant.plugin.error.unavailable", defaultValue: "Sprite assistant needs an attached workspace sidebar before this tool can run")
        )
    }
}
