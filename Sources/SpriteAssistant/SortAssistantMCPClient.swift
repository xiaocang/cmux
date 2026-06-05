import Darwin
import Foundation
import MCP

struct SortAssistantMCPClient: Sendable {
    private static let runTimeoutSeconds: TimeInterval = 60
    private static let proactiveNotificationDigestTimeoutSeconds: TimeInterval = 18
    private static let claudeSessionInUseRetryDelays: [TimeInterval] = [0.25, 0.75, 1.5]
    private static let semanticRouterServerName = "cmux_semantic_router"
    private static let semanticRouterToolName = "route"
    private static let semanticRouterSearchToolName = "search"
    private static let semanticRouterQualifiedToolName = "mcp__cmux_semantic_router__route"
    private static let semanticRouterQualifiedSearchToolName = "mcp__cmux_semantic_router__search"
    private static let semanticRouterQualifiedToolNames = [
        semanticRouterQualifiedToolName,
        semanticRouterQualifiedSearchToolName,
    ]

    private struct PromptBundle {
        let profile: SortAssistantClaudePromptProfile
        let systemPrompt: String
        let userPrompt: String
        let fragmentNames: [String]
    }

    private struct MCPRuntimePlan {
        let mcpServers: [String: Any]
        let externalServerNames: [String]
        let externalAllowedTools: [String]
        let externalPolicy: String

        var serverNames: [String] {
            mcpServers.keys.sorted()
        }
    }

    struct MCPRuntimePlanSummary: Equatable, Sendable {
        let serverNames: [String]
        let externalServerNames: [String]
        let externalAllowedTools: [String]
        let externalPolicy: String
        let executionAllowedTools: [String]
    }

    static func runtimePlanSummaryForTesting(_ request: SortAssistantMCPRequest) -> MCPRuntimePlanSummary {
        let runtimePlan = mcpRuntimePlan(for: request)
        return MCPRuntimePlanSummary(
            serverNames: runtimePlan.serverNames,
            externalServerNames: runtimePlan.externalServerNames,
            externalAllowedTools: runtimePlan.externalAllowedTools,
            externalPolicy: runtimePlan.externalPolicy,
            executionAllowedTools: executionAllowedTools(for: request, runtimePlan: runtimePlan)
        )
    }

    private enum MCPExposureMode: String {
        case routerOnly = "router_only"
        case expanded
    }

    private struct MCPConfigFile {
        let url: URL
        let semanticRouterPayloadURL: URL?
        let exposureMode: MCPExposureMode
        let serverNames: [String]
        let externalServerNames: [String]
        let externalAllowedTools: [String]
        let allowedTools: [String]
        let byteCount: Int
        let semanticRouterPayloadByteCount: Int
        let externalPolicy: String
    }

    func run(
        _ request: SortAssistantMCPRequest,
        progressHandler: SortAssistantMCPProgressHandler? = nil
    ) async throws -> SortAssistantMCPRunResult {
        try await Task.detached(priority: .userInitiated) {
            try Self.perform(request, progressHandler: progressHandler)
        }.value
    }

    func summarizeProactiveNotifications(
        _ request: SortAssistantProactiveNotificationDigestRequest
    ) async throws -> SortAssistantProactiveNotificationDigestResult {
        try await Task.detached(priority: .utility) {
            try Self.performProactiveNotificationDigest(request)
        }.value
    }

    private static func performProactiveNotificationDigest(
        _ request: SortAssistantProactiveNotificationDigestRequest
    ) throws -> SortAssistantProactiveNotificationDigestResult {
        let executable = claudeCodeExecutable()
        if executable.contains("/") && !FileManager.default.isExecutableFile(atPath: executable) {
            throw NSError(domain: "SortAssistantMCPClient", code: 1)
        }

        let arguments = try proactiveNotificationDigestClaudeArguments(request)
        request.debugSession?.log(
            "notificationDigest.claude.begin items=\(request.items.count) sessionReused=\(request.claudeSessionReused ? 1 : 0) \(SortAssistantClaudeCodeRuntime.debugSummary(sessionId: request.claudeSessionId, resumeSession: request.claudeSessionReused))"
        )
        let output = try runClaudeCodeRetryingSessionInUse(
            executable: executable,
            arguments: arguments,
            timeoutSeconds: proactiveNotificationDigestTimeoutSeconds,
            debugSession: request.debugSession,
            progressHandler: nil
        )
        request.debugSession?.log(
            "notificationDigest.claude.end status=\(output.status) stdoutBytes=\(output.stdout.utf8.count) stderrBytes=\(output.stderr.utf8.count)"
        )
        guard output.status == 0 else {
            throw SortAssistantMCPClientProcessError(
                status: output.status,
                stdout: output.stdout,
                stderr: output.stderr
            )
        }
        let content = SortAssistantClaudeOutputParser.resultText(from: output.stdout) ?? output.stdout
        guard let digest = proactiveNotificationDigestResult(from: content, items: request.items) else {
            throw SortAssistantMCPRunResultParseError(raw: content)
        }
        return digest
    }

    private static func proactiveNotificationDigestClaudeArguments(
        _ request: SortAssistantProactiveNotificationDigestRequest
    ) throws -> [String] {
        [
            "-p", proactiveNotificationDigestUserPrompt(request),
            "--output-format", SortAssistantClaudeCodeRuntime.outputFormat,
            "--model", "haiku",
        ] +
            SortAssistantClaudeCodeRuntime.outputFormatArguments +
            (try SortAssistantClaudeCodeRuntime.isolatedArguments(
                systemPrompt: proactiveNotificationDigestSystemPrompt,
                sessionId: request.claudeSessionId,
                resumeSession: request.claudeSessionReused
            ))
    }

    private static let proactiveNotificationDigestSystemPrompt = """
        You are cmux sprite's notification summarizer. Merge a burst of workspace notifications into one concise semantic sentence for the user, and choose the single most important notification to keep visible.
        Return only JSON: {"sentence":"...","folded_ids":["..."]}.
        Requirements:
        - exactly one sentence
        - no Markdown, no bullets, no emoji
        - preserve the important action and workspace names
        - folded_ids must contain every notification id except the single most important one
        - never fold the most important notification
        - keep it under 180 characters when possible
        - do not invent facts
        """

    private static func proactiveNotificationDigestUserPrompt(
        _ request: SortAssistantProactiveNotificationDigestRequest
    ) -> String {
        let payload: [String: Any] = [
            "notifications": request.items.map { item in
                [
                    "id": item.id.uuidString,
                    "workspaceId": item.workspaceId.uuidString,
                    "workspaceTitle": item.workspaceTitle,
                    "type": item.type,
                    "title": item.title,
                    "reason": item.reason ?? "",
                    "confidence": item.confidence,
                ] as [String: Any]
            },
            "recentConversation": request.conversationContext,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
            ?? Data("{}".utf8)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        return "Merge these cmux sprite notifications into one user-facing sentence:\n\(json)"
    }

    private static func proactiveNotificationDigestResult(
        from content: String,
        items: [SortAssistantProactiveNotificationDigestItem]
    ) -> SortAssistantProactiveNotificationDigestResult? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let object = proactiveNotificationDigestJSONObject(from: trimmed),
           let sentence = object["sentence"] as? String,
           let normalized = normalizedDigestSentence(sentence) {
            return SortAssistantProactiveNotificationDigestResult(
                sentence: normalized,
                foldedSuggestionIds: singleVisibleFoldedSuggestionIds(
                    requestedFoldedIds: foldedSuggestionIds(from: object, validItems: items),
                    validItems: items
                )
            )
        }
        guard let sentence = normalizedDigestSentence(trimmed) else { return nil }
        return SortAssistantProactiveNotificationDigestResult(
            sentence: sentence,
            foldedSuggestionIds: singleVisibleFoldedSuggestionIds(requestedFoldedIds: [], validItems: items)
        )
    }

    #if DEBUG
    static func proactiveNotificationDigestResultForTesting(
        from content: String,
        items: [SortAssistantProactiveNotificationDigestItem]
    ) -> SortAssistantProactiveNotificationDigestResult? {
        proactiveNotificationDigestResult(from: content, items: items)
    }
    #endif

    private static func proactiveNotificationDigestJSONObject(from text: String) -> [String: Any]? {
        if let object = jsonObject(from: text) {
            return object
        }
        for candidate in proactiveNotificationDigestJSONCandidates(from: text) {
            if let object = jsonObject(from: candidate) {
                return object
            }
        }
        return nil
    }

    private static func proactiveNotificationDigestJSONCandidates(from text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates: [String] = []

        if trimmed.hasPrefix("```"),
           let firstNewline = trimmed.firstIndex(where: \.isNewline) {
            var body = trimmed[trimmed.index(after: firstNewline)...]
            if let closingFence = body.range(of: "```", options: .backwards) {
                body = body[..<closingFence.lowerBound]
            }
            candidates.append(String(body).trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let lowercased = trimmed.lowercased()
        if lowercased.hasPrefix("json") {
            let remainder = trimmed.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines)
            candidates.append(remainder)
        }

        if let embeddedObject = firstJSONObjectSubstring(in: trimmed) {
            candidates.append(embeddedObject)
        }

        return candidates
    }

    private static func firstJSONObjectSubstring(in text: String) -> String? {
        var start: String.Index?
        var depth = 0
        var isInsideString = false
        var isEscaped = false

        for index in text.indices {
            let character = text[index]
            guard let objectStart = start else {
                if character == "{" {
                    start = index
                    depth = 1
                }
                continue
            }

            if isInsideString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isInsideString = false
                }
                continue
            }

            if character == "\"" {
                isInsideString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(text[objectStart...index])
                }
            }
        }
        return nil
    }

    private static func foldedSuggestionIds(
        from object: [String: Any],
        validItems: [SortAssistantProactiveNotificationDigestItem]
    ) -> Set<UUID> {
        let validIds = Set(validItems.map(\.id))
        let rawList = object["folded_ids"] ?? object["foldedIds"] ?? object["collapsed_ids"] ?? object["collapsedIds"]
        let rawStrings: [String]
        if let strings = rawList as? [String] {
            rawStrings = strings
        } else if let values = rawList as? [Any] {
            rawStrings = values.compactMap { $0 as? String }
        } else {
            rawStrings = []
        }
        return Set(rawStrings.compactMap(UUID.init(uuidString:)).filter { validIds.contains($0) })
    }

    private static func singleVisibleFoldedSuggestionIds(
        requestedFoldedIds: Set<UUID>,
        validItems: [SortAssistantProactiveNotificationDigestItem]
    ) -> Set<UUID> {
        guard let primaryId = validItems.first?.id else { return [] }
        let nonPrimaryIds = Set(validItems.dropFirst().map(\.id))
        return requestedFoldedIds.union(nonPrimaryIds).subtracting([primaryId])
    }

    private static func normalizedDigestSentence(_ text: String) -> String? {
        let normalized = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"`")))
        guard !normalized.isEmpty else { return nil }
        if normalized.count <= 240 {
            return normalized
        }
        let end = normalized.index(normalized.startIndex, offsetBy: 240)
        return String(normalized[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func jsonObject(from text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func perform(
        _ request: SortAssistantMCPRequest,
        progressHandler: SortAssistantMCPProgressHandler?
    ) throws -> SortAssistantMCPRunResult {
        let executable = claudeCodeExecutable()
        if executable.contains("/") && !FileManager.default.isExecutableFile(atPath: executable) {
            throw NSError(domain: "SortAssistantMCPClient", code: 1)
        }

        let routedPromptBundle = promptBundle(for: request)
        let runtimePlan = mcpRuntimePlan(for: request)
        let semanticRouterPayload = semanticRouterPayloadObject(
            request: request,
            promptBundle: routedPromptBundle,
            runtimePlan: runtimePlan
        )

        let executionResumeSession: Bool
        if request.requiresMCPScopeRefresh {
            try refreshSemanticRouterScope(
                request: request,
                runtimePlan: runtimePlan,
                semanticRouterPayload: semanticRouterPayload,
                executable: executable,
                progressHandler: progressHandler
            )
            executionResumeSession = request.claudeSessionId != nil
        } else {
            executionResumeSession = request.claudeSessionReused
            request.debugSession?.log(
                "mcp.scope.reuse signatureHash=\(request.visibleScopeSignature.hashValue) reason=\(request.scopeRefreshReason)"
            )
        }

        let configStart = SortAssistantDebugSession.now()
        let mcpConfig = try writeMCPConfig(
            request,
            runtimePlan: runtimePlan,
            semanticRouterPayload: semanticRouterPayload,
            exposureMode: .expanded
        )
        request.debugSession?.log(
            "mcp.config.end exposure=\(mcpConfig.exposureMode.rawValue) servers=\(mcpConfig.serverNames.count) externalServers=\(mcpConfig.externalServerNames.count) serverNames=\(mcpConfig.serverNames.joined(separator: ",")) externalPolicy=\(mcpConfig.externalPolicy) bytes=\(mcpConfig.byteCount) semanticRouterPayloadBytes=\(mcpConfig.semanticRouterPayloadByteCount)",
            phaseStartNanos: configStart
        )
        defer {
            try? FileManager.default.removeItem(at: mcpConfig.url)
            if let semanticRouterPayloadURL = mcpConfig.semanticRouterPayloadURL {
                try? FileManager.default.removeItem(at: semanticRouterPayloadURL)
            }
        }

        let promptBundle = semanticRouterBootstrapPromptBundle(for: request)
        let arguments = try claudeArguments(
            request: request,
            mcpConfig: mcpConfig,
            promptBundle: promptBundle,
            resumeSession: executionResumeSession
        )
        request.debugSession?.log(
            "mcp.claude.begin exposure=\(mcpConfig.exposureMode.rawValue) allowedTools=\(mcpConfig.allowedTools.count) externalAllowedTools=\(mcpConfig.externalAllowedTools.count) allowedToolNames=\(mcpConfig.allowedTools.joined(separator: ",")) externalServers=\(mcpConfig.externalServerNames.joined(separator: ",")) mode=\(request.route.mode.rawValue) promptProfile=\(promptBundle.profile.rawValue) routedPromptProfile=\(routedPromptBundle.profile.rawValue) promptFragments=\(routedPromptBundle.fragmentNames.joined(separator: ",")) routeSteps=\(request.routeSteps.debugDescriptionJoined) adjustment=\(request.routeAdjustment.debugDescription) scopeRefresh=\(request.requiresMCPScopeRefresh ? 1 : 0) scopeReason=\(request.scopeRefreshReason) systemPromptChars=\(promptBundle.systemPrompt.count) userPromptChars=\(promptBundle.userPrompt.count) routedSystemPromptChars=\(routedPromptBundle.systemPrompt.count) routedUserPromptChars=\(routedPromptBundle.userPrompt.count) includeContext=\(request.includeConversationContext ? 1 : 0) sessionReused=\(executionResumeSession ? 1 : 0) sessionReason=\(request.claudeSessionReason) \(SortAssistantClaudeCodeRuntime.debugSummary(sessionId: request.claudeSessionId, resumeSession: executionResumeSession))"
        )
        let claudeStart = SortAssistantDebugSession.now()
        let output = try runClaudeCodeRetryingSessionInUse(
            executable: executable,
            arguments: arguments,
            timeoutSeconds: runTimeoutSeconds,
            debugSession: request.debugSession,
            progressHandler: progressHandler
        )
        request.debugSession?.log(
            "mcp.claude.end status=\(output.status) stdoutBytes=\(output.stdout.utf8.count) stderrBytes=\(output.stderr.utf8.count)",
            phaseStartNanos: claudeStart
        )
        guard output.status == 0 else {
            request.debugSession?.log(
                "mcp.claude.failed status=\(output.status) stdoutBytes=\(output.stdout.utf8.count) stderrBytes=\(output.stderr.utf8.count)"
            )
            throw SortAssistantMCPClientProcessError(
                status: output.status,
                stdout: output.stdout,
                stderr: output.stderr
            )
        }
        let content = SortAssistantClaudeOutputParser.resultText(from: output.stdout) ?? output.stdout
        let parseStart = SortAssistantDebugSession.now()
        let parsed = try SortAssistantMCPRunResult.parse(content)
        request.debugSession?.log(
            "mcp.parse.end hasCard=\(parsed.card != nil) hasChoice=\(parsed.choicePrompt != nil) messageChars=\(parsed.message.count)",
            phaseStartNanos: parseStart
        )
        return parsed
    }

    private static func refreshSemanticRouterScope(
        request: SortAssistantMCPRequest,
        runtimePlan: MCPRuntimePlan,
        semanticRouterPayload: [String: Any],
        executable: String,
        progressHandler: SortAssistantMCPProgressHandler?
    ) throws {
        let configStart = SortAssistantDebugSession.now()
        let mcpConfig = try writeMCPConfig(
            request,
            runtimePlan: runtimePlan,
            semanticRouterPayload: semanticRouterPayload,
            exposureMode: .routerOnly
        )
        request.debugSession?.log(
            "mcp.scope.config.end exposure=\(mcpConfig.exposureMode.rawValue) servers=\(mcpConfig.serverNames.count) serverNames=\(mcpConfig.serverNames.joined(separator: ",")) allowedTools=\(mcpConfig.allowedTools.joined(separator: ",")) bytes=\(mcpConfig.byteCount) semanticRouterPayloadBytes=\(mcpConfig.semanticRouterPayloadByteCount) signatureHash=\(request.visibleScopeSignature.hashValue) reason=\(request.scopeRefreshReason)",
            phaseStartNanos: configStart
        )
        defer {
            try? FileManager.default.removeItem(at: mcpConfig.url)
            if let semanticRouterPayloadURL = mcpConfig.semanticRouterPayloadURL {
                try? FileManager.default.removeItem(at: semanticRouterPayloadURL)
            }
        }

        let promptBundle = semanticRouterScopeRefreshPromptBundle(for: request)
        let arguments = try claudeArguments(
            request: request,
            mcpConfig: mcpConfig,
            promptBundle: promptBundle,
            resumeSession: request.claudeSessionReused
        )
        request.debugSession?.log(
            "mcp.scope.claude.begin allowedTools=\(mcpConfig.allowedTools.count) allowedToolNames=\(mcpConfig.allowedTools.joined(separator: ",")) sessionReused=\(request.claudeSessionReused ? 1 : 0) \(SortAssistantClaudeCodeRuntime.debugSummary(sessionId: request.claudeSessionId, resumeSession: request.claudeSessionReused))"
        )
        let scopeStart = SortAssistantDebugSession.now()
        let output = try runClaudeCodeRetryingSessionInUse(
            executable: executable,
            arguments: arguments,
            timeoutSeconds: runTimeoutSeconds,
            debugSession: request.debugSession,
            progressHandler: progressHandler
        )
        request.debugSession?.log(
            "mcp.scope.claude.end status=\(output.status) stdoutBytes=\(output.stdout.utf8.count) stderrBytes=\(output.stderr.utf8.count)",
            phaseStartNanos: scopeStart
        )
        guard output.status == 0 else {
            request.debugSession?.log(
                "mcp.scope.claude.failed status=\(output.status) stdoutBytes=\(output.stdout.utf8.count) stderrBytes=\(output.stderr.utf8.count)"
            )
            throw SortAssistantMCPClientProcessError(
                status: output.status,
                stdout: output.stdout,
                stderr: output.stderr
            )
        }
    }

    private static func claudeArguments(
        request: SortAssistantMCPRequest,
        mcpConfig: MCPConfigFile,
        promptBundle: PromptBundle,
        resumeSession: Bool
    ) throws -> [String] {
        return [
            "-p", promptBundle.userPrompt,
            "--output-format", SortAssistantClaudeCodeRuntime.outputFormat,
            "--mcp-config", mcpConfig.url.path,
            "--strict-mcp-config",
            "--allowed-tools", mcpConfig.allowedTools.joined(separator: ","),
            "--model", "haiku",
        ] +
            SortAssistantClaudeCodeRuntime.outputFormatArguments +
            (try SortAssistantClaudeCodeRuntime.isolatedArguments(
                systemPrompt: promptBundle.systemPrompt,
                sessionId: request.claudeSessionId,
                resumeSession: resumeSession
            ))
    }

    private static func promptBundle(for request: SortAssistantMCPRequest) -> PromptBundle {
        let steps = normalizedRouteSteps(for: request)
        let fragmentNames = request.routeAdjustment.applyingPromptFragments(
            to: promptFragmentNames(for: steps)
        )
        return PromptBundle(
            profile: promptProfile(for: steps, fragmentNames: fragmentNames),
            systemPrompt: routedSystemPrompt(fragmentNames: fragmentNames),
            userPrompt: userPrompt(request),
            fragmentNames: fragmentNames
        )
    }

    private static func semanticRouterBootstrapPromptBundle(for request: SortAssistantMCPRequest) -> PromptBundle {
        PromptBundle(
            profile: .semanticRouterBootstrap,
            systemPrompt: semanticRouterBootstrapSystemPrompt,
            userPrompt: semanticRouterBootstrapUserPrompt(request),
            fragmentNames: ["semantic_router"]
        )
    }

    private static func semanticRouterScopeRefreshPromptBundle(for request: SortAssistantMCPRequest) -> PromptBundle {
        PromptBundle(
            profile: .semanticRouterBootstrap,
            systemPrompt: semanticRouterScopeRefreshSystemPrompt,
            userPrompt: semanticRouterScopeRefreshUserPrompt(request),
            fragmentNames: ["semantic_router"]
        )
    }

    static func promptFragmentNamesForTesting(
        steps: [SortAssistantRouteStep],
        adjustment: SortAssistantRouteAdjustment = .empty
    ) -> [String] {
        adjustment.applyingPromptFragments(to: promptFragmentNames(for: steps))
    }

    static func promptFragmentTextForTesting(named name: String) -> String? {
        promptFragment(named: name)
    }

    private static func promptProfile(
        for steps: [SortAssistantRouteStep],
        fragmentNames: [String]
    ) -> SortAssistantClaudePromptProfile {
        if steps.count > 1 || fragmentNames.count > 1 {
            return .routedFragments
        }
        switch fragmentNames.first {
        case "normal_chat", "context":
            return .conversation
        case "workspace_color":
            return .workspaceColorCompact
        default:
            return .routedFragments
        }
    }

    private static func normalizedRouteSteps(for request: SortAssistantMCPRequest) -> [SortAssistantRouteStep] {
        SortAssistantRouteStep.normalizing(
            request.routeSteps,
            fallback: SortAssistantRouteStep(intent: request.intent)
        )
    }

    private static func promptFragmentNames(for steps: [SortAssistantRouteStep]) -> [String] {
        orderedUniqueSortAssistant(steps.flatMap { step -> [String] in
            switch step.intent {
            case .normalChat:
                return ["normal_chat"]
            case .askContext:
                return ["context"]
            case .workspaceColor:
                return ["workspace_color"]
            case .proposeSort, .applySort:
                return step.sortRoute == .colorGroup ? ["sort", "sort_color_group"] : ["sort"]
            case .explainCurrentOrder:
                return ["explain_order"]
            case .manualReorderFeedback, .rememberPreference, .forgetPreference:
                return ["sort_memory"]
            case .rememberSpriteMemory, .forgetSpriteMemory:
                return ["sprite_memory"]
            case .undoSort:
                return ["undo"]
            case .clearSession:
                return ["clear_session"]
            }
        })
    }

    private static func routedSystemPrompt(fragmentNames: [String]) -> String {
        let fragments = fragmentNames.compactMap(promptFragment(named:))
        return ([routedBaseSystemPrompt] + fragments).joined(separator: "\n\n")
    }

    private static var routedBaseSystemPrompt: String {
        """
        You are cmux sprite's workspace assistant. Execute only the current request's taskPlan using the provided MCP tools.
        If the request includes routeAdjustment, its prompt/tool modes describe how this turn changed the active route. Treat replacement or removal as intentional narrowing; do not use stale capabilities or stale prompt guidance that were removed.

        Return only one strict JSON object:
        {
          "message": "short user-facing sentence",
          "choicePrompt": null | {
            "title": "short question title",
            "message": "optional context sentence",
            "questions": [
              {
                "id": "stable_question_id",
                "title": "short question title",
                "message": "optional context sentence",
                "options": [
                  {
                    "id": "stable_snake_case_id",
                    "title": "short option title",
                    "subtitle": "one-line option description",
                    "goal": "complete follow-up instruction fragment for this choice"
                  }
                ]
              }
            ],
            "options": [
              {
                "id": "stable_snake_case_id",
                "title": "short option title",
                "subtitle": "one-line option description",
                "goal": "complete follow-up instruction fragment"
              }
            ]
          },
          "card": null | {
            "title": "short title",
            "mode": "preview|applied",
            "dimensionLabel": "optional label",
            "changes": ["short visible change"],
            "rationale": "short markdown body",
            "patchId": "optional UUID",
            "actions": ["apply","partial_apply","ignore","explain","undo","remember"]
          }
        }

        Execute taskPlan.steps in order. If one step changes workspace order or color, use fresh tool output for later steps. Report mutations only after the corresponding tool result confirms them. If a step needs user choices, return one choicePrompt covering all missing details. The taskPlan is scoped to this request; later requests may choose different routes in the same session.
        """
    }

    private static var semanticRouterBootstrapSystemPrompt: String {
        """
        You are cmux sprite. Use the semantic router MCP result already present in this session when it is fresh for the current request; otherwise prefer calling mcp__cmux_semantic_router__search before doing substantive work so you can use its route bundle for this turn.

        The route bundle contains systemPrompt, userPrompt, taskPlan, mcpList, and executionAllowedTools. Use systemPrompt and userPrompt as the detailed instructions, stay within executionAllowedTools for execution work, and return the strict JSON response shape described by the route bundle.
        """
    }

    private static var semanticRouterScopeRefreshSystemPrompt: String {
        """
        You are cmux sprite's MCP scope refresher. Only the local semantic router MCP is visible in this phase.

        Call mcp__cmux_semantic_router__search to retrieve the route bundle for the current request. Do not execute the user's task in this phase. Return only this JSON after the search result is available:
        {"message":"scope refreshed","choicePrompt":null,"card":null}
        """
    }

    private static func semanticRouterBootstrapUserPrompt(_ request: SortAssistantMCPRequest) -> String {
        var payload: [String: Any] = [
            "goal": request.goal,
            "workspaceId": request.workspaceId.map { $0 as Any } ?? NSNull(),
            "workspaceDirectory": request.workspaceDirectory.map { $0 as Any } ?? NSNull(),
            "explicitSlashCommand": request.explicitSlashCommand,
            "routerTool": semanticRouterQualifiedToolName,
            "searchTool": semanticRouterQualifiedSearchToolName,
            "scopeRefreshAlreadyPerformed": request.requiresMCPScopeRefresh,
            "visibleScopeSignature": request.visibleScopeSignature,
        ]
        if request.includeConversationContext {
            payload["recentConversationItemCount"] = request.conversationContext.count
        }
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        let json = String(data: data, encoding: .utf8) ?? "{}"
        return "Handle this cmux sprite request. Reuse the fresh semantic router search result in this session when available; otherwise search the router before execution:\n\(json)"
    }

    private static func semanticRouterScopeRefreshUserPrompt(_ request: SortAssistantMCPRequest) -> String {
        var payload: [String: Any] = [
            "goal": request.goal,
            "workspaceId": request.workspaceId.map { $0 as Any } ?? NSNull(),
            "workspaceDirectory": request.workspaceDirectory.map { $0 as Any } ?? NSNull(),
            "explicitSlashCommand": request.explicitSlashCommand,
            "searchTool": semanticRouterQualifiedSearchToolName,
            "visibleScopeSignature": request.visibleScopeSignature,
            "scopeRefreshReason": request.scopeRefreshReason,
        ]
        if request.includeConversationContext {
            payload["recentConversationItemCount"] = request.conversationContext.count
        }
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        let json = String(data: data, encoding: .utf8) ?? "{}"
        return "Refresh the visible MCP scope through the local semantic router search tool:\n\(json)"
    }

    private static func promptFragment(named name: String) -> String? {
        switch name {
        case "normal_chat":
            return """
            normal_chat: Answer naturally and briefly. Use recentConversation when it helps. If the user asks about an external system such as Jira issues/tickets or Confluence pages and a matching external MCP tool is present in your allowed tools (their names start with mcp__, e.g. mcp__mcp-atlassian__* for Jira/Confluence), call that tool to answer instead of guessing; if no such tool is available, say so.
            """
        case "context":
            return """
            context: Read assistant_working_context_get first. Use workspace_snapshot_get or workspace_digest_get for specific workspaces, context_freshness_get to report stale or missing providers, suggestions_active_get to inspect current proactive suggestions, and list_state only when the user asks about visible sidebar order. Use context_agent_collect or proactive_suggestions_refresh only when the user explicitly asks to refresh/collect cmux context or required data is missing/stale enough that cached context cannot answer. Use proactive_signal_report only when the user explicitly asks to report a proactive workspace signal. Use suggestion_accept or suggestion_dismiss only when the latest user request explicitly asks to accept/open or dismiss a specific suggestion. When the request is about an external system such as Jira issues/tickets or Confluence pages and a matching external MCP tool is present in your allowed tools (their names start with mcp__, e.g. mcp__mcp-atlassian__* for Jira/Confluence), call that tool to answer rather than guessing. If required data remains stale or missing, say which provider is stale or missing and answer with that limitation.
            """
        case "workspace_color":
            return """
            workspace_color: Use workspace_color_get for reads, workspace_color_set for set/change requests, and workspace_color_clear for clear/reset/remove requests. Use the active workspace unless the user names another workspace. For multiple workspaces, visible/current workspace lists, or category/group color assignments, call list_state, match item ids/titles, then call the color tool for each confirmed match. Return one choicePrompt for ambiguous group/category matches.
            """
        case "sort":
            return """
            sort: For propose_sort, call memory_query plus assistant_working_context_get/ranking_latest_get/list_state as needed, then sort_preview. For apply_sort, read the same snapshot-backed context, call sort_preview, then sort_apply. Use choicePrompt only when missing details prevent computing a concrete order.
            """
        case "sort_color_group":
            return """
            sort_color_group: Call list_state immediately before computing the order and use each item's custom_color/customColor. sort_preview and sort_apply must receive explicit itemIds from the latest list_state. If the user named a color order, place named colors first and preserve relative order for unspecified colors.
            """
        case "explain_order":
            return "explain_order: Use assistant_working_context_get, ranking_latest_get, sort_explain, or list_state, then return a concise explanation of the current order."
        case "sort_memory":
            return """
            sort_memory: Keep free-sort/sidebar sorting preferences in memory_query, memory_write_candidate, and memory_forget. Compare new preference candidates with existing memories before writing a candidate.
            """
        case "sprite_memory":
            return "sprite_memory: Use sprite_memory_query, sprite_memory_write, and sprite_memory_forget for project/session facts from workspace memory.md."
        case "undo":
            return "undo: Call sort_undo and report the tool result."
        default:
            return nil
        }
    }

    private static func userPrompt(_ request: SortAssistantMCPRequest) -> String {
        let steps = normalizedRouteSteps(for: request)
        var payload: [String: Any] = [
            "initialPrompt": routeInitialPrompt(for: request),
            "goal": request.goal,
            "intent": request.intent.rawValue,
            "taskPlan": [
                "scope": "current_request",
                "steps": routeStepPayload(steps),
            ],
            "workspaceId": request.workspaceId.map { $0 as Any } ?? NSNull(),
            "workspaceDirectory": request.workspaceDirectory.map { $0 as Any } ?? NSNull(),
            "explicitSlashCommand": request.explicitSlashCommand,
            "route": [
                "mode": request.route.mode.rawValue,
                "needsConfirmation": request.route.needsConfirmation,
                "allowedTools": request.route.allowedTools,
                "memoryWritePolicy": request.route.memoryWritePolicy.rawValue,
            ],
        ]
        if request.includeConversationContext {
            payload["recentConversation"] = request.conversationContext
        }
        if !request.routeAdjustment.isEmpty {
            payload["routeAdjustment"] = [
                "promptFragmentMode": request.routeAdjustment.promptFragmentMode.rawValue,
                "promptFragments": request.routeAdjustment.promptFragments,
                "removedPromptFragments": request.routeAdjustment.removedPromptFragments,
                "allowedToolsMode": request.routeAdjustment.allowedToolsMode.rawValue,
                "allowedTools": request.routeAdjustment.allowedTools,
                "removedAllowedTools": request.routeAdjustment.removedAllowedTools,
            ]
        }
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        let json = String(data: data, encoding: .utf8) ?? "{}"
        return "Handle this sprite assistant request through MCP tools:\n\(json)"
    }

    private static func routeStepPayload(_ steps: [SortAssistantRouteStep]) -> [[String: Any]] {
        steps.map { step in
            var object: [String: Any] = [
                "intent": step.intent.rawValue,
            ]
            if let sortRoute = step.sortRoute {
                object["sortRoute"] = sortRoute.rawValue
            } else {
                object["sortRoute"] = NSNull()
            }
            return object
        }
    }

    private static func routeInitialPrompt(for request: SortAssistantMCPRequest) -> String {
        let steps = normalizedRouteSteps(for: request)
        if steps.count > 1 {
            let description = steps.map(\.debugDescription).joined(separator: " -> ")
            return "Semantic router selected ordered tasks: \(description). Complete them in order."
        }
        switch request.intent {
        case .normalChat:
            return "Semantic router selected normal_chat. Answer conversationally and briefly."
        case .askContext:
            return "Semantic router selected ask_context. Read the latest snapshot context and answer concretely, noting stale or missing freshness when relevant."
        case .workspaceColor:
            return "Semantic router selected workspace_color. Read, set, change, clear, reset, or remove workspace/sidebar/tab colors as requested."
        case .proposeSort:
            return "Semantic router selected propose_sort. Produce a sort preview or recommendation."
        case .applySort:
            return "Semantic router selected apply_sort. The user asked to apply a workspace/sidebar order change."
        case .explainCurrentOrder:
            return "Semantic router selected explain_current_order. Explain the current order."
        case .manualReorderFeedback:
            return "Semantic router selected manual_reorder_feedback. Treat this as feedback about a user-made reorder."
        case .rememberPreference:
            return "Semantic router selected remember_preference. Save or prepare a free-sort/sidebar sorting preference."
        case .forgetPreference:
            return "Semantic router selected forget_preference. Forget a saved free-sort/sidebar sorting preference."
        case .rememberSpriteMemory:
            return "Semantic router selected remember_sprite_memory. Save a project/session fact to sprite workspace memory, not a sorting preference."
        case .forgetSpriteMemory:
            return "Semantic router selected forget_sprite_memory. Forget a project/session fact from sprite workspace memory."
        case .undoSort:
            return "Semantic router selected undo_sort. Undo the assistant's previous sort."
        case .clearSession:
            return "Semantic router selected clear_session, but clear_session should be handled before MCP."
        }
    }

    private static func semanticRouterPayloadObject(
        request: SortAssistantMCPRequest,
        promptBundle: PromptBundle,
        runtimePlan: MCPRuntimePlan
    ) -> [String: Any] {
        let steps = normalizedRouteSteps(for: request)
        let executionAllowedTools = executionAllowedTools(for: request, runtimePlan: runtimePlan)
        let claudeAllowedTools = claudeAllowedTools(for: request, runtimePlan: runtimePlan)
        var payload: [String: Any] = [
            "version": 1,
            "surface": "cmux_sprite_assistant",
            "goal": request.goal,
            "systemPrompt": promptBundle.systemPrompt,
            "userPrompt": promptBundle.userPrompt,
            "promptProfile": promptBundle.profile.rawValue,
            "promptFragments": promptBundle.fragmentNames,
            "intent": request.intent.rawValue,
            "taskPlan": [
                "scope": "current_request",
                "steps": routeStepPayload(steps),
            ],
            "workspaceId": request.workspaceId.map { $0 as Any } ?? NSNull(),
            "workspaceDirectory": request.workspaceDirectory.map { $0 as Any } ?? NSNull(),
            "explicitSlashCommand": request.explicitSlashCommand,
            "route": [
                "mode": request.route.mode.rawValue,
                "needsConfirmation": request.route.needsConfirmation,
                "allowedTools": request.route.allowedTools,
                "memoryWritePolicy": request.route.memoryWritePolicy.rawValue,
            ],
            "mcpList": mcpListPayload(
                request: request,
                runtimePlan: runtimePlan,
                executionAllowedTools: executionAllowedTools
            ),
            "mcpServers": runtimePlan.serverNames,
            "externalMCPServers": runtimePlan.externalServerNames,
            "executionAllowedTools": executionAllowedTools,
            "claudeAllowedTools": claudeAllowedTools,
            "visibleScope": [
                "signature": request.visibleScopeSignature,
                "refreshRequired": request.requiresMCPScopeRefresh,
                "refreshReason": request.scopeRefreshReason,
                "initialVisibleMCPServers": [semanticRouterServerName],
                "initialVisibleTools": semanticRouterQualifiedToolNames,
                "expandedMCPServers": runtimePlan.serverNames,
                "expandedAllowedTools": claudeAllowedTools,
            ],
            "toolUsePolicy": [
                "routerTool": semanticRouterQualifiedToolName,
                "searchTool": semanticRouterQualifiedSearchToolName,
                "preferRouterFirst": true,
                "routerIsGuidance": true,
                "executionAllowedToolsAreRecommended": true,
                "initialVisibilityIsRouterOnly": true,
            ],
        ]
        if request.includeConversationContext {
            payload["recentConversation"] = request.conversationContext
        }
        if !request.routeAdjustment.isEmpty {
            payload["routeAdjustment"] = [
                "promptFragmentMode": request.routeAdjustment.promptFragmentMode.rawValue,
                "promptFragments": request.routeAdjustment.promptFragments,
                "removedPromptFragments": request.routeAdjustment.removedPromptFragments,
                "allowedToolsMode": request.routeAdjustment.allowedToolsMode.rawValue,
                "allowedTools": request.routeAdjustment.allowedTools,
                "removedAllowedTools": request.routeAdjustment.removedAllowedTools,
            ]
        }
        return payload
    }

    private static func mcpListPayload(
        request: SortAssistantMCPRequest,
        runtimePlan: MCPRuntimePlan,
        executionAllowedTools: [String]
    ) -> [[String: Any]] {
        var entries: [[String: Any]] = [
            [
                "name": semanticRouterServerName,
                "role": "semantic_router",
                "tools": [semanticRouterToolName, semanticRouterSearchToolName],
                "qualifiedTools": semanticRouterQualifiedToolNames,
            ],
        ]

        if !request.route.allowedTools.isEmpty {
            entries.append([
                "name": "cmux_sprite",
                "role": "sprite_execution",
                "tools": request.route.allowedTools,
                "qualifiedTools": request.route.allowedTools.map { "mcp__cmux_sprite__\($0)" },
            ])
        }

        for serverName in runtimePlan.externalServerNames {
            let prefix = "mcp__\(serverName)__"
            let allowedTools = executionAllowedTools.filter { $0.hasPrefix(prefix) }
            entries.append([
                "name": serverName,
                "role": "external",
                "qualifiedTools": allowedTools,
            ])
        }
        return entries
    }

    private static func mcpRuntimePlan(for request: SortAssistantMCPRequest) -> MCPRuntimePlan {
        var env: [String: String] = [
            "CMUX_SOCKET_PATH": request.socketPath,
        ]
#if DEBUG
        env["CMUX_SPRITE_MCP_DEBUG"] = "1"
        if let debugLogPath = debugLogPathForMCP() {
            env["CMUX_DEBUG_LOG"] = debugLogPath
        }
#endif
        if let workspaceId = request.workspaceId, !workspaceId.isEmpty {
            env["CMUX_WORKSPACE_ID"] = workspaceId
        }
        if let workspaceDirectory = request.workspaceDirectory, !workspaceDirectory.isEmpty {
            env["CMUX_WORKSPACE_DIRECTORY"] = workspaceDirectory
        }

        let includeExternal = shouldLoadExternalMCP(for: request)
        let externalServers = includeExternal
            ? SpriteAssistantConfig.externalMCPServers(workspaceDirectory: request.workspaceDirectory)
            : [:]
        let externalServerNames = externalServers.keys.sorted()
        let externalAllowedTools = includeExternal
            ? SpriteAssistantConfig.externalMCPAllowedTools(
                workspaceDirectory: request.workspaceDirectory,
                serverNames: externalServerNames
            )
            : []

        var mcpServers = externalServers
        if !request.route.allowedTools.isEmpty {
            env["CMUX_SPRITE_ALLOWED_TOOLS"] = request.route.allowedTools.joined(separator: ",")
            mcpServers["cmux_sprite"] = [
                "command": request.cmuxCLIPath,
                "args": [
                    "--socket",
                    request.socketPath,
                    "mcp",
                    "sprite-assistant",
                ],
                "env": env,
            ]
        }

        return MCPRuntimePlan(
            mcpServers: mcpServers,
            externalServerNames: externalServerNames,
            externalAllowedTools: externalAllowedTools,
            externalPolicy: includeExternal ? "loaded_for_intent" : "sprite_only_for_intent"
        )
    }

    private static func writeMCPConfig(
        _ request: SortAssistantMCPRequest,
        runtimePlan: MCPRuntimePlan,
        semanticRouterPayload: [String: Any],
        exposureMode: MCPExposureMode
    ) throws -> MCPConfigFile {
        let semanticRouterPayloadURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sprite-semantic-router-\(UUID().uuidString).json")
        let semanticRouterPayloadData = try JSONSerialization.data(
            withJSONObject: semanticRouterPayload,
            options: [.prettyPrinted, .sortedKeys]
        )
        try semanticRouterPayloadData.write(to: semanticRouterPayloadURL, options: [.atomic])

        var semanticRouterEnv: [String: String] = [
            "CMUX_SPRITE_SEMANTIC_ROUTER_PAYLOAD_PATH": semanticRouterPayloadURL.path,
        ]
#if DEBUG
        if let debugLogPath = debugLogPathForMCP() {
            semanticRouterEnv["CMUX_DEBUG_LOG"] = debugLogPath
        }
#endif

        var mcpServers: [String: Any]
        switch exposureMode {
        case .routerOnly:
            mcpServers = [:]
        case .expanded:
            mcpServers = runtimePlan.mcpServers
        }
        mcpServers[semanticRouterServerName] = [
            "command": request.cmuxCLIPath,
            "args": [
                "mcp",
                "semantic-router",
            ],
            "env": semanticRouterEnv,
        ]

        let config: [String: Any] = [
            "mcpServers": mcpServers,
        ]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sprite-mcp-\(UUID().uuidString).json")
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            try? FileManager.default.removeItem(at: semanticRouterPayloadURL)
            throw error
        }
        return MCPConfigFile(
            url: url,
            semanticRouterPayloadURL: semanticRouterPayloadURL,
            exposureMode: exposureMode,
            serverNames: mcpServers.keys.sorted(),
            externalServerNames: exposureMode == .expanded ? runtimePlan.externalServerNames : [],
            externalAllowedTools: exposureMode == .expanded ? runtimePlan.externalAllowedTools : [],
            allowedTools: allowedTools(
                for: request,
                runtimePlan: runtimePlan,
                exposureMode: exposureMode
            ),
            byteCount: data.count,
            semanticRouterPayloadByteCount: semanticRouterPayloadData.count,
            externalPolicy: exposureMode == .expanded ? runtimePlan.externalPolicy : "router_only_scope_refresh"
        )
    }

    private static func allowedTools(
        for request: SortAssistantMCPRequest,
        runtimePlan: MCPRuntimePlan,
        exposureMode: MCPExposureMode
    ) -> [String] {
        switch exposureMode {
        case .routerOnly:
            return semanticRouterQualifiedToolNames
        case .expanded:
            return claudeAllowedTools(for: request, runtimePlan: runtimePlan)
        }
    }

    private static func executionAllowedTools(
        for request: SortAssistantMCPRequest,
        runtimePlan: MCPRuntimePlan
    ) -> [String] {
        orderedUniqueSortAssistant(
            request.route.allowedTools.map { "mcp__cmux_sprite__\($0)" } +
                runtimePlan.externalAllowedTools
        )
    }

    private static func claudeAllowedTools(
        for request: SortAssistantMCPRequest,
        runtimePlan: MCPRuntimePlan
    ) -> [String] {
        orderedUniqueSortAssistant(
            semanticRouterQualifiedToolNames +
                executionAllowedTools(for: request, runtimePlan: runtimePlan)
        )
    }

    private static func shouldLoadExternalMCP(for request: SortAssistantMCPRequest) -> Bool {
        normalizedRouteSteps(for: request).contains { step in
            switch step.intent {
            // Conversational intents are where the user asks about external
            // systems (Jira issues, Confluence pages, etc.), so they get the
            // configured external MCP servers. Sort/color/memory routes stay
            // sprite-only to avoid paying the external-server spawn latency on
            // every mutation turn.
            case .askContext, .normalChat:
                return true
            case .clearSession,
                 .proposeSort,
                 .applySort,
                 .explainCurrentOrder,
                 .manualReorderFeedback,
                 .rememberPreference,
                 .forgetPreference,
                 .rememberSpriteMemory,
                 .forgetSpriteMemory,
                 .undoSort,
                 .workspaceColor:
                return false
            }
        }
    }

#if DEBUG
    private static func debugLogPathForMCP() -> String? {
        if let path = ProcessInfo.processInfo.environment["CMUX_DEBUG_LOG"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            return path
        }
        let lastPathFile = "/tmp/cmux-last-debug-log-path"
        if let path = try? String(contentsOfFile: lastPathFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            return path
        }
        return nil
    }
#endif

    private static func claudeCodeExecutable() -> String {
        if let custom = ClaudeCodeIntegrationSettings.customClaudePath(),
           !custom.isEmpty {
            return custom
        }
        if let custom = ProcessInfo.processInfo.environment["CMUX_CUSTOM_CLAUDE_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            return custom
        }
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.claude/local/claude",
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return "claude"
    }

    private struct ProcessOutput {
        let stdout: String
        let stderr: String
        let status: Int32
    }

    private final class ProcessTimeoutFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func markTimedOut() {
            lock.lock()
            value = true
            lock.unlock()
        }

        var didTimeOut: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private final class ProcessPipeCollector: @unchecked Sendable {
        private let name: String
        private let parseStreamJSON: Bool
        private let debugSession: SortAssistantDebugSession?
        private let progressHandler: SortAssistantMCPProgressHandler?
        private let startedAtNanos: UInt64
        private let lock = NSLock()
        private var data = Data()
        private var lineBuffer = Data()
        private var lineCount = 0
        private var jsonLineCount = 0
        private var typeCounts: [String: Int] = [:]
        private var toolUseCount = 0
        private var toolUseNames: [String] = []
        private var resultSeen = false
        private var firstByteNanos: UInt64?
        private var lastEmittedProgressMessage: String?

        init(
            name: String,
            parseStreamJSON: Bool,
            debugSession: SortAssistantDebugSession?,
            progressHandler: SortAssistantMCPProgressHandler?
        ) {
            self.name = name
            self.parseStreamJSON = parseStreamJSON
            self.debugSession = debugSession
            self.progressHandler = progressHandler
            self.startedAtNanos = SortAssistantDebugSession.now()
        }

        func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.lock()
            if firstByteNanos == nil {
                firstByteNanos = SortAssistantDebugSession.now()
                debugSession?.log(
                    "mcp.claude.stream.first pipe=\(name) byteCount=\(chunk.count)",
                    phaseStartNanos: startedAtNanos
                )
                emitProgressLocked(Self.localizedProgressThinking())
            }
            data.append(chunk)
            if parseStreamJSON {
                appendLinesLocked(chunk)
            }
            lock.unlock()
        }

        func collectedData() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }

        func summaryFields() -> String {
            lock.lock()
            defer { lock.unlock() }
            let types = typeCounts
                .sorted { $0.key < $1.key }
                .map { "\($0.key):\($0.value)" }
                .joined(separator: ",")
            let tools = orderedUniqueSortAssistant(toolUseNames).joined(separator: ",")
            let firstByteMs = firstByteNanos
                .map { Self.formatMilliseconds(Self.elapsedMilliseconds(from: startedAtNanos, to: $0)) }
                ?? "nil"
            return "pipe=\(name) bytes=\(data.count) lines=\(lineCount) jsonLines=\(jsonLineCount) types=\(types.isEmpty ? "none" : types) toolUses=\(toolUseCount) toolNames=\(tools.isEmpty ? "none" : tools) resultSeen=\(resultSeen) firstByteMs=\(firstByteMs)"
        }

        private func appendLinesLocked(_ chunk: Data) {
            for byte in chunk {
                if byte == 10 {
                    processLineLocked(lineBuffer)
                    lineBuffer.removeAll(keepingCapacity: true)
                } else if byte != 13 {
                    lineBuffer.append(byte)
                }
            }
        }

        private func processLineLocked(_ lineData: Data) {
            guard !lineData.isEmpty,
                  let line = String(data: lineData, encoding: .utf8)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !line.isEmpty else {
                return
            }
            lineCount += 1
            guard let object = Self.jsonObject(from: line) else { return }
            jsonLineCount += 1
            let type = (object["type"] as? String) ?? "unknown"
            typeCounts[type, default: 0] += 1

            let toolNames = Self.toolUseNames(in: object)
            if !toolNames.isEmpty {
                toolUseCount += toolNames.count
                toolUseNames.append(contentsOf: toolNames)
                let names = orderedUniqueSortAssistant(toolNames).joined(separator: ",")
                debugSession?.log("mcp.claude.stream.toolUse count=\(toolNames.count) toolNames=\(names)")
                emitProgressLocked(Self.localizedProgressUsingTools(toolNames))
            }

            if type == "result" {
                resultSeen = true
                let subtype = (object["subtype"] as? String) ?? "unknown"
                let isError = (object["is_error"] as? Bool) ?? false
                let durationMs = Self.numberString(object["duration_ms"])
                let apiMs = Self.numberString(object["duration_api_ms"])
                let turns = Self.numberString(object["num_turns"])
                debugSession?.log(
                    "mcp.claude.stream.result subtype=\(subtype) isError=\(isError ? 1 : 0) durationMs=\(durationMs) apiMs=\(apiMs) turns=\(turns)"
                )
                emitProgressLocked(Self.localizedProgressFinalizing())
            }
        }

        private func emitProgressLocked(_ message: String) {
            guard lastEmittedProgressMessage != message else { return }
            lastEmittedProgressMessage = message
            progressHandler?(SortAssistantMCPProgressUpdate(message: message))
        }

        private static func jsonObject(from line: String) -> [String: Any]? {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return object
        }

        private static func toolUseNames(in object: [String: Any]) -> [String] {
            if let message = object["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                return content.compactMap { item in
                    guard (item["type"] as? String) == "tool_use" else { return nil }
                    return item["name"] as? String
                }
            }
            if let content = object["content"] as? [[String: Any]] {
                return content.compactMap { item in
                    guard (item["type"] as? String) == "tool_use" else { return nil }
                    return item["name"] as? String
                }
            }
            return []
        }

        private static func numberString(_ value: Any?) -> String {
            if let value = value as? NSNumber {
                return value.stringValue
            }
            if let value {
                return String(describing: value)
            }
            return "nil"
        }

        private static func elapsedMilliseconds(from start: UInt64, to end: UInt64) -> Double {
            Double(end >= start ? end - start : 0) / 1_000_000
        }

        private static func formatMilliseconds(_ value: Double) -> String {
            String(format: "%.1f", value)
        }

        private static func localizedProgressThinking() -> String {
            String(localized: "sortAssistant.mcp.stream.thinking", defaultValue: "Thinking...")
        }

        private static func localizedProgressUsingTools(_ toolNames: [String]) -> String {
            let displayNames = orderedUniqueSortAssistant(toolNames)
                .map(prettyToolUseName)
            if displayNames.count == 1, let tool = displayNames.first {
                return String(
                    format: String(
                        localized: "sortAssistant.mcp.stream.usingTool",
                        defaultValue: "%@..."
                    ),
                    tool
                )
            }
            let tools = displayNames.joined(separator: ", ")
            return String(
                format: String(
                    localized: "sortAssistant.mcp.stream.usingTools",
                    defaultValue: "Using tools: %@..."
                ),
                tools
            )
        }

        private static func localizedProgressFinalizing() -> String {
            String(localized: "sortAssistant.mcp.stream.finalizing", defaultValue: "Finalizing...")
        }

        private static func prettyToolUseName(_ rawName: String) -> String {
            let toolName = unqualifiedToolName(rawName)
            switch toolName {
            case "search":
                return String(localized: "sortAssistant.mcp.tool.search", defaultValue: "Searching semantic router")
            case "route":
                return String(localized: "sortAssistant.mcp.tool.route", defaultValue: "Reading semantic route")
            case "workspace_color_get":
                return String(localized: "sortAssistant.mcp.tool.workspaceColorGet", defaultValue: "Reading workspace color")
            case "workspace_color_set":
                return String(localized: "sortAssistant.mcp.tool.workspaceColorSet", defaultValue: "Setting workspace color")
            case "workspace_color_clear":
                return String(localized: "sortAssistant.mcp.tool.workspaceColorClear", defaultValue: "Clearing workspace color")
            case "list_state":
                return String(localized: "sortAssistant.mcp.tool.listState", defaultValue: "Reading workspace list")
            case "assistant_working_context_get":
                return String(localized: "sortAssistant.mcp.tool.assistantWorkingContext", defaultValue: "Reading assistant context")
            case "workspace_snapshot_get":
                return String(localized: "sortAssistant.mcp.tool.workspaceSnapshot", defaultValue: "Reading workspace snapshot")
            case "context_freshness_get":
                return String(localized: "sortAssistant.mcp.tool.contextFreshness", defaultValue: "Reading context freshness")
            case "suggestions_active_get":
                return String(localized: "sortAssistant.mcp.tool.suggestionsActive", defaultValue: "Reading suggestions")
            case "context_agent_collect":
                return String(localized: "sortAssistant.mcp.tool.contextAgentCollect", defaultValue: "Collecting cmux context")
            case "proactive_suggestions_refresh":
                return String(localized: "sortAssistant.mcp.tool.proactiveSuggestionsRefresh", defaultValue: "Refreshing proactive suggestions")
            case "proactive_signal_report":
                return String(localized: "sortAssistant.mcp.tool.proactiveSignalReport", defaultValue: "Reporting proactive signal")
            case "suggestion_accept":
                return String(localized: "sortAssistant.mcp.tool.suggestionAccept", defaultValue: "Accepting suggestion")
            case "suggestion_dismiss":
                return String(localized: "sortAssistant.mcp.tool.suggestionDismiss", defaultValue: "Dismissing suggestion")
            case "ranking_latest_get":
                return String(localized: "sortAssistant.mcp.tool.rankingLatest", defaultValue: "Reading workspace ranking")
            case "repository_context":
                return String(localized: "sortAssistant.mcp.tool.repositoryContext", defaultValue: "Reading repository context")
            case "context_collect":
                return String(localized: "sortAssistant.mcp.tool.contextCollect", defaultValue: "Collecting context")
            case "github_context":
                return String(localized: "sortAssistant.mcp.tool.githubContext", defaultValue: "Reading GitHub context")
            case "github_pr_context", "ghpr_context":
                return String(localized: "sortAssistant.mcp.tool.prContext", defaultValue: "Reading pull request context")
            case "ghpr_status":
                return String(localized: "sortAssistant.mcp.tool.prStatus", defaultValue: "Checking pull request status")
            case "workspace_digest_get":
                return String(localized: "sortAssistant.mcp.tool.workspaceDigest", defaultValue: "Reading workspace digest")
            case "workspace_digest_progress":
                return String(localized: "sortAssistant.mcp.tool.workspaceDigestProgress", defaultValue: "Checking digest progress")
            case "memory_query":
                return String(localized: "sortAssistant.mcp.tool.memoryQuery", defaultValue: "Reading sort memory")
            case "memory_write_candidate":
                return String(localized: "sortAssistant.mcp.tool.memoryWrite", defaultValue: "Preparing memory update")
            case "memory_forget":
                return String(localized: "sortAssistant.mcp.tool.memoryForget", defaultValue: "Forgetting sort memory")
            case "sprite_memory_query":
                return String(localized: "sortAssistant.mcp.tool.spriteMemoryQuery", defaultValue: "Reading sprite memory")
            case "sprite_memory_write":
                return String(localized: "sortAssistant.mcp.tool.spriteMemoryWrite", defaultValue: "Writing sprite memory")
            case "sprite_memory_forget":
                return String(localized: "sortAssistant.mcp.tool.spriteMemoryForget", defaultValue: "Forgetting sprite memory")
            case "sort_context":
                return String(localized: "sortAssistant.mcp.tool.sortContext", defaultValue: "Reading sort context")
            case "sort_preview":
                return String(localized: "sortAssistant.mcp.tool.sortPreview", defaultValue: "Previewing sort")
            case "sort_apply":
                return String(localized: "sortAssistant.mcp.tool.sortApply", defaultValue: "Applying sort")
            case "sort_explain":
                return String(localized: "sortAssistant.mcp.tool.sortExplain", defaultValue: "Explaining order")
            case "sort_undo":
                return String(localized: "sortAssistant.mcp.tool.sortUndo", defaultValue: "Undoing sort")
            default:
                return fallbackPrettyToolName(toolName)
            }
        }

        private static func unqualifiedToolName(_ rawName: String) -> String {
            let parts = rawName.components(separatedBy: "__")
            if parts.count >= 3, parts.first == "mcp" {
                return parts.dropFirst(2).joined(separator: "__")
            }
            return rawName
        }

        private static func fallbackPrettyToolName(_ toolName: String) -> String {
            toolName
                .replacingOccurrences(of: "_", with: " ")
                .split(separator: " ")
                .map { word in
                    guard let first = word.first else { return "" }
                    return first.uppercased() + String(word.dropFirst())
                }
                .joined(separator: " ")
        }
    }

    private static func runClaudeCode(
        executable: String,
        arguments: [String],
        timeoutSeconds: TimeInterval,
        debugSession: SortAssistantDebugSession?,
        progressHandler: SortAssistantMCPProgressHandler?
    ) throws -> ProcessOutput {
        let prepareStart = SortAssistantDebugSession.now()
        let process = Process()
        if executable.contains("/") {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
        }
        process.currentDirectoryURL = try SortAssistantClaudeWorkDirectory.url()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let stdoutCollector = ProcessPipeCollector(
            name: "stdout",
            parseStreamJSON: SortAssistantClaudeCodeRuntime.outputFormat == "stream-json",
            debugSession: debugSession,
            progressHandler: progressHandler
        )
        let stderrCollector = ProcessPipeCollector(
            name: "stderr",
            parseStreamJSON: false,
            debugSession: debugSession,
            progressHandler: nil
        )
        stdout.fileHandleForReading.readabilityHandler = { handle in
            stdoutCollector.append(handle.availableData)
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            stderrCollector.append(handle.availableData)
        }
        debugSession?.log(
            "mcp.claude.process.prepared executable=\(executableName(executable)) argc=\(arguments.count) argvCharCount=\(arguments.reduce(0) { $0 + $1.count }) outputFormat=\(SortAssistantClaudeCodeRuntime.outputFormat)",
            phaseStartNanos: prepareStart
        )

        let spawnStart = SortAssistantDebugSession.now()
        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            debugSession?.log(
                "mcp.claude.spawn.failed error=\(SortAssistantDebugSession.errorSummary(error))",
                phaseStartNanos: spawnStart
            )
            throw error
        }
        debugSession?.log(
            "mcp.claude.spawn.end pid=\(process.processIdentifier)",
            phaseStartNanos: spawnStart
        )
        let timeoutFlag = ProcessTimeoutFlag()
        let timeout = DispatchWorkItem {
            if process.isRunning {
                timeoutFlag.markTimedOut()
                process.terminate()
                let pid = process.processIdentifier
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                    if process.isRunning {
                        kill(pid, SIGKILL)
                    }
                }
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + timeoutSeconds,
            execute: timeout
        )
        let waitStart = SortAssistantDebugSession.now()
        process.waitUntilExit()
        timeout.cancel()
        debugSession?.log(
            "mcp.claude.wait.end status=\(process.terminationStatus)",
            phaseStartNanos: waitStart
        )
        if timeoutFlag.didTimeOut {
            debugSession?.log("mcp.claude.timeout timeoutSeconds=\(Int(timeoutSeconds.rounded()))")
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            stdout.fileHandleForReading.closeFile()
            stderr.fileHandleForReading.closeFile()
            throw SortAssistantMCPClientTimeoutError(timeoutSeconds: timeoutSeconds)
        }
        let readStart = SortAssistantDebugSession.now()
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        stdoutCollector.append(stdout.fileHandleForReading.availableData)
        stderrCollector.append(stderr.fileHandleForReading.availableData)
        let stdoutData = stdoutCollector.collectedData()
        let stderrData = stderrCollector.collectedData()
        debugSession?.log("mcp.claude.stream.summary \(stdoutCollector.summaryFields())")
        debugSession?.log("mcp.claude.stream.summary \(stderrCollector.summaryFields())")
        debugSession?.log(
            "mcp.claude.read.end stdoutBytes=\(stdoutData.count) stderrBytes=\(stderrData.count)",
            phaseStartNanos: readStart
        )
        return ProcessOutput(
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
            status: process.terminationStatus
        )
    }

    private static func runClaudeCodeRetryingSessionInUse(
        executable: String,
        arguments: [String],
        timeoutSeconds: TimeInterval,
        debugSession: SortAssistantDebugSession?,
        progressHandler: SortAssistantMCPProgressHandler?
    ) throws -> ProcessOutput {
        var output = try runClaudeCode(
            executable: executable,
            arguments: arguments,
            timeoutSeconds: timeoutSeconds,
            debugSession: debugSession,
            progressHandler: progressHandler
        )
        for (index, delay) in claudeSessionInUseRetryDelays.enumerated() where output.status != 0 {
            guard isClaudeSessionInUseError(output) else { break }
            debugSession?.log(
                "mcp.claude.sessionInUseRetry attempt=\(index + 1) delayMs=\(Int((delay * 1000).rounded()))"
            )
            Thread.sleep(forTimeInterval: delay)
            output = try runClaudeCode(
                executable: executable,
                arguments: arguments,
                timeoutSeconds: timeoutSeconds,
                debugSession: debugSession,
                progressHandler: progressHandler
            )
        }
        return output
    }

    private static func isClaudeSessionInUseError(_ output: ProcessOutput) -> Bool {
        let text = "\(output.stderr)\n\(output.stdout)".lowercased()
        return text.contains("session id") && text.contains("already in use")
    }

    private static func executableName(_ executable: String) -> String {
        executable.contains("/")
            ? URL(fileURLWithPath: executable).lastPathComponent
            : executable
    }

}
