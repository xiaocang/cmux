import CMUXPluginAPI
import Foundation

final class CMUXSpriteAssistantPlugin: CMUXPlugin {
    let manifest = CMUXPluginManifest(
        id: CMUXBuiltinPluginID.spriteAssistant,
        name: "cmux Sprite Assistant",
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
                    title: "Sprite Assistant",
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
                    title: "Query Free Sort Memories"
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
                    title: "Create Free Sort Memory Candidate"
                ) { input in
                    guard let text = CMUXPluginParams.string(input.params, "text", "memory") else {
                        throw CMUXSocketCommandError(
                            code: "invalid_params",
                            message: "memory.write_candidate requires params.text"
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
                    title: "Forget Free Sort Memory"
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
                    title: "Query Sprite Workspace Memory"
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
                    title: "Write Sprite Workspace Memory"
                ) { input in
                    guard let text = CMUXPluginParams.string(input.params, "text", "memory") else {
                        throw CMUXSocketCommandError(
                            code: "invalid_params",
                            message: "sprite.memory.write requires params.text"
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
                    title: "Write Sprite Workspace Memory"
                ) { input in
                    guard let text = CMUXPluginParams.string(input.params, "text", "memory") else {
                        throw CMUXSocketCommandError(
                            code: "invalid_params",
                            message: "sprite.memory.write_candidate requires params.text"
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
                    title: "Forget Sprite Workspace Memory"
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
                    title: "Sprite Sort Context"
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
                    title: "Preview Sprite Sort Patch"
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
                    title: "Apply Sprite Sort Patch"
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
                    title: "Undo Sprite Sort"
                ) { _ in
                    try runOnMainSyncThrowing {
                        guard let payload = SortAssistantCoordinator.shared.socketSortUndo() else {
                            throw CMUXSocketCommandError(
                                code: "not_found",
                                message: "No assistant sort is available to undo"
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
                    title: "Explain Sprite Sort"
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
                    title: "Sprite Sort List State"
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
                    id: "github.context",
                    title: "Sprite GitHub Context"
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
                    id: "list.lock",
                    title: "Lock Sprite Sort List Item"
                ) { input in
                    guard let itemId = Self.uuid(input.params["itemId"] ?? input.params["item_id"]) else {
                        throw CMUXSocketCommandError(
                            code: "invalid_params",
                            message: "list.lock requires params.itemId"
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
                    title: "Pin Sprite Sort List Item"
                ) { input in
                    guard let itemId = Self.uuid(input.params["itemId"] ?? input.params["item_id"]) else {
                        throw CMUXSocketCommandError(
                            code: "invalid_params",
                            message: "list.pin requires params.itemId"
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
            message: "Sprite assistant needs an attached workspace sidebar before this tool can run"
        )
    }
}
