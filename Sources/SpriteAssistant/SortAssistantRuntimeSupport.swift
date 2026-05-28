import CMUXAssistant
import Foundation

typealias AssistantRuntimeContextRead = CMUXAssistant.AssistantRuntimeContextRead
typealias AssistantRuntimeError = CMUXAssistant.AssistantRuntimeError
typealias AssistantRuntime = CMUXAssistant.AssistantRuntime

struct SortAssistantSemanticRouterRuntimeError: Error, CustomStringConvertible {
    let issue: SortAssistantSemanticRouterIssue

    var description: String {
        "semanticRouter.\(issue.debugDescription)"
    }
}

struct SortAssistantDebugSession: Sendable {
    let id: UUID
    let startedAtNanos: UInt64

    static func start(source: String, text: String, externalGoal: Bool, forceApply: Bool) -> SortAssistantDebugSession {
        let session = SortAssistantDebugSession(id: UUID(), startedAtNanos: now())
        session.log(
            "begin source=\(source) externalGoal=\(externalGoal) forceApply=\(forceApply) textChars=\(text.count)"
        )
        return session
    }

    static func now() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    var shortId: String {
        String(id.uuidString.prefix(8)).lowercased()
    }

    func log(_ message: String, phaseStartNanos: UInt64? = nil) {
#if DEBUG
        let total = Self.elapsedMilliseconds(since: startedAtNanos)
        let phase = phaseStartNanos.map { " phase_ms=\(Self.formatMilliseconds(Self.elapsedMilliseconds(since: $0)))" } ?? ""
        cmuxDebugLog(
            "sprite.timing session=\(shortId)\(phase) total_ms=\(Self.formatMilliseconds(total)) \(message)"
        )
#endif
    }

    func finish(result: String, details: String = "") {
        let suffix = details.isEmpty ? "" : " \(details)"
        log("end result=\(result)\(suffix)")
    }

    private static func elapsedMilliseconds(since start: UInt64) -> Double {
        Double(now().saturatingSubtracting(start)) / 1_000_000
    }

    private static func formatMilliseconds(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    static func errorSummary(_ error: Error) -> String {
        String(describing: error)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .prefix(180)
            .description
    }
}

private extension UInt64 {
    func saturatingSubtracting(_ other: UInt64) -> UInt64 {
        self >= other ? self - other : 0
    }
}

enum SortAssistantClaudeWorkDirectory {
    static func url() throws -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let url = base
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("sprite-assistant-claude", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

enum SortAssistantClaudeCodeRuntime {
    private static let settingsSources = "project"
    private static let settingsContents = "{}\n"
    private static let effort = "low"

    static var outputFormat: String {
        "stream-json"
    }

    static var outputFormatArguments: [String] {
        ["--verbose"]
    }

    static func isolatedArguments(
        systemPrompt: String,
        sessionId: UUID? = nil,
        resumeSession: Bool = false
    ) throws -> [String] {
        var arguments = [
            "--system-prompt", systemPrompt,
            "--settings", try settingsURL().path,
            "--setting-sources", settingsSources,
            "--effort", effort,
            "--disable-slash-commands",
            "--tools", "",
        ]
        if let sessionId {
            arguments += [resumeSession ? "--resume" : "--session-id", sessionId.uuidString]
        } else {
            arguments.append("--no-session-persistence")
        }
        return arguments
    }

    static func debugSummary(sessionId: UUID? = nil, resumeSession: Bool = false) -> String {
        let persistence: String
        if let sessionId {
            persistence = "\(resumeSession ? "resume" : "new"):\(String(sessionId.uuidString.prefix(8)))"
        } else {
            persistence = "disabled"
        }
        return "outputFormat=\(outputFormat) effort=\(effort) systemPrompt=replace settingSources=\(settingsSources) skills=disabled builtInTools=disabled sessionPersistence=\(persistence)"
    }

    private static func settingsURL() throws -> URL {
        let directory = try SortAssistantClaudeWorkDirectory.url()
            .appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = directory.appendingPathComponent("settings.json")
        let existing = try? String(contentsOf: url, encoding: .utf8)
        if existing != settingsContents {
            try settingsContents.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }
}

enum SortAssistantClaudeOutputParser {
    static func resultText(from stdout: String) -> String? {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let object = jsonObject(from: trimmed) {
            return resultText(from: object)
        }

        var latestResult: String?
        for line in trimmed.split(whereSeparator: \.isNewline) {
            guard let object = jsonObject(from: String(line)),
                  let result = resultText(from: object) else {
                continue
            }
            latestResult = result
        }
        return latestResult
    }

    private static func resultText(from object: [String: Any]) -> String? {
        if let isError = object["is_error"] as? Bool, isError {
            return nil
        }
        return object["result"] as? String
    }

    private static func jsonObject(from text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }
}

struct SpriteAssistantSemanticRouterConfig: Sendable {
    let provider: String
    let model: String
    let baseURL: String
    let apiKey: String?
    let timeoutSeconds: TimeInterval

    var normalizedProvider: String {
        provider
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "_")
            .lowercased()
    }
}

enum SpriteAssistantSemanticRouterProviderOption: String, CaseIterable, Identifiable {
    case ollama
    case openAICompatible = "openai_compatible"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ollama:
            return String(localized: "settings.sprite.localLLM.provider.ollama", defaultValue: "Ollama")
        case .openAICompatible:
            return String(localized: "settings.sprite.localLLM.provider.openAICompatible", defaultValue: "OpenAI-compatible")
        }
    }
}

enum SpriteAssistantSemanticRouterSettings {
    static let enabledKey = "sprite.semanticRouter.enabled"
    static let providerKey = "sprite.semanticRouter.provider"
    static let modelKey = "sprite.semanticRouter.model"
    static let baseURLKey = "sprite.semanticRouter.baseURL"
    static let timeoutSecondsKey = "sprite.semanticRouter.timeoutSeconds"

    static let defaultEnabled = true
    static let defaultProvider = SpriteAssistantSemanticRouterProviderOption.ollama.rawValue
    static let defaultModel = ""
    static let defaultTimeoutSeconds: TimeInterval = 12

    static func defaultBaseURL(for provider: String) -> String {
        switch normalizedProvider(provider) {
        case SpriteAssistantSemanticRouterProviderOption.openAICompatible.rawValue,
            "openai",
            "openai_compat":
            return "http://localhost:11434/v1"
        default:
            return "http://localhost:11434"
        }
    }

    static func normalizedProvider(_ provider: String) -> String {
        provider
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "_")
            .lowercased()
    }

    static func providerOption(for rawValue: String) -> SpriteAssistantSemanticRouterProviderOption {
        SpriteAssistantSemanticRouterProviderOption(rawValue: normalizedProvider(rawValue)) ?? .ollama
    }

    static func resolvedBaseURL(provider: String, storedBaseURL: String) -> String {
        let trimmed = storedBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultBaseURL(for: provider) : trimmed
    }

    static func userDefaultsObject(defaults: UserDefaults = .standard) -> [String: Any] {
        var raw: [String: Any] = [
            "enabled": defaults.object(forKey: enabledKey) as? Bool ?? defaultEnabled,
            "provider": providerOption(for: defaults.string(forKey: providerKey) ?? defaultProvider).rawValue,
            "baseURL": resolvedBaseURL(
                provider: defaults.string(forKey: providerKey) ?? defaultProvider,
                storedBaseURL: defaults.string(forKey: baseURLKey) ?? ""
            ),
            "timeoutSeconds": resolvedTimeoutSeconds(defaults: defaults),
        ]
        if let model = trimmed(defaults.string(forKey: modelKey)) {
            raw["model"] = model
        }
        return raw
    }

    static func resolvedTimeoutSeconds(defaults: UserDefaults = .standard) -> TimeInterval {
        let value = defaults.object(forKey: timeoutSecondsKey) as? TimeInterval ?? defaultTimeoutSeconds
        guard value.isFinite, value > 0 else { return defaultTimeoutSeconds }
        return min(max(value, 1), 30)
    }

    static func fetchOllamaModelNames(
        baseURL: String,
        timeoutSeconds: TimeInterval = defaultTimeoutSeconds
    ) async throws -> [String] {
        let url = try endpointURL(baseURL: baseURL, defaultPath: "/api/tags")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeoutSeconds
        configuration.timeoutIntervalForResource = timeoutSeconds
        let session = URLSession(configuration: configuration)
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "SpriteAssistantSemanticRouterSettings", code: 1)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["models"] as? [[String: Any]] else {
            return []
        }
        return models.compactMap { model in
            trimmed(model["name"] as? String)
        }
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func endpointURL(baseURL: String, defaultPath: String) throws -> URL {
        guard let base = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw NSError(domain: "SpriteAssistantSemanticRouterSettings", code: 2)
        }
        if base.path.hasSuffix(defaultPath) {
            return base
        }
        return base.appendingPathComponent(defaultPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    private static func trimmed(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum SpriteAssistantConfig {
    static let globalFileName = "sprite.json"

    static func externalMCPServers(workspaceDirectory: String?) -> [String: Any] {
        var merged: [String: Any] = [:]
        for object in configObjects(workspaceDirectory: workspaceDirectory) {
            let serverObjects = [
                object["mcpServers"],
                object["externalMCPServers"],
                object["externalMcpServers"],
            ].compactMap { $0 as? [String: Any] }
            for servers in serverObjects {
                for (name, value) in servers {
                    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedName.isEmpty,
                          trimmedName != "cmux_sprite",
                          let server = value as? [String: Any] else {
                        continue
                    }
                    merged[trimmedName] = server
                }
            }
        }
        return merged
    }

    static func externalMCPAllowedTools(
        workspaceDirectory: String?,
        serverNames: [String]? = nil
    ) -> [String] {
        let names = serverNames ?? externalMCPServers(workspaceDirectory: workspaceDirectory)
            .keys
            .sorted()
        let serverAllowlist = names.map { "mcp__\($0)__*" }
        var configured: [String] = []
        for object in configObjects(workspaceDirectory: workspaceDirectory) {
            let values = object["allowedTools"]
                ?? object["mcpAllowedTools"]
                ?? object["mcp_allowed_tools"]
            configured.append(contentsOf: stringArray(values))
        }
        return unique(serverAllowlist + configured)
    }

    static func semanticRouterConfig(workspaceDirectory: String?) -> SpriteAssistantSemanticRouterConfig? {
        let env = ProcessInfo.processInfo.environment
        let raw = semanticRouterRawConfig(workspaceDirectory: workspaceDirectory, environment: env)

        if let enabled = bool(raw["enabled"]), !enabled {
            return nil
        }
        let provider = string(raw["provider"]) ?? SpriteAssistantSemanticRouterSettings.defaultProvider
        let baseURL = string(raw["baseURL"]) ?? defaultBaseURL(for: provider)
        guard let model = string(raw["model"]),
              !model.isEmpty,
              !baseURL.isEmpty else {
            return nil
        }

        let apiKey: String? = {
            if let direct = string(raw["apiKey"]) { return direct }
            if let envName = string(raw["apiKeyEnv"]) ?? string(raw["api_key_env"]) {
                return trimmed(env[envName])
            }
            return nil
        }()
        let timeout = double(raw["timeoutSeconds"] ?? raw["timeout_seconds"])
            ?? SpriteAssistantSemanticRouterSettings.defaultTimeoutSeconds
        return SpriteAssistantSemanticRouterConfig(
            provider: provider,
            model: model,
            baseURL: baseURL,
            apiKey: apiKey,
            timeoutSeconds: min(max(timeout, 1), 30)
        )
    }

    static func semanticRouterConfigIssue(workspaceDirectory: String?) -> String {
        let raw = semanticRouterRawConfig(workspaceDirectory: workspaceDirectory)
        if let enabled = bool(raw["enabled"]), !enabled {
            return "disabled"
        }
        let provider = string(raw["provider"]) ?? SpriteAssistantSemanticRouterSettings.defaultProvider
        let baseURL = string(raw["baseURL"]) ?? defaultBaseURL(for: provider)
        guard let model = string(raw["model"]),
              !model.isEmpty else {
            return "not_configured"
        }
        guard !baseURL.isEmpty else {
            return "missing_base_url"
        }
        return "unavailable"
    }

    private static func semanticRouterRawConfig(
        workspaceDirectory: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: Any] {
        var raw = SpriteAssistantSemanticRouterSettings.userDefaultsObject()
        for object in configObjects(workspaceDirectory: workspaceDirectory) {
            guard let next = object["semanticRouter"] as? [String: Any] else { continue }
            raw.merge(next) { _, new in new }
        }

        if let provider = trimmed(environment["CMUX_SPRITE_SEMANTIC_ROUTER_PROVIDER"]) {
            raw["provider"] = provider
        }
        if let model = trimmed(environment["CMUX_SPRITE_SEMANTIC_ROUTER_MODEL"]) {
            raw["model"] = model
        }
        if let baseURL = trimmed(environment["CMUX_SPRITE_SEMANTIC_ROUTER_BASE_URL"]) {
            raw["baseURL"] = baseURL
        }
        if let timeout = trimmed(environment["CMUX_SPRITE_SEMANTIC_ROUTER_TIMEOUT_SECONDS"]),
           let value = TimeInterval(timeout),
           value.isFinite,
           value > 0 {
            raw["timeoutSeconds"] = value
        }
        if let apiKey = trimmed(environment["CMUX_SPRITE_SEMANTIC_ROUTER_API_KEY"]) {
            raw["apiKey"] = apiKey
        }
        return raw
    }

    private static func defaultBaseURL(for provider: String) -> String {
        SpriteAssistantSemanticRouterSettings.defaultBaseURL(for: provider)
    }

    private static func configObjects(workspaceDirectory: String?) -> [[String: Any]] {
        configURLs(workspaceDirectory: workspaceDirectory).compactMap(loadJSONObject)
    }

    private static func configURLs(workspaceDirectory: String?) -> [URL] {
        var urls: [URL] = [globalConfigURL()]
        urls.append(contentsOf: projectConfigURLs(workspaceDirectory: workspaceDirectory))
        return urls
    }

    private static func globalConfigURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent(globalFileName, isDirectory: false)
    }

    private static func projectConfigURLs(workspaceDirectory: String?) -> [URL] {
        guard let workspaceDirectory = trimmed(workspaceDirectory) else { return [] }
        var isDirectory: ObjCBool = false
        let expanded = (workspaceDirectory as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return []
        }

        var urls: [URL] = []
        var current = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        while true {
            let candidate = current
                .appendingPathComponent(".cmux", isDirectory: true)
                .appendingPathComponent(globalFileName, isDirectory: false)
            if FileManager.default.fileExists(atPath: candidate.path) {
                urls.append(candidate)
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return urls.reversed()
    }

    private static func loadJSONObject(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func string(_ value: Any?) -> String? {
        if let string = value as? String {
            return trimmed(string)
        }
        return nil
    }

    private static func stringArray(_ value: Any?) -> [String] {
        if let strings = value as? [String] {
            return strings.compactMap { trimmed($0) }
        }
        if let values = value as? [Any] {
            return values.compactMap(string)
        }
        if let string = string(value) {
            return [string]
        }
        return []
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }

    private static func trimmed(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = string(value) {
            switch string.lowercased() {
            case "1", "true", "yes", "on":
                return true
            case "0", "false", "no", "off":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = string(value) { return Double(string) }
        return nil
    }
}

enum SortAssistantPayload {
    private static let encoder = JSONEncoder()

    static func dictionary<T: Encodable>(_ value: T) -> [String: Any] {
        guard let data = try? encoder.encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }

    static func array<T: Encodable>(_ value: T) -> [[String: Any]] {
        guard let data = try? encoder.encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return object
    }
}
