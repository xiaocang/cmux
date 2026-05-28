import Darwin
import Foundation
import MCP

struct SortAssistantIntentRouter: Sendable {
    private static let semanticConfidenceFloor = 0.35
    private static let semanticTimeoutSeconds: TimeInterval = 8
    private static let localSemanticRouterTestRequest = "Tell me the current repository context and current branch."
    private static let localSemanticRouterExpectedIntent = SortAssistantIntent.askContext
    private static let clearSessionCommands = ["/clear", "/new"]
    private static let semanticIntentOrder: [SortAssistantIntent] = [
        .askContext,
        .explainCurrentOrder,
        .proposeSort,
        .applySort,
        .manualReorderFeedback,
        .rememberPreference,
        .forgetPreference,
        .rememberSpriteMemory,
        .forgetSpriteMemory,
        .undoSort,
        .workspaceColor,
        .normalChat,
    ]

    func immediateIntent(for text: String, externalGoal: Bool = false) -> SortAssistantIntent? {
        if Self.clearSessionCommands.contains(Self.slashCommandName(text)) {
            return .clearSession
        }
        return nil
    }

    func semanticIntent(
        for text: String,
        externalGoal: Bool = false,
        conversationContext: [String] = [],
        workspaceDirectory: String? = nil,
        debugSession: SortAssistantDebugSession? = nil,
        runtimeMode: CmuxRuntimeMode = CmuxRuntimeMode.current()
    ) async -> SortAssistantIntentDecision {
        if let immediate = immediateIntent(for: text, externalGoal: externalGoal) {
            debugSession?.log("router.immediate intent=\(immediate.rawValue)")
            return SortAssistantIntentDecision(intent: immediate, confidence: 1, reason: "deterministic")
        }

        if runtimeMode.disableRealLLM || runtimeMode.fakeAssistant {
            // UI-test/fake-assistant mode must not reach local LLM, Claude, or MCP
            // discovery. Keep this conservative and production-disabled.
            let decision = Self.deterministicNoLLMDecision(
                text: text,
                externalGoal: externalGoal,
                conversationContext: conversationContext
            )
            debugSession?.log(
                "router.end provider=deterministicNoLLM intent=\(decision.intent.rawValue) steps=\(decision.stepDebugDescription) reason=\(decision.reason ?? "none")"
            )
            return decision
        }

        return await Task.detached(priority: .userInitiated) {
            let toolCatalog = await Self.semanticMCPToolCatalog(
                workspaceDirectory: workspaceDirectory,
                debugSession: debugSession
            )
            var localIssue: SortAssistantSemanticRouterIssue?
            debugSession?.log("router.begin externalGoal=\(externalGoal) contextItems=\(conversationContext.count)")
            do {
                let phaseStart = SortAssistantDebugSession.now()
                let decision = try await Self.classifyWithConfiguredLocalLLM(
                    text: text,
                    externalGoal: externalGoal,
                    conversationContext: conversationContext,
                    toolCatalog: toolCatalog,
                    workspaceDirectory: workspaceDirectory
                )
                guard !decision.containsClearSession,
                      decision.confidence >= Self.semanticConfidenceFloor else {
                    debugSession?.log(
                        "router.local.rejected intent=\(decision.intent.rawValue) steps=\(decision.stepDebugDescription) confidence=\(Self.debugConfidence(decision.confidence))",
                        phaseStartNanos: phaseStart
                    )
                    throw SortAssistantSemanticRouterRuntimeError(issue: SortAssistantSemanticRouterIssue(
                        stage: .local,
                        code: "low_confidence",
                        detail: "intent=\(decision.intent.rawValue) confidence=\(Self.debugConfidence(decision.confidence))"
                    ))
                }
                debugSession?.log(
                    "router.end provider=local intent=\(decision.intent.rawValue) steps=\(decision.stepDebugDescription) confidence=\(Self.debugConfidence(decision.confidence)) adjustment=\(decision.routeAdjustment.debugDescription) fallback=false",
                    phaseStartNanos: phaseStart
                )
                return decision
            } catch {
                localIssue = Self.semanticIssue(from: error, stage: .local, fallbackCode: "failed")
                debugSession?.log("router.local.failed error=\(localIssue?.debugDescription ?? Self.debugError(error))")
                // Local semantic routing is optional. Claude Code remains the
                // semantic classifier when no local provider is configured or
                // the local provider is unavailable.
            }

            do {
                let phaseStart = SortAssistantDebugSession.now()
                let decision = try Self.classifyWithClaudeCode(
                    text: text,
                    externalGoal: externalGoal,
                    conversationContext: conversationContext,
                    toolCatalog: toolCatalog
                )
                guard !decision.containsClearSession else {
                    debugSession?.log(
                        "router.claude.rejected intent=\(decision.intent.rawValue) steps=\(decision.stepDebugDescription) confidence=\(Self.debugConfidence(decision.confidence))",
                        phaseStartNanos: phaseStart
                    )
                    let report = Self.semanticUnavailableReport(
                        reason: "claudeClearSessionRejected",
                        localIssue: localIssue,
                        claudeIssue: SortAssistantSemanticRouterIssue(
                            stage: .claude,
                            code: "clear_session_rejected",
                            detail: "intent=\(decision.intent.rawValue)"
                        )
                    )
                    let unavailable = Self.semanticUnavailableDecision(reason: "claudeClearSessionRejected", report: report)
                    debugSession?.log("router.end provider=semanticUnavailable intent=\(unavailable.intent.rawValue) \(report.debugDescription)")
                    return unavailable
                }
                guard decision.confidence >= Self.semanticConfidenceFloor else {
                    debugSession?.log(
                        "router.claude.rejected intent=\(decision.intent.rawValue) steps=\(decision.stepDebugDescription) confidence=\(Self.debugConfidence(decision.confidence))",
                        phaseStartNanos: phaseStart
                    )
                    let report = Self.semanticUnavailableReport(
                        reason: "claudeLowConfidence",
                        localIssue: localIssue,
                        claudeIssue: SortAssistantSemanticRouterIssue(
                            stage: .claude,
                            code: "low_confidence",
                            detail: "intent=\(decision.intent.rawValue) confidence=\(Self.debugConfidence(decision.confidence))"
                        )
                    )
                    let unavailable = Self.semanticUnavailableDecision(reason: "claudeLowConfidence", report: report)
                    debugSession?.log("router.end provider=semanticUnavailable intent=\(unavailable.intent.rawValue) \(report.debugDescription)")
                    return unavailable
                }
                debugSession?.log(
                    "router.end provider=claude intent=\(decision.intent.rawValue) steps=\(decision.stepDebugDescription) confidence=\(Self.debugConfidence(decision.confidence)) adjustment=\(decision.routeAdjustment.debugDescription) fallback=false",
                    phaseStartNanos: phaseStart
                )
                return decision
            } catch {
                let claudeIssue = Self.semanticIssue(from: error, stage: .claude, fallbackCode: "failed")
                debugSession?.log("router.claude.failed error=\(claudeIssue.debugDescription)")
                let report = Self.semanticUnavailableReport(
                    reason: "claudeFailed",
                    localIssue: localIssue,
                    claudeIssue: claudeIssue
                )
                let unavailable = Self.semanticUnavailableDecision(reason: "claudeFailed", report: report)
                debugSession?.log("router.end provider=semanticUnavailable intent=\(unavailable.intent.rawValue) \(report.debugDescription)")
                return unavailable
            }
        }.value
    }

    private static func deterministicNoLLMDecision(
        text: String,
        externalGoal: Bool,
        conversationContext: [String]
    ) -> SortAssistantIntentDecision {
        let normalized = normalizedSemanticText(text)
        let recent = normalizedSemanticText(conversationContext.joined(separator: "\n"))
        let combined = [normalized, recent].filter { !$0.isEmpty }.joined(separator: " ")

        let intent: SortAssistantIntent
        let sortRoute: SortAssistantSortRoute?
        if containsAny(combined, ["workspace color", "tab color", "sidebar color", "colour", "color "]) {
            intent = .workspaceColor
            sortRoute = nil
        } else if containsAny(combined, ["undo sort", "undo reorder", "revert sort", "revert reorder"]) {
            intent = .undoSort
            sortRoute = nil
        } else if containsAny(combined, [
            "forget sprite",
            "delete sprite memory",
            "remove sprite memory",
            "forget workspace memory",
            "delete workspace memory",
            "remove workspace memory",
        ]) {
            intent = .forgetSpriteMemory
            sortRoute = nil
        } else if containsAny(combined, ["remember sprite", "workspace memory", "memory.md", "project memory"]) {
            intent = .rememberSpriteMemory
            sortRoute = nil
        } else if containsAny(combined, ["remember", "save preference", "keep preference"]) {
            intent = .rememberPreference
            sortRoute = nil
        } else if containsAny(combined, ["forget", "delete memory", "remove memory"]) {
            intent = .forgetPreference
            sortRoute = nil
        } else if containsAny(combined, ["why", "explain", "current order", "ordered this way"]) {
            intent = .explainCurrentOrder
            sortRoute = nil
        } else if containsAny(combined, ["context", "status", "summarize", "summary", "github", "branch", "repo", "pull request"])
            || containsAnyToken(combined, ["pr", "ci"]) {
            intent = .askContext
            sortRoute = nil
        } else if containsAny(combined, ["sort", "reorder", "order", "rank", "prioritize", "arrange", "move"]) {
            intent = externalGoal || containsAny(combined, ["apply", "do it", "execute", "actually"])
                ? .applySort
                : .proposeSort
            sortRoute = containsAny(combined, ["by color", "by colour", "color group", "colour group"])
                ? .colorGroup
                : nil
        } else {
            intent = .normalChat
            sortRoute = nil
        }

        return SortAssistantIntentDecision(
            intent: intent,
            confidence: 1,
            reason: "real_llm_disabled",
            sortRoute: sortRoute
        )
    }

    private static func normalizedSemanticText(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private static func containsAnyToken(_ text: String, _ tokens: Set<String>) -> Bool {
        text.split { !$0.isLetter && !$0.isNumber }.contains { token in
            tokens.contains(String(token))
        }
    }

    static func testLocalSemanticRouter(
        provider: String,
        model: String,
        baseURL: String,
        timeoutSeconds: TimeInterval
    ) async throws -> SortAssistantLocalSemanticRouterTestResult {
        let config = SpriteAssistantSemanticRouterConfig(
            provider: provider,
            model: model,
            baseURL: baseURL,
            apiKey: nil,
            timeoutSeconds: min(max(timeoutSeconds, 1), 30)
        )
        let decision = try await classifyWithLocalLLM(
            config: config,
            text: localSemanticRouterTestRequest,
            externalGoal: false,
            conversationContext: [
                "target_workspace: cmux id=00000000-0000-0000-0000-000000000000 directory=/tmp/cmux",
            ],
            toolCatalog: await semanticMCPToolCatalog(workspaceDirectory: nil, includeBuiltIn: false)
        )
        return SortAssistantLocalSemanticRouterTestResult(
            request: localSemanticRouterTestRequest,
            decision: decision,
            expectedIntent: localSemanticRouterExpectedIntent,
            passed: decision.intent == localSemanticRouterExpectedIntent
                && decision.confidence >= semanticConfidenceFloor
        )
    }

    private static func semanticUnavailableDecision(
        reason: String,
        report: SortAssistantSemanticRouterUnavailableReport? = nil
    ) -> SortAssistantIntentDecision {
        return SortAssistantIntentDecision(
            intent: .normalChat,
            confidence: 0,
            reason: reason,
            isFallback: true,
            semanticRouterUnavailableReport: report
        )
    }

    private static func semanticUnavailableReport(
        reason: String,
        localIssue: SortAssistantSemanticRouterIssue?,
        claudeIssue: SortAssistantSemanticRouterIssue?
    ) -> SortAssistantSemanticRouterUnavailableReport {
        SortAssistantSemanticRouterUnavailableReport(
            reason: reason,
            fallbackIntent: .normalChat,
            localIssue: localIssue,
            claudeIssue: claudeIssue
        )
    }

    private static func semanticIssue(
        from error: Error,
        stage: SortAssistantSemanticRouterIssue.Stage,
        fallbackCode: String
    ) -> SortAssistantSemanticRouterIssue {
        if let error = error as? SortAssistantSemanticRouterRuntimeError {
            return error.issue
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            return SortAssistantSemanticRouterIssue(
                stage: stage,
                code: "file_error",
                detail: Self.debugError(error)
            )
        }
        return SortAssistantSemanticRouterIssue(
            stage: stage,
            code: fallbackCode,
            detail: Self.debugError(error),
            status: nsError.code > 0 ? nsError.code : nil
        )
    }

    private static func debugConfidence(_ confidence: Double) -> String {
        String(format: "%.2f", confidence)
    }

    private static func debugError(_ error: Error) -> String {
        String(describing: error)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .prefix(180)
            .description
    }

    private static func classifyWithConfiguredLocalLLM(
        text: String,
        externalGoal: Bool,
        conversationContext: [String],
        toolCatalog: [[String: Any]],
        workspaceDirectory: String?
    ) async throws -> SortAssistantIntentDecision {
        guard let config = SpriteAssistantConfig.semanticRouterConfig(workspaceDirectory: workspaceDirectory) else {
            throw SortAssistantSemanticRouterRuntimeError(issue: SortAssistantSemanticRouterIssue(
                stage: .local,
                code: SpriteAssistantConfig.semanticRouterConfigIssue(workspaceDirectory: workspaceDirectory)
            ))
        }

        return try await classifyWithLocalLLM(
            config: config,
            text: text,
            externalGoal: externalGoal,
            conversationContext: conversationContext,
            toolCatalog: toolCatalog
        )
    }

    private static func classifyWithLocalLLM(
        config: SpriteAssistantSemanticRouterConfig,
        text: String,
        externalGoal: Bool,
        conversationContext: [String],
        toolCatalog: [[String: Any]]
    ) async throws -> SortAssistantIntentDecision {
        let content: String
        switch config.normalizedProvider {
        case "openai", "openai_compatible", "openai_compat":
            content = try await classifyWithOpenAICompatibleLocalLLM(
                config: config,
                text: text,
                externalGoal: externalGoal,
                conversationContext: conversationContext,
                toolCatalog: toolCatalog
            )
        default:
            content = try await classifyWithOllama(
                config: config,
                text: text,
                externalGoal: externalGoal,
                conversationContext: conversationContext,
                toolCatalog: toolCatalog
            )
        }
        do {
            return try parseDecision(from: content)
        } catch {
            throw SortAssistantSemanticRouterRuntimeError(issue: SortAssistantSemanticRouterIssue(
                stage: .local,
                code: "invalid_decision",
                detail: Self.debugError(error)
            ))
        }
    }

    private static func classifyWithOllama(
        config: SpriteAssistantSemanticRouterConfig,
        text: String,
        externalGoal: Bool,
        conversationContext: [String],
        toolCatalog: [[String: Any]]
    ) async throws -> String {
        let url = try endpointURL(baseURL: config.baseURL, defaultPath: "/api/chat")
        let response = try await postLocalLLMJSON(
            url: url,
            apiKey: config.apiKey,
            timeoutSeconds: config.timeoutSeconds,
            body: [
                "model": config.model,
                "stream": false,
                "messages": localLLMMessages(
                    text: text,
                    externalGoal: externalGoal,
                    conversationContext: conversationContext,
                    toolCatalog: toolCatalog
                ),
                "options": [
                    "temperature": 0,
                ],
            ]
        )
        if let message = response["message"] as? [String: Any],
           let content = message["content"] as? String {
            return content
        }
        if let content = response["response"] as? String {
            return content
        }
        throw SortAssistantSemanticRouterRuntimeError(issue: SortAssistantSemanticRouterIssue(
            stage: .local,
            code: "missing_content"
        ))
    }

    private static func classifyWithOpenAICompatibleLocalLLM(
        config: SpriteAssistantSemanticRouterConfig,
        text: String,
        externalGoal: Bool,
        conversationContext: [String],
        toolCatalog: [[String: Any]]
    ) async throws -> String {
        let url = try endpointURL(baseURL: config.baseURL, defaultPath: "/chat/completions")
        let response = try await postLocalLLMJSON(
            url: url,
            apiKey: config.apiKey,
            timeoutSeconds: config.timeoutSeconds,
            body: [
                "model": config.model,
                "temperature": 0,
                "messages": localLLMMessages(
                    text: text,
                    externalGoal: externalGoal,
                    conversationContext: conversationContext,
                    toolCatalog: toolCatalog
                ),
            ]
        )
        guard let choices = response["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw SortAssistantSemanticRouterRuntimeError(issue: SortAssistantSemanticRouterIssue(
                stage: .local,
                code: "missing_content"
            ))
        }
        return content
    }

    private static func localLLMMessages(
        text: String,
        externalGoal: Bool,
        conversationContext: [String],
        toolCatalog: [[String: Any]]
    ) -> [[String: String]] {
        [
            [
                "role": "system",
                "content": semanticSystemPrompt,
            ],
            [
                "role": "user",
                "content": semanticUserPrompt(
                    text: text,
                    externalGoal: externalGoal,
                    conversationContext: conversationContext,
                    toolCatalog: toolCatalog
                ),
            ],
        ]
    }

    private static func endpointURL(baseURL: String, defaultPath: String) throws -> URL {
        guard let base = URL(string: baseURL) else {
            throw SortAssistantSemanticRouterRuntimeError(issue: SortAssistantSemanticRouterIssue(
                stage: .local,
                code: "invalid_base_url",
                detail: baseURL
            ))
        }
        let normalizedDefault = defaultPath.hasPrefix("/") ? defaultPath : "/\(defaultPath)"
        if base.path.hasSuffix(normalizedDefault) {
            return base
        }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        let currentPath = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        let nextPath: String
        if currentPath.isEmpty {
            nextPath = normalizedDefault
        } else {
            nextPath = "/" + currentPath + normalizedDefault
        }
        components?.path = nextPath
        guard let url = components?.url else {
            throw SortAssistantSemanticRouterRuntimeError(issue: SortAssistantSemanticRouterIssue(
                stage: .local,
                code: "invalid_base_url",
                detail: baseURL
            ))
        }
        return url
    }

    private static func postLocalLLMJSON(
        url: URL,
        apiKey: String?,
        timeoutSeconds: TimeInterval,
        body: [String: Any]
    ) async throws -> [String: Any] {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeoutSeconds
        configuration.timeoutIntervalForResource = timeoutSeconds
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            throw SortAssistantSemanticRouterRuntimeError(issue: SortAssistantSemanticRouterIssue(
                stage: .local,
                code: "http_status",
                detail: url.absoluteString,
                status: http.statusCode
            ))
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SortAssistantSemanticRouterRuntimeError(issue: SortAssistantSemanticRouterIssue(
                stage: .local,
                code: "invalid_json"
            ))
        }
        return object
    }

    private static func classifyWithClaudeCode(
        text: String,
        externalGoal: Bool,
        conversationContext: [String],
        toolCatalog: [[String: Any]]
    ) throws -> SortAssistantIntentDecision {
        let executable = claudeCodeExecutable()
        if executable.contains("/") && !FileManager.default.isExecutableFile(atPath: executable) {
            throw SortAssistantSemanticRouterRuntimeError(issue: SortAssistantSemanticRouterIssue(
                stage: .claude,
                code: "executable_missing",
                detail: executable
            ))
        }

        let output = try runClaudeCode(
            executable: executable,
            arguments: [
                "-p", semanticUserPrompt(
                    text: text,
                    externalGoal: externalGoal,
                    conversationContext: conversationContext,
                    toolCatalog: toolCatalog
                ),
                "--output-format", SortAssistantClaudeCodeRuntime.outputFormat,
                "--allowed-tools", "",
                "--model", "haiku",
            ] +
                SortAssistantClaudeCodeRuntime.outputFormatArguments +
                (try SortAssistantClaudeCodeRuntime.isolatedArguments(systemPrompt: semanticSystemPrompt)),
            timeoutSeconds: semanticTimeoutSeconds
        )
        guard output.status == 0 else {
            throw SortAssistantSemanticRouterRuntimeError(issue: SortAssistantSemanticRouterIssue(
                stage: .claude,
                code: "exited",
                detail: output.stderr,
                status: Int(output.status)
            ))
        }

        let content = SortAssistantClaudeOutputParser.resultText(from: output.stdout) ?? output.stdout
        do {
            return try parseDecision(from: content)
        } catch {
            throw SortAssistantSemanticRouterRuntimeError(issue: SortAssistantSemanticRouterIssue(
                stage: .claude,
                code: "invalid_decision",
                detail: Self.debugError(error)
            ))
        }
    }

    private static var semanticSystemPrompt: String {
        """
        You are the semantic intent router for cmux's sprite assistant. Classify the latest input into one or more ordered task routes. Do not default to sorting.
        Use the availableMCPTools and routeCatalog in the user payload as the source of truth for tool capabilities and route affordances.
        Return only one strict JSON object with this schema:
        {"intent":"ask_context|clear_session|explain_current_order|propose_sort|apply_sort|manual_reorder_feedback|remember_preference|forget_preference|remember_sprite_memory|forget_sprite_memory|undo_sort|workspace_color|normal_chat","sortRoute":"default|color_group|null","steps":[{"intent":"apply_sort","sortRoute":"default|color_group|null"}],"routeAdjustment":{"promptFragmentMode":"append|replace","promptFragments":["workspace_color"],"removePromptFragments":["normal_chat"],"allowedToolsMode":"append|replace","allowedTools":["workspace_color_set"],"removeAllowedTools":["sort_apply"]},"confidence":0.0,"reason":"short"}

        Intent meanings:
        - ask_context: the user asks what list/context/signals you can see, including GitHub, ghpr, PR, CI, review, Jira, Git, branch, submodule, current directory, repository context, dead/stale/inactive/unused workspaces, workspace usage, recent sessions, or last-active workspaces.
        - clear_session: reserved for exact slash commands handled outside this semantic router; do not return it for natural-language input.
        - explain_current_order: the user asks why the sidebar is ordered this way.
        - propose_sort: the user asks for a recommendation, preview, suggestion, or how to sort without clearly asking to apply it.
        - apply_sort: the user asks to actually sort, reorder, move, arrange, rank, or prioritize workspaces/sidebar items.
        - manual_reorder_feedback: the user reports a manual drag/move or gives feedback about a reorder they already made.
        - remember_preference: the user asks you to save a future free-sort/sidebar sorting preference.
        - forget_preference: the user asks you to forget/delete a saved free-sort/sidebar sorting preference.
        - remember_sprite_memory: the user asks you to remember a project/session fact in the workspace memory.md, not a sorting preference.
        - forget_sprite_memory: the user asks you to forget/delete a project/session fact from workspace memory.md, not a sorting preference.
        - undo_sort: the user asks to undo/revert the assistant's previous sort.
        - workspace_color: the user asks to read, set, change, clear, reset, or remove a workspace/sidebar/tab color.
        - normal_chat: greetings, identity questions, help/meta questions, or anything not about workspace sorting/memory/order.

        Important routing rules:
        - The top-level intent is the primary or first task route for compatibility.
        - Always include steps. For a single-route request, steps contains exactly one item matching intent. For a mixed request, steps contains every requested task in user-specified order.
        - If the user asks to sort workspaces and then color workspaces, include both apply_sort/propose_sort and workspace_color steps.
        - Do not include normal_chat in steps when there is a concrete task route such as ask_context, workspace_color, sorting, memory, explanation, or undo.
        - First decide whether the input is about conversation/help, context, workspace color, memory, current order explanation, or sorting. Only choose propose_sort/apply_sort after that route check.
        - Do not classify slash commands. Slash commands are handled before semantic routing.
        - Never classify natural-language clear/reset/new-chat requests as clear_session. clear_session is reserved for exact slash commands handled outside this semantic router.
        - Do not classify "who are you", "who you are", "what are you", or "what can you do" as apply_sort.
        - Classify the latest input using recentConversation when it is a follow-up. Pronouns like "it", "that", and "this" may refer to the previous assistant answer.
        - Questions or follow-ups about GitHub/ghpr/PR/CI/review/Jira/Git/repository/current repo/current directory/submodule context are ask_context unless the user asks to sort or reorder with those signals.
        - Questions about dead/stale/inactive/unused workspace detection, workspace usage, recent sessions, last active workspaces, git activity, or file modification timestamps are ask_context unless the user asks to sort or reorder.
        - Mentions of "workspace", "repo", "context", "current", "status", "branch", "PR", "urgent", or "priority" are not sorting requests by themselves.
        - Choose propose_sort/apply_sort only when the user explicitly asks to sort, order, reorder, rank, prioritize, arrange, move, or group workspace/sidebar items, or when recentConversation is already about a sort result and the latest input continues that sort task.
        - If the input is not explicitly about sorting the workspace sidebar, classify normal_chat or ask_context.
        - If it explicitly asks to apply/do/execute a workspace/sidebar reorder, classify apply_sort.
        - If it explicitly asks for a recommendation, preview, suggestion, or how to sort without clearly asking to apply it, classify propose_sort.
        - If externalGoal is true and the input is a sort/order request, classify apply_sort unless it is clearly asking only for a preview/explanation.
        - For propose_sort/apply_sort, set sortRoute to color_group when the requested sort criterion is workspace/sidebar/tab color or custom color. Short sort-command arguments such as "by color" mean sorting workspaces by color.
        - For all other intents and non-color sort criteria, set sortRoute to null or default.
        - Plain remember/forget requests in this sort assistant should default to remember_preference/forget_preference.
        - Remember/forget requests about workspace sorting/sidebar order are remember_preference/forget_preference.
        - Use remember_sprite_memory/forget_sprite_memory only when the user explicitly asks for sprite/workspace memory.md/project/session memory rather than a sorting preference.
        - Workspace/sidebar/tab color requests are workspace_color, not normal_chat and not a sorting request.
        - Requests that map color names or hex values to workspace groups/categories are workspace_color, even when the wording does not explicitly say "workspace color".
        - Follow-ups claiming workspace color writes are unavailable, read-only, or need permission are workspace_color when recentConversation is about reading or setting workspace colors.
        - Use routeAdjustment when the current turn needs prompt/tool affordances that are not fully represented by the primary intent, especially short follow-ups inside an existing conversation.
        - Use routeAdjustment modes dynamically: append when adding missing affordances, replace when the latest turn switches or narrows the active task, and removePromptFragments/removeAllowedTools when stale prompt guidance or tools should be subtracted.
        - routeAdjustment.promptFragments may only use: normal_chat, context, workspace_color, sort, sort_color_group, explain_order, sort_memory, sprite_memory, undo.
        - routeAdjustment.allowedTools may only use cmux sprite MCP tool names from availableMCPTools.
        - If the latest input is read-only after a write-capable turn, replace allowedTools with a read-only list or remove the stale write tools.
        - If intent or any step is workspace_color, never replace allowedTools with an empty list. Use workspace_color_get for read-only color turns, and include the relevant workspace_color_* tool for changes.
        - Only request write tools such as workspace_color_set, workspace_color_clear, sort_apply, sort_undo, suggestion_accept, suggestion_dismiss, memory_write_candidate, memory_forget, sprite_memory_write, or sprite_memory_forget when the latest input clearly asks to mutate state.
        """
    }

    private static func semanticUserPrompt(
        text: String,
        externalGoal: Bool,
        conversationContext: [String],
        toolCatalog: [[String: Any]]
    ) -> String {
        let payload: [String: Any] = [
            "input": text,
            "externalGoal": externalGoal,
            "recentConversation": conversationContext,
            "surface": "cmux_sprite_assistant",
            "availableMCPTools": toolCatalog,
            "routeCatalog": semanticRouteCatalog(),
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        let json = String(data: data, encoding: .utf8) ?? #"{"input":""}"#
        return "Classify this user input:\n\(json)"
    }

    private struct SemanticMCPServerSpec {
        let name: String
        let command: String
        let args: [String]
        let env: [String: String]
        let cwd: String?
    }

    private static let semanticMCPToolDiscoveryTimeoutNanoseconds: UInt64 = 2_000_000_000

    private actor SemanticMCPToolDiscoverySession {
        private let server: SemanticMCPServerSpec
        private var process: Process?
        private var stdin: Pipe?
        private var stdout: Pipe?
        private var stderr: Pipe?
        private var client: MCP.Client?

        init(server: SemanticMCPServerSpec) {
            self.server = server
        }

        func discover() async throws -> [MCP.Tool] {
            let process = Process()
            if server.command.contains("/") {
                process.executableURL = URL(fileURLWithPath: server.command)
                process.arguments = server.args
            } else {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = [server.command] + server.args
            }
            if let cwd = server.cwd, !cwd.isEmpty {
                process.currentDirectoryURL = URL(fileURLWithPath: (cwd as NSString).expandingTildeInPath, isDirectory: true)
            }
            process.environment = ProcessInfo.processInfo.environment.merging(server.env) { _, new in new }

            let stdin = Pipe()
            let stdout = Pipe()
            let stderr = Pipe()
            stderr.fileHandleForReading.readabilityHandler = { handle in
                _ = handle.availableData
            }
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr

            self.process = process
            self.stdin = stdin
            self.stdout = stdout
            self.stderr = stderr

            try process.run()

            let client = MCP.Client(
                name: "cmux-sprite-semantic-router",
                version: "0.1.0"
            )
            self.client = client
            let transport = StdioTransport(
                input: .init(rawValue: stdout.fileHandleForReading.fileDescriptor),
                output: .init(rawValue: stdin.fileHandleForWriting.fileDescriptor)
            )

            do {
                _ = try await client.connect(transport: transport)
                let tools = try await listAllTools(client: client)
                await client.disconnect()
                cleanup()
                return tools
            } catch {
                await client.disconnect()
                cleanup()
                throw error
            }
        }

        func cancel() async {
            if let client {
                await client.disconnect()
            }
            cleanup()
        }

        private func listAllTools(client: MCP.Client) async throws -> [MCP.Tool] {
            var tools: [MCP.Tool] = []
            var cursor: String?
            repeat {
                let page = try await client.listTools(cursor: cursor)
                tools.append(contentsOf: page.tools)
                cursor = page.nextCursor
            } while cursor != nil
            return tools
        }

        private func cleanup() {
            stderr?.fileHandleForReading.readabilityHandler = nil
            try? stdin?.fileHandleForWriting.close()
            try? stdout?.fileHandleForReading.close()
            try? stderr?.fileHandleForReading.close()
            if let process, process.isRunning {
                process.terminate()
            }
            client = nil
            process = nil
            stdin = nil
            stdout = nil
            stderr = nil
        }
    }

    private static func semanticMCPToolCatalog(
        workspaceDirectory: String?,
        includeBuiltIn: Bool = true,
        includeExternal: Bool = false,
        externalServersOverride: [String: Any]? = nil,
        debugSession: SortAssistantDebugSession? = nil
    ) async -> [[String: Any]] {
        let servers = semanticMCPServerSpecs(
            workspaceDirectory: workspaceDirectory,
            includeBuiltIn: includeBuiltIn,
            includeExternal: includeExternal,
            externalServersOverride: externalServersOverride
        )
        var catalog: [[String: Any]] = []
        for server in servers {
            let tools = await semanticMCPTools(server: server)
            debugSession?.log("router.mcp.toolsList server=\(server.name) tools=\(tools.count)")
            catalog.append(contentsOf: tools)
        }
        return catalog
    }

    private static func semanticMCPServerSpecs(
        workspaceDirectory: String?,
        includeBuiltIn: Bool,
        includeExternal: Bool,
        externalServersOverride: [String: Any]?
    ) -> [SemanticMCPServerSpec] {
        var specs: [SemanticMCPServerSpec] = []
        if includeBuiltIn {
            var env: [String: String] = [
                "CMUX_SOCKET_PATH": SocketControlSettings.socketPath(),
                "CMUX_SPRITE_ALLOWED_TOOLS": sortAssistantProductionAssistantTools
                    .sorted()
                    .joined(separator: ","),
            ]
#if DEBUG
            if let debugLogPath = debugLogPathForMCPDiscovery() {
                env["CMUX_DEBUG_LOG"] = debugLogPath
                env["CMUX_SPRITE_MCP_DEBUG"] = "1"
            }
#endif
            if let workspaceDirectory, !workspaceDirectory.isEmpty {
                env["CMUX_WORKSPACE_DIRECTORY"] = workspaceDirectory
            }
            specs.append(SemanticMCPServerSpec(
                name: "cmux_sprite",
                command: cmuxCLIPathForMCP(),
                args: [
                    "--socket",
                    SocketControlSettings.socketPath(),
                    "mcp",
                    "sprite-assistant",
                ],
                env: env,
                cwd: nil
            ))
        }

        let externalServers = includeExternal
            ? (externalServersOverride ?? SpriteAssistantConfig.externalMCPServers(workspaceDirectory: workspaceDirectory))
            : [:]
        let externalSpecs = externalServers.keys.sorted().compactMap { name -> SemanticMCPServerSpec? in
            guard let object = externalServers[name] as? [String: Any],
                  let command = mcpString(object["command"]) else {
                return nil
            }
            return SemanticMCPServerSpec(
                name: name,
                command: command,
                args: mcpStringArray(object["args"]),
                env: mcpStringDictionary(object["env"]),
                cwd: mcpString(object["cwd"] ?? object["workingDirectory"] ?? object["working_directory"])
            )
        }
        specs.append(contentsOf: externalSpecs)
        return specs
    }

    private static func semanticMCPTools(server: SemanticMCPServerSpec) async -> [[String: Any]] {
        let session = SemanticMCPToolDiscoverySession(server: server)
        let discovery = Task {
            try await session.discover()
        }
        let timeout = Task {
            try? await Task.sleep(nanoseconds: semanticMCPToolDiscoveryTimeoutNanoseconds)
            discovery.cancel()
            await session.cancel()
        }

        do {
            let tools = try await discovery.value
            timeout.cancel()
            await session.cancel()
            return tools.compactMap { tool in
                semanticMCPToolPayload(tool, serverName: server.name)
            }
        } catch {
            timeout.cancel()
            await session.cancel()
            return []
        }
    }

    private static func semanticMCPToolPayload(_ tool: MCP.Tool, serverName: String) -> [String: Any]? {
        guard let name = mcpString(tool.name) else {
            return nil
        }
        var payload: [String: Any] = [
            "server": serverName,
            "name": name,
            "qualifiedName": "mcp__\(serverName)__\(name)",
        ]
        if let title = mcpString(tool.title) {
            payload["title"] = title
        }
        if let description = mcpString(tool.description) {
            payload["description"] = description
        }
        if let inputSchema = mcpEncodedJSONObject(tool.inputSchema) {
            payload["inputSchema"] = inputSchema
        }
        if let outputSchema = tool.outputSchema.flatMap(mcpEncodedJSONObject) {
            payload["outputSchema"] = outputSchema
        }
        if let annotations = mcpEncodedJSONObject(tool.annotations) as? [String: Any],
           !annotations.isEmpty {
            payload["annotations"] = annotations
        }
        if serverName == "cmux_sprite" {
            payload["mutating"] = sortAssistantMutatingInternalTools.contains(name)
        }
        return payload
    }

    private static func mcpEncodedJSONObject<T: Encodable>(_ value: T) -> Any? {
        guard let data = try? JSONEncoder().encode(value) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func mcpString(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let value = value as? CustomStringConvertible {
            let trimmed = value.description.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private static func mcpStringArray(_ value: Any?) -> [String] {
        if let strings = value as? [String] {
            return strings.compactMap(mcpString)
        }
        if let values = value as? [Any] {
            return values.compactMap(mcpString)
        }
        return mcpString(value).map { [$0] } ?? []
    }

    private static func mcpStringDictionary(_ value: Any?) -> [String: String] {
        guard let object = value as? [String: Any] else {
            return [:]
        }
        return object.reduce(into: [:]) { partial, pair in
            if let value = mcpString(pair.value) {
                partial[pair.key] = value
            }
        }
    }

    private static func cmuxCLIPathForMCP() -> String {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["CMUX_DIGEST_CMUX"],
           FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        if let resources = Bundle.main.resourceURL {
            let bundled = resources.appendingPathComponent("bin/cmux").path
            if FileManager.default.isExecutableFile(atPath: bundled) {
                return bundled
            }
        }
        if FileManager.default.isExecutableFile(atPath: "/tmp/cmux-cli") {
            return "/tmp/cmux-cli"
        }
        return "cmux"
    }

#if DEBUG
    private static func debugLogPathForMCPDiscovery() -> String? {
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

    private static func semanticRouteCatalog() -> [[String: Any]] {
        let actionRouter = SortAssistantActionRouter()
        return semanticIntentOrder.map { intent in
            let route = actionRouter.route(for: intent)
            return [
                "intent": intent.rawValue,
                "mode": route.mode.rawValue,
                "needsConfirmation": route.needsConfirmation,
                "allowedTools": route.allowedTools,
                "memoryWritePolicy": route.memoryWritePolicy.rawValue,
            ] as [String: Any]
        }
    }

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
            "/usr/local/bin/claude"
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

    private static func runClaudeCode(
        executable: String,
        arguments: [String],
        timeoutSeconds: TimeInterval
    ) throws -> ProcessOutput {
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

        do {
            try process.run()
        } catch {
            timeout.cancel()
            throw error
        }
        process.waitUntilExit()
        timeout.cancel()

        if timeoutFlag.didTimeOut {
            throw SortAssistantSemanticRouterRuntimeError(issue: SortAssistantSemanticRouterIssue(
                stage: .claude,
                code: "timed_out",
                timeoutSeconds: Int(timeoutSeconds.rounded())
            ))
        }

        return ProcessOutput(
            stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            status: process.terminationStatus
        )
    }

    private static func parseDecision(from content: String) throws -> SortAssistantIntentDecision {
        guard let json = firstJSONObject(in: content),
              let data = json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawIntent = object["intent"] as? String,
              let intent = SortAssistantIntent(rawValue: rawIntent.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw NSError(domain: "SortAssistantIntentRouter", code: 2)
        }
        let confidence = doubleValue(object["confidence"]) ?? 0
        let reason = object["reason"] as? String
        let parsedSortRoute = sortRouteValue(
            object["sortRoute"] ?? object["sort_route"] ?? object["route"] ?? object["sort_path"]
        )
        let sortRoute = intent.isSortRouted ? parsedSortRoute : nil
        let routeSteps = routeStepsValue(
            object["steps"] ?? object["intents"] ?? object["routes"] ?? object["taskSteps"] ?? object["task_steps"]
        )
        let routeAdjustment = routeAdjustmentValue(object)
        return SortAssistantIntentDecision(
            intent: intent,
            confidence: min(max(confidence, 0), 1),
            reason: reason,
            sortRoute: sortRoute,
            steps: routeSteps.isEmpty ? nil : routeSteps,
            routeAdjustment: routeAdjustment
        )
    }

    static func parseDecisionForTesting(_ content: String) throws -> SortAssistantIntentDecision {
        try parseDecision(from: content)
    }

    static func semanticMCPToolCatalogForTesting(externalServers: [String: Any]) async -> [[String: Any]] {
        await semanticMCPToolCatalog(
            workspaceDirectory: nil,
            includeBuiltIn: false,
            includeExternal: true,
            externalServersOverride: externalServers
        )
    }

    static func semanticMCPServerNamesForTesting(externalServers: [String: Any]) -> [String] {
        semanticMCPServerSpecs(
            workspaceDirectory: nil,
            includeBuiltIn: true,
            includeExternal: false,
            externalServersOverride: externalServers
        )
        .map(\.name)
    }

    private static func routeAdjustmentValue(_ object: [String: Any]) -> SortAssistantRouteAdjustment {
        let nestedObject = firstRouteAdjustmentObject(in: object)
        let promptModeKeys = [
            "promptFragmentMode", "prompt_fragment_mode",
            "promptFragmentsMode", "prompt_fragments_mode",
            "fragmentMode", "fragment_mode",
            "promptMode", "prompt_mode",
        ]
        let allowedModeKeys = [
            "allowedToolsMode", "allowed_tools_mode",
            "allowToolsMode", "allow_tools_mode",
            "toolsMode", "tools_mode",
        ]
        let promptFragmentKeys = ["promptFragments", "prompt_fragments", "fragments"]
        let removePromptFragmentKeys = [
            "removePromptFragments", "remove_prompt_fragments",
            "removedPromptFragments", "removed_prompt_fragments",
            "withoutPromptFragments", "without_prompt_fragments",
            "dropPromptFragments", "drop_prompt_fragments",
            "removeFragments", "remove_fragments",
            "withoutFragments", "without_fragments",
        ]
        let allowedToolKeys = ["allowedTools", "allowed_tools", "allowTools", "allow_tools", "tools"]
        let removeAllowedToolKeys = [
            "removeAllowedTools", "remove_allowed_tools",
            "removedAllowedTools", "removed_allowed_tools",
            "withoutAllowedTools", "without_allowed_tools",
            "dropAllowedTools", "drop_allowed_tools",
            "withoutTools", "without_tools",
            "dropTools", "drop_tools",
            "removeTools", "remove_tools",
            "disallowedTools", "disallowed_tools",
        ]

        var promptFragmentMode = routeAdjustmentModeValue(
            firstValue(in: object, keys: promptModeKeys)
        ) ?? .append
        var allowedToolsMode = routeAdjustmentModeValue(
            firstValue(in: object, keys: allowedModeKeys)
        ) ?? .append
        var promptFragments = stringArrayValue(firstValue(in: object, keys: promptFragmentKeys))
        var removedPromptFragments = stringArrayValue(firstValue(in: object, keys: removePromptFragmentKeys))
        var allowedTools = stringArrayValue(firstValue(in: object, keys: allowedToolKeys))
        var removedAllowedTools = stringArrayValue(firstValue(in: object, keys: removeAllowedToolKeys))

        if let nestedObject {
            let nestedSharedMode = routeAdjustmentModeValue(nestedObject["mode"])
            promptFragmentMode = routeAdjustmentModeValue(
                firstValue(in: nestedObject, keys: promptModeKeys)
            ) ?? nestedSharedMode ?? promptFragmentMode
            allowedToolsMode = routeAdjustmentModeValue(
                firstValue(in: nestedObject, keys: allowedModeKeys)
            ) ?? nestedSharedMode ?? allowedToolsMode
            promptFragments += stringArrayValue(firstValue(in: nestedObject, keys: promptFragmentKeys))
            removedPromptFragments += stringArrayValue(firstValue(in: nestedObject, keys: removePromptFragmentKeys))
            allowedTools += stringArrayValue(firstValue(in: nestedObject, keys: allowedToolKeys))
            removedAllowedTools += stringArrayValue(firstValue(in: nestedObject, keys: removeAllowedToolKeys))
        }

        return SortAssistantRouteAdjustment(
            promptFragmentMode: promptFragmentMode,
            promptFragments: promptFragments,
            removedPromptFragments: removedPromptFragments,
            allowedToolsMode: allowedToolsMode,
            allowedTools: allowedTools,
            removedAllowedTools: removedAllowedTools
        )
    }

    private static func firstRouteAdjustmentObject(in object: [String: Any]) -> [String: Any]? {
        firstValue(
            in: object,
            keys: ["routeAdjustment", "route_adjustment", "mcp", "runtime", "execution"]
        ) as? [String: Any]
    }

    private static func firstValue(in object: [String: Any], keys: [String]) -> Any? {
        for key in keys {
            if let value = object[key] {
                return value
            }
        }
        return nil
    }

    private static func routeAdjustmentModeValue(_ value: Any?) -> SortAssistantRouteAdjustmentMode? {
        guard let raw = stringValue(value) else { return nil }
        switch raw {
        case "append", "add", "merge", "extend":
            return .append
        case "replace", "set", "only", "limit", "restrict":
            return .replace
        default:
            return nil
        }
    }

    private static func routeStepsValue(_ value: Any?) -> [SortAssistantRouteStep] {
        if let objects = value as? [[String: Any]] {
            return objects.compactMap(routeStepValue)
        }
        if let values = value as? [Any] {
            return values.compactMap { value in
                if let object = value as? [String: Any] {
                    return routeStepValue(object)
                }
                guard let rawIntent = stringValue(value),
                      let intent = SortAssistantIntent(rawValue: rawIntent) else {
                    return nil
                }
                return SortAssistantRouteStep(intent: intent)
            }
        }
        return []
    }

    private static func routeStepValue(_ object: [String: Any]) -> SortAssistantRouteStep? {
        guard let rawIntent = stringValue(
            object["intent"] ?? object["name"] ?? object["route"] ?? object["type"]
        ),
              let intent = SortAssistantIntent(rawValue: rawIntent) else {
            return nil
        }
        return SortAssistantRouteStep(
            intent: intent,
            sortRoute: sortRouteValue(object["sortRoute"] ?? object["sort_route"] ?? object["sortPath"] ?? object["sort_path"])
        )
    }

    private static func sortRouteValue(_ value: Any?) -> SortAssistantSortRoute? {
        guard let raw = value as? String else { return nil }
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
        switch normalized {
        case "color_group", "group_by_color", "color", "colors", "colour", "colours":
            return .colorGroup
        default:
            return nil
        }
    }

    private static func firstJSONObject(in content: String) -> String? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"), trimmed.hasSuffix("}") {
            return trimmed
        }
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"),
              start <= end else {
            return nil
        }
        return String(trimmed[start...end])
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String {
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func stringArrayValue(_ value: Any?) -> [String] {
        if let values = value as? [Any] {
            return values.compactMap(stringValue)
        }
        return stringValue(value).map { [$0] } ?? []
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        let raw: String?
        if let value = value as? String {
            raw = value
        } else if let value = value as? CustomStringConvertible {
            raw = value.description
        } else {
            raw = nil
        }
        let normalized = raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_") ?? ""
        return normalized.isEmpty ? nil : normalized
    }

    private static func slashCommandName(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return "" }
        return trimmed
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .first
            .map { String($0).lowercased() } ?? ""
    }
}
