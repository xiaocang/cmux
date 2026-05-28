import Foundation

struct SortAssistantMCPRunResult: Sendable {
    struct Card: Sendable {
        let title: String
        let dimensionLabel: String?
        let changes: [String]
        let rationale: String?
        let patchId: UUID?
        let mode: SortAssistantResultMode
        let actions: [SortAssistantResultAction]
    }

    let message: String
    let card: Card?
    let choicePrompt: SortAssistantChoicePrompt?

    init(
        message: String,
        card: Card?,
        choicePrompt: SortAssistantChoicePrompt? = nil
    ) {
        self.message = message
        self.card = card
        self.choicePrompt = choicePrompt
    }

    static func parse(_ raw: String) throws -> SortAssistantMCPRunResult {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SortAssistantMCPRunResultParseError(raw: raw)
        }
        guard let json = firstJSONObject(in: raw),
              let data = json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return SortAssistantMCPRunResult(message: trimmed, card: nil)
        }

        if let nested = Self.string(object["result"]),
           nested != trimmed,
           isAbsent(object["message"]),
           isAbsent(object["assistant_message"]),
           isAbsent(object["card"]),
           isAbsent(object["choicePrompt"]),
           isAbsent(object["choice_prompt"]),
           isAbsent(object["clarification"]) {
            return try parse(nested)
        }

        let message = Self.string(object["message"])
            ?? Self.string(object["assistant_message"])
            ?? Self.string(object["text"])
            ?? Self.contentText(object["content"])
            ?? ""
        let cardObject = object["card"] as? [String: Any]
            ?? object["result"] as? [String: Any]
        let card = cardObject.flatMap(Self.card)
        let promptObject = object["choicePrompt"] as? [String: Any]
            ?? object["choice_prompt"] as? [String: Any]
            ?? object["clarification"] as? [String: Any]
            ?? object["choice"] as? [String: Any]
        let choicePrompt = promptObject.flatMap(Self.choicePrompt)
        if message.isEmpty, card == nil, choicePrompt == nil {
            throw SortAssistantMCPRunResultParseError(raw: raw)
        }
        return SortAssistantMCPRunResult(message: message, card: card, choicePrompt: choicePrompt)
    }

    private static func card(_ object: [String: Any]) -> Card? {
        guard let title = string(object["title"]) else { return nil }
        let mode: SortAssistantResultMode = {
            switch string(object["mode"])?.lowercased() {
            case "applied", "apply": return .applied
            default: return .preview
            }
        }()
        let patchId = string(object["patchId"] ?? object["patch_id"]).flatMap(UUID.init(uuidString:))
        return Card(
            title: title,
            dimensionLabel: string(object["dimensionLabel"] ?? object["dimension_label"]),
            changes: stringArray(object["changes"]),
            rationale: string(object["rationale"] ?? object["markdown"]),
            patchId: patchId,
            mode: mode,
            actions: resultActions(object["actions"] ?? object["result_actions"] ?? object["cmux_result_actions"])
        )
    }

    private static func choicePrompt(_ object: [String: Any]) -> SortAssistantChoicePrompt? {
        let title = string(object["title"])
            ?? string(object["question"])
            ?? string(object["label"])
        let message = string(object["message"])
            ?? string(object["body"])
            ?? string(object["description"])
        let options = choiceOptions(object["options"] ?? object["choices"])
        let questions = choiceQuestions(object["questions"] ?? object["steps"])
        guard !questions.isEmpty || (title != nil && !options.isEmpty) else { return nil }
        let followUpIntent = string(object["intent"] ?? object["followUpIntent"] ?? object["follow_up_intent"])
            .flatMap(SortAssistantIntent.init(rawValue:))
        let routeSteps = routeSteps(
            object["routeSteps"]
                ?? object["route_steps"]
                ?? (object["taskPlan"] as? [String: Any])?["steps"]
                ?? (object["task_plan"] as? [String: Any])?["steps"]
        )
        let forceApply = bool(object["forceApply"] ?? object["force_apply"]) ?? false
        return SortAssistantChoicePrompt(
            title: title ?? String(localized: "sortAssistant.choice.title", defaultValue: "Choose details"),
            message: message,
            options: options.isEmpty ? (questions.first?.options ?? []) : options,
            questions: questions.isEmpty ? nil : questions,
            followUpIntent: followUpIntent,
            routeSteps: routeSteps.isEmpty ? nil : routeSteps,
            forceApply: forceApply
        )
    }

    private static func routeSteps(_ value: Any?) -> [SortAssistantRouteStep] {
        if let objects = value as? [[String: Any]] {
            return objects.compactMap(routeStep)
        }
        if let values = value as? [Any] {
            return values.compactMap { value in
                if let object = value as? [String: Any] {
                    return routeStep(object)
                }
                guard let rawIntent = normalizedString(value),
                      let intent = SortAssistantIntent(rawValue: rawIntent) else {
                    return nil
                }
                return SortAssistantRouteStep(intent: intent)
            }
        }
        return []
    }

    private static func routeStep(_ object: [String: Any]) -> SortAssistantRouteStep? {
        guard let rawIntent = normalizedString(
            object["intent"] ?? object["name"] ?? object["route"] ?? object["type"]
        ),
              let intent = SortAssistantIntent(rawValue: rawIntent) else {
            return nil
        }
        return SortAssistantRouteStep(
            intent: intent,
            sortRoute: sortRoute(object["sortRoute"] ?? object["sort_route"] ?? object["sortPath"] ?? object["sort_path"])
        )
    }

    private static func sortRoute(_ value: Any?) -> SortAssistantSortRoute? {
        guard let normalized = normalizedString(value) else { return nil }
        switch normalized {
        case "color_group", "group_by_color", "color", "colors", "colour", "colours":
            return .colorGroup
        default:
            return nil
        }
    }

    private static func choiceQuestions(_ value: Any?) -> [SortAssistantChoicePrompt.Question] {
        let parsed: [SortAssistantChoicePrompt.Question]
        if let list = value as? [[String: Any]] {
            parsed = list.enumerated().compactMap { index, object in
                choiceQuestion(object, fallbackIndex: index)
            }
        } else if let list = value as? [Any] {
            parsed = list.enumerated().compactMap { index, value in
                guard let object = value as? [String: Any] else { return nil }
                return choiceQuestion(object, fallbackIndex: index)
            }
        } else {
            parsed = []
        }

        var seen: Set<String> = []
        return parsed.filter { question in
            seen.insert(question.id).inserted
        }
    }

    private static func choiceQuestion(
        _ object: [String: Any],
        fallbackIndex: Int
    ) -> SortAssistantChoicePrompt.Question? {
        guard let title = string(object["title"] ?? object["question"] ?? object["label"]) else {
            return nil
        }
        let options = choiceOptions(object["options"] ?? object["choices"])
        guard !options.isEmpty else { return nil }
        return SortAssistantChoicePrompt.Question(
            id: string(object["id"]) ?? optionId(title, fallbackIndex: fallbackIndex),
            title: title,
            message: string(object["message"] ?? object["body"] ?? object["description"]),
            options: options
        )
    }

    private static func choiceOptions(_ value: Any?) -> [SortAssistantChoicePrompt.Option] {
        let parsed: [SortAssistantChoicePrompt.Option]
        if let list = value as? [[String: Any]] {
            parsed = list.enumerated().compactMap { index, object in
                choiceOption(object, fallbackIndex: index)
            }
        } else if let list = value as? [Any] {
            parsed = list.enumerated().compactMap { index, value in
                if let object = value as? [String: Any] {
                    return choiceOption(object, fallbackIndex: index)
                }
                guard let title = string(value) else { return nil }
                return SortAssistantChoicePrompt.Option(
                    id: optionId(title, fallbackIndex: index),
                    title: title,
                    subtitle: nil,
                    goal: title
                )
            }
        } else {
            parsed = []
        }

        var seen: Set<String> = []
        return parsed.filter { option in
            seen.insert(option.id).inserted
        }
    }

    private static func choiceOption(
        _ object: [String: Any],
        fallbackIndex: Int
    ) -> SortAssistantChoicePrompt.Option? {
        guard let title = string(object["title"] ?? object["label"] ?? object["name"]) else {
            return nil
        }
        let subtitle = string(object["subtitle"] ?? object["description"] ?? object["detail"])
        let goal = string(object["goal"] ?? object["prompt"] ?? object["value"])
            ?? [title, subtitle].compactMap { $0 }.joined(separator: ": ")
        return SortAssistantChoicePrompt.Option(
            id: string(object["id"]) ?? optionId(title, fallbackIndex: fallbackIndex),
            title: title,
            subtitle: subtitle,
            goal: goal
        )
    }

    private static func optionId(_ title: String, fallbackIndex: Int) -> String {
        let normalized = title
            .lowercased()
            .unicodeScalars
            .map { scalar -> Character in
                CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
            }
            .reduce(into: "") { partial, character in
                if character == "-", partial.last == "-" {
                    return
                }
                partial.append(character)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return normalized.isEmpty ? "choice-\(fallbackIndex + 1)" : normalized
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

    private static func string(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        let raw: String?
        if let value = value as? String {
            raw = value
        } else if let value = value as? CustomStringConvertible {
            raw = value.description
        } else {
            raw = nil
        }
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedString(_ value: Any?) -> String? {
        string(value)?
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
    }

    private static func isAbsent(_ value: Any?) -> Bool {
        value == nil || value is NSNull
    }

    private static func stringArray(_ value: Any?) -> [String] {
        if let list = value as? [String] {
            return list
        }
        if let list = value as? [Any] {
            return list.compactMap(string)
        }
        return []
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool {
            return value
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let string = string(value)?.lowercased() {
            switch string {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        }
        return nil
    }

    private static func contentText(_ value: Any?) -> String? {
        if let list = value as? [[String: Any]] {
            let text = list
                .compactMap { item in
                    string(item["text"] ?? item["content"] ?? item["message"])
                }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        if let list = value as? [Any] {
            let text = list
                .compactMap { item -> String? in
                    if let object = item as? [String: Any] {
                        return string(object["text"] ?? object["content"] ?? object["message"])
                    }
                    return string(item)
                }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        return string(value)
    }

    private static func resultActions(_ value: Any?) -> [SortAssistantResultAction] {
        let raw: [String]
        if let list = value as? [String] {
            raw = list
        } else if let list = value as? [Any] {
            raw = list.compactMap(string)
        } else if let string = string(value) {
            raw = string
                .trimmingCharacters(in: CharacterSet(charactersIn: " []"))
                .split { $0 == "," || $0 == " " || $0 == "\t" }
                .map { String($0) }
        } else {
            raw = []
        }
        var seen: Set<SortAssistantResultAction> = []
        return raw.compactMap { token in
            SortAssistantResultAction(rawValue: token.trimmingCharacters(in: .whitespacesAndNewlines))
        }.filter { action in
            seen.insert(action).inserted
        }
    }
}

struct SortAssistantMCPRunResultParseError: LocalizedError, Sendable {
    let raw: String

    var errorDescription: String? {
        let trimmed = raw
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let detail: String
        if trimmed.isEmpty {
            detail = String(localized: "sortAssistant.mcp.parse.empty", defaultValue: "empty Claude response")
        } else {
            detail = Self.shortened(trimmed)
        }
        return String(
            localized: "sortAssistant.mcp.parse.failed",
            defaultValue: "Could not parse sprite MCP response: \(detail)"
        )
    }

    private static func shortened(_ text: String) -> String {
        guard text.count > 420 else { return text }
        let end = text.index(text.startIndex, offsetBy: 420)
        return String(text[..<end]) + "..."
    }
}

struct SortAssistantMCPRequest: Sendable {
    let goal: String
    let intent: SortAssistantIntent
    let routeSteps: [SortAssistantRouteStep]
    let route: SortAssistantActionRoute
    let routeAdjustment: SortAssistantRouteAdjustment
    let visibleScopeSignature: String
    let requiresMCPScopeRefresh: Bool
    let conversationContext: [String]
    let includeConversationContext: Bool
    let explicitSlashCommand: Bool
    let workspaceId: String?
    let workspaceDirectory: String?
    let socketPath: String
    let cmuxCLIPath: String
    let claudeSessionId: UUID?
    let claudeSessionReused: Bool
    let debugSession: SortAssistantDebugSession?

    var claudeSessionReason: String {
        claudeSessionReused ? "conversation_history" : "conversation_start"
    }

    var scopeRefreshReason: String {
        requiresMCPScopeRefresh ? (claudeSessionReused ? "scope_changed" : "conversation_start") : "scope_reused"
    }
}

struct SortAssistantMCPProgressUpdate: Sendable {
    let message: String
}

typealias SortAssistantMCPProgressHandler = @Sendable (SortAssistantMCPProgressUpdate) -> Void

enum SortAssistantClaudePromptProfile: String, Sendable {
    case semanticRouterBootstrap = "semantic_router_bootstrap"
    case conversation
    case general
    case routedFragments = "routed_fragments"
    case workspaceColorCompact = "workspace_color_compact"
}

struct SortAssistantMCPClientProcessError: LocalizedError, Sendable {
    let status: Int32
    let stdout: String
    let stderr: String

    var errorDescription: String? {
        let detail = [stderr, stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
            ?? String(localized: "sortAssistant.mcp.claudeNoDetails", defaultValue: "Claude Code exited without details.")
        return String(
            localized: "sortAssistant.mcp.claudeExited",
            defaultValue: "Claude Code exited \(status): \(Self.shortened(detail))"
        )
    }

    private static func shortened(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\n", with: " ")
        guard normalized.count > 420 else { return normalized }
        let end = normalized.index(normalized.startIndex, offsetBy: 420)
        return String(normalized[..<end]) + "..."
    }
}

struct SortAssistantMCPClientTimeoutError: LocalizedError, Sendable {
    let timeoutSeconds: TimeInterval

    var errorDescription: String? {
        String(
            format: String(
                localized: "sortAssistant.mcp.timedOut",
                defaultValue: "Sprite MCP request timed out after %d seconds."
            ),
            Int(timeoutSeconds.rounded())
        )
    }
}
