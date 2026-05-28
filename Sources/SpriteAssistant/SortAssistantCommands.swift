import Foundation

struct SortAssistantMonitorCommand: Equatable {
    enum Action: Equatable {
        case add(condition: String, interval: TimeInterval)
        case list
        case stop(selector: String?)
    }

    let action: Action

    static let defaultInterval: TimeInterval = 60
    static let minimumInterval: TimeInterval = 5
    static let maximumInterval: TimeInterval = 86_400

    static func parse(argument: String) -> SortAssistantMonitorCommand {
        var remaining = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = remaining.lowercased()
        if lower == "list" || lower == "ls" || lower == "status" {
            return SortAssistantMonitorCommand(action: .list)
        }
        if lower == "stop" || lower == "cancel" || lower == "clear" {
            return SortAssistantMonitorCommand(action: .stop(selector: nil))
        }
        for prefix in ["stop ", "cancel ", "clear ", "remove "] {
            if lower.hasPrefix(prefix) {
                let selector = String(remaining.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return SortAssistantMonitorCommand(action: .stop(selector: selector.isEmpty ? nil : selector))
            }
        }

        var interval = defaultInterval
        if let parsed = parseIntervalOption(from: remaining) {
            interval = parsed.interval
            remaining = parsed.remaining
        }
        return SortAssistantMonitorCommand(
            action: .add(
                condition: remaining.trimmingCharacters(in: .whitespacesAndNewlines),
                interval: clampedInterval(interval)
            )
        )
    }

    private static func parseIntervalOption(from argument: String) -> (interval: TimeInterval, remaining: String)? {
        let tokens = argument.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return nil }
        if tokens.count >= 2,
           ["every", "interval"].contains(tokens[0].lowercased()),
           let interval = parseDuration(tokens[1]) {
            return (interval, tokens.dropFirst(2).joined(separator: " "))
        }
        if tokens.count >= 2,
           ["--interval", "-i"].contains(tokens[0].lowercased()),
           let interval = parseDuration(tokens[1]) {
            return (interval, tokens.dropFirst(2).joined(separator: " "))
        }
        if let first = tokens.first,
           first.lowercased().hasPrefix("--interval="),
           let interval = parseDuration(String(first.dropFirst("--interval=".count))) {
            return (interval, tokens.dropFirst().joined(separator: " "))
        }
        if tokens.count >= 2,
           let interval = parseDuration(tokens[0]) {
            return (interval, tokens.dropFirst().joined(separator: " "))
        }
        return nil
    }

    private static func parseDuration(_ raw: String) -> TimeInterval? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        let numberText = normalized
            .trimmingCharacters(in: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz秒分时小时"))
        guard let value = TimeInterval(numberText), value.isFinite, value > 0 else { return nil }
        if normalized.hasSuffix("ms") {
            return value / 1000
        }
        if normalized.hasSuffix("m") || normalized.hasSuffix("min") || normalized.hasSuffix("分钟") || normalized.hasSuffix("分") {
            return value * 60
        }
        if normalized.hasSuffix("h") || normalized.hasSuffix("hr") || normalized.hasSuffix("hour") || normalized.hasSuffix("小时") || normalized.hasSuffix("时") {
            return value * 3600
        }
        return value
    }

    private static func clampedInterval(_ interval: TimeInterval) -> TimeInterval {
        min(max(interval, minimumInterval), maximumInterval)
    }
}

struct SortAssistantSlashCommand: Equatable {
    enum Operation: Equatable {
        case clearSession
        case help
        case askContext(String)
        case undoSort
        case explainCurrentOrder(String)
        case proposeSort(String)
        case applySort(String)
        case listSortMemories
        case listSpriteMemories
        case rememberSpriteMemory(String)
        case forgetSpriteMemory(String)
        case rememberFreeSortMemory(String)
        case forgetFreeSortMemory(String)
        case monitor(SortAssistantMonitorCommand)
        case setPinned(Bool)
        case setLocked(Bool)
        case selectWorkspace
    }

    let name: String
    let argument: String
    let operation: Operation

    static func parse(_ text: String) -> SortAssistantSlashCommand? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let nameEnd = trimmed.firstIndex(where: { $0.isWhitespace }) ?? trimmed.endIndex
        let name = String(trimmed[..<nameEnd]).lowercased()
        let argument = String(trimmed[nameEnd...])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        switch name {
        case "/clear", "/new":
            return SortAssistantSlashCommand(name: name, argument: argument, operation: .clearSession)
        case "/help", "/?":
            return SortAssistantSlashCommand(name: name, argument: argument, operation: .help)
        case "/repo", "/git":
            let goal = argument.isEmpty
                ? String(localized: "sortAssistant.slash.repo.defaultGoal", defaultValue: "Tell me the current repository context.")
                : argument
            return SortAssistantSlashCommand(name: name, argument: argument, operation: .askContext(goal))
        case "/context", "/ctx":
            let goal = argument.isEmpty
                ? String(localized: "sortAssistant.slash.context.defaultGoal", defaultValue: "Summarize the current workspace context.")
                : argument
            return SortAssistantSlashCommand(name: name, argument: argument, operation: .askContext(goal))
        case "/undo":
            return SortAssistantSlashCommand(
                name: name,
                argument: argument,
                operation: .undoSort
            )
        case "/explain":
            let goal = argument.isEmpty
                ? String(localized: "sortAssistant.slash.explain.defaultGoal", defaultValue: "Explain the current workspace order.")
                : argument
            return SortAssistantSlashCommand(name: name, argument: argument, operation: .explainCurrentOrder(goal))
        case "/sort":
            let goal = argument.isEmpty
                ? String(localized: "sortAssistant.slash.sort.defaultGoal", defaultValue: "Sort workspaces using the current signals.")
                : argument
            return SortAssistantSlashCommand(name: name, argument: argument, operation: .applySort(goal))
        case "/apply":
            let goal = argument.isEmpty
                ? String(localized: "sortAssistant.slash.apply.defaultGoal", defaultValue: "Apply a workspace sort using the current signals.")
                : argument
            return SortAssistantSlashCommand(name: name, argument: argument, operation: .applySort(goal))
        case "/memory", "/mem":
            return SortAssistantSlashCommand(
                name: name,
                argument: argument,
                operation: .listSortMemories
            )
        case "/remember":
            return SortAssistantSlashCommand(
                name: name,
                argument: argument,
                operation: .rememberFreeSortMemory(argument)
            )
        case "/forget":
            return SortAssistantSlashCommand(
                name: name,
                argument: argument,
                operation: .forgetFreeSortMemory(argument)
            )
        case "/memory-sprite", "/mem-sprite":
            return SortAssistantSlashCommand(
                name: name,
                argument: argument,
                operation: .listSpriteMemories
            )
        case "/remember-sprite":
            return SortAssistantSlashCommand(
                name: name,
                argument: argument,
                operation: .rememberSpriteMemory(argument)
            )
        case "/forget-sprite":
            return SortAssistantSlashCommand(
                name: name,
                argument: argument,
                operation: .forgetSpriteMemory(argument)
            )
        case "/remember-sort":
            return SortAssistantSlashCommand(
                name: name,
                argument: argument,
                operation: .rememberFreeSortMemory(argument)
            )
        case "/forget-sort":
            return SortAssistantSlashCommand(
                name: name,
                argument: argument,
                operation: .forgetFreeSortMemory(argument)
            )
        case "/monitor":
            return SortAssistantSlashCommand(
                name: name,
                argument: argument,
                operation: .monitor(SortAssistantMonitorCommand.parse(argument: argument))
            )
        case "/pin":
            return SortAssistantSlashCommand(name: name, argument: argument, operation: .setPinned(true))
        case "/unpin":
            return SortAssistantSlashCommand(name: name, argument: argument, operation: .setPinned(false))
        case "/lock":
            return SortAssistantSlashCommand(name: name, argument: argument, operation: .setLocked(true))
        case "/unlock":
            return SortAssistantSlashCommand(name: name, argument: argument, operation: .setLocked(false))
        case "/select", "/focus":
            return SortAssistantSlashCommand(name: name, argument: argument, operation: .selectWorkspace)
        default:
            return nil
        }
    }
}

struct SortAssistantSlashCommandDescriptor: Identifiable, Equatable {
    let name: String
    let aliases: [String]
    let argumentHint: String?
    let summary: String

    var id: String { name }

    var displayText: String {
        guard let argumentHint else { return name }
        return "\(name) \(argumentHint)"
    }

    var insertionText: String {
        argumentHint == nil ? name : "\(name) "
    }

    func matches(query: String) -> Bool {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedQuery.isEmpty else { return true }
        return ([name] + aliases).contains { commandName in
            commandName
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .lowercased()
                .hasPrefix(normalizedQuery)
                || commandName.lowercased().hasPrefix("/\(normalizedQuery)")
        }
    }
}

extension SortAssistantSlashCommand {
    static var descriptors: [SortAssistantSlashCommandDescriptor] {
        [
            SortAssistantSlashCommandDescriptor(
                name: "/help",
                aliases: ["/?"],
                argumentHint: nil,
                summary: String(localized: "sortAssistant.slash.help.summary", defaultValue: "Show available commands")
            ),
            SortAssistantSlashCommandDescriptor(
                name: "/clear",
                aliases: ["/new"],
                argumentHint: nil,
                summary: String(localized: "sortAssistant.slash.clear.summary", defaultValue: "Clear the current conversation")
            ),
            SortAssistantSlashCommandDescriptor(
                name: "/repo",
                aliases: ["/git"],
                argumentHint: "[@workspace]",
                summary: String(localized: "sortAssistant.slash.repo.summary", defaultValue: "Explain repository context")
            ),
            SortAssistantSlashCommandDescriptor(
                name: "/context",
                aliases: ["/ctx"],
                argumentHint: "[@workspace]",
                summary: String(localized: "sortAssistant.slash.context.summary", defaultValue: "Summarize workspace context")
            ),
            SortAssistantSlashCommandDescriptor(
                name: "/sort",
                aliases: [],
                argumentHint: "[goal]",
                summary: String(localized: "sortAssistant.slash.sort.summary", defaultValue: "Sort workspaces")
            ),
            SortAssistantSlashCommandDescriptor(
                name: "/apply",
                aliases: [],
                argumentHint: "[goal]",
                summary: String(localized: "sortAssistant.slash.apply.summary", defaultValue: "Apply a workspace sort")
            ),
            SortAssistantSlashCommandDescriptor(
                name: "/undo",
                aliases: [],
                argumentHint: nil,
                summary: String(localized: "sortAssistant.slash.undo.summary", defaultValue: "Undo the last assistant sort")
            ),
            SortAssistantSlashCommandDescriptor(
                name: "/explain",
                aliases: [],
                argumentHint: "[question]",
                summary: String(localized: "sortAssistant.slash.explain.summary", defaultValue: "Explain the current order")
            ),
            SortAssistantSlashCommandDescriptor(
                name: "/memory",
                aliases: ["/mem"],
                argumentHint: nil,
                summary: String(localized: "sortAssistant.slash.memory.summary", defaultValue: "List saved sort memories")
            ),
            SortAssistantSlashCommandDescriptor(
                name: "/remember",
                aliases: ["/remember-sort"],
                argumentHint: "<preference>",
                summary: String(localized: "sortAssistant.slash.remember.summary", defaultValue: "Propose a sort memory")
            ),
            SortAssistantSlashCommandDescriptor(
                name: "/forget",
                aliases: ["/forget-sort"],
                argumentHint: "<memory>",
                summary: String(localized: "sortAssistant.slash.forget.summary", defaultValue: "Forget sort memory")
            ),
            SortAssistantSlashCommandDescriptor(
                name: "/memory-sprite",
                aliases: ["/mem-sprite"],
                argumentHint: nil,
                summary: String(localized: "sortAssistant.slash.memorySprite.summary", defaultValue: "List sprite workspace memories")
            ),
            SortAssistantSlashCommandDescriptor(
                name: "/remember-sprite",
                aliases: [],
                argumentHint: "<memory>",
                summary: String(localized: "sortAssistant.slash.rememberSprite.summary", defaultValue: "Save sprite workspace memory")
            ),
            SortAssistantSlashCommandDescriptor(
                name: "/forget-sprite",
                aliases: [],
                argumentHint: "<memory>",
                summary: String(localized: "sortAssistant.slash.forgetSprite.summary", defaultValue: "Forget sprite workspace memory")
            ),
            SortAssistantSlashCommandDescriptor(
                name: "/monitor",
                aliases: [],
                argumentHint: "[every 30s] <status>",
                summary: String(localized: "sortAssistant.slash.monitor.summary", defaultValue: "Notify when a workspace status appears")
            ),
            SortAssistantSlashCommandDescriptor(
                name: "/pin",
                aliases: [],
                argumentHint: "[@workspace]",
                summary: String(localized: "sortAssistant.slash.pin.summary", defaultValue: "Pin a workspace")
            ),
            SortAssistantSlashCommandDescriptor(
                name: "/unpin",
                aliases: [],
                argumentHint: "[@workspace]",
                summary: String(localized: "sortAssistant.slash.unpin.summary", defaultValue: "Unpin a workspace")
            ),
            SortAssistantSlashCommandDescriptor(
                name: "/lock",
                aliases: [],
                argumentHint: "[@workspace]",
                summary: String(localized: "sortAssistant.slash.lock.summary", defaultValue: "Lock a workspace in sorting")
            ),
            SortAssistantSlashCommandDescriptor(
                name: "/unlock",
                aliases: [],
                argumentHint: "[@workspace]",
                summary: String(localized: "sortAssistant.slash.unlock.summary", defaultValue: "Unlock a workspace for sorting")
            ),
            SortAssistantSlashCommandDescriptor(
                name: "/select",
                aliases: ["/focus"],
                argumentHint: "@workspace",
                summary: String(localized: "sortAssistant.slash.select.summary", defaultValue: "Select a workspace")
            ),
        ]
    }

    static func completions(matching query: String) -> [SortAssistantSlashCommandDescriptor] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let options = descriptors.flatMap { descriptor -> [SortAssistantSlashCommandDescriptor] in
            var matches: [SortAssistantSlashCommandDescriptor] = []
            if descriptor.matches(query: normalizedQuery) {
                matches.append(descriptor)
            }
            for alias in descriptor.aliases {
                let aliasDescriptor = SortAssistantSlashCommandDescriptor(
                    name: alias,
                    aliases: [],
                    argumentHint: descriptor.argumentHint,
                    summary: descriptor.summary
                )
                if aliasDescriptor.matches(query: normalizedQuery) {
                    matches.append(aliasDescriptor)
                }
            }
            return matches
        }
        var seen: Set<String> = []
        return options
            .filter { seen.insert($0.name).inserted }
            .sorted { lhs, rhs in
                if lhs.name == "/help" { return true }
                if rhs.name == "/help" { return false }
                return lhs.name < rhs.name
            }
    }
}
