import CmuxFoundation
import Foundation
import OSLog

struct LiveShellSessionInfo: Codable, Equatable, Hashable, Sendable, Identifiable {
    let id: String
    let name: String
    let status: LiveShellStatus
    let cwd: String
    let shellPath: String
    let createdAtMs: UInt64
    let lastActiveAtMs: UInt64
    let attached: Bool

    private enum CodingKeys: String, CodingKey {
        case id, name, status, cwd
        case shellPath = "shell_path"
        case createdAtMs = "created_at_ms"
        case lastActiveAtMs = "last_active_at_ms"
        case attached
    }
}

enum LiveShellStatus: String, Codable, Equatable, Hashable, Sendable {
    case running = "Running"
    case exited = "Exited"
    case lost = "Lost"
}

/// Thin async wrapper around the `liveshctl` CLI.
enum LiveShellControl {
    private static let logger = Logger(subsystem: "com.cmuxterm.app", category: "LiveShellControl")
    private static let timeout: TimeInterval = 5

    enum LiveShellControlError: Error, LocalizedError {
        case executableNotFound
        case daemonUnavailable
        case timedOut
        case commandFailed
        case nonZeroExit(code: Int32, stderr: String)
        case decodeFailure(underlying: Error)

        var errorDescription: String? {
            switch self {
            case .executableNotFound:
                String(localized: "liveShell.error.executableNotFound", defaultValue: "liveshctl was not found.")
            case .daemonUnavailable:
                String(localized: "liveShell.error.daemonUnavailable", defaultValue: "The livesh daemon is unavailable.")
            case .timedOut:
                String(localized: "liveShell.error.timedOut", defaultValue: "liveshctl did not respond in time.")
            case .commandFailed:
                String(localized: "liveShell.error.commandFailed", defaultValue: "liveshctl could not be launched.")
            case .nonZeroExit(let code, let stderr):
                String(
                    format: String(localized: "liveShell.error.nonZeroExit", defaultValue: "liveshctl exited with code %lld: %@"),
                    Int64(code),
                    stderr
                )
            case .decodeFailure:
                String(localized: "liveShell.error.decodeFailure", defaultValue: "liveshctl returned an invalid response.")
            }
        }
    }

    static func list(commands: any CommandRunning = CommandRunner()) async throws -> [LiveShellSessionInfo] {
        switch await run(arguments: ["list", "--json"], commands: commands) {
        case .success(let stdout):
            let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return [] }
            do {
                return try JSONDecoder().decode([LiveShellSessionInfo].self, from: data)
            } catch {
                logger.error("decode list output failed: \(error.localizedDescription, privacy: .public)")
                throw LiveShellControlError.decodeFailure(underlying: error)
            }
        case .failure(let error):
            throw error
        }
    }

    static func kill(
        sessionId: String,
        commands: any CommandRunning = CommandRunner()
    ) async throws {
        let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if case .failure(let error) = await run(arguments: ["kill", trimmed], commands: commands) {
            throw error
        }
    }

    static func gc(commands: any CommandRunning = CommandRunner()) async throws {
        if case .failure(let error) = await run(arguments: ["gc"], commands: commands) {
            throw error
        }
    }

    private static func run(
        arguments: [String],
        commands: any CommandRunning
    ) async -> Result<String, LiveShellControlError> {
        guard let executable = LiveShellSettings.resolvedLiveshctlExecutable() else {
            return .failure(.executableNotFound)
        }
        let result = await commands.run(
            directory: FileManager.default.currentDirectoryPath,
            executable: executable,
            arguments: arguments,
            timeout: timeout
        )
        if result.timedOut {
            return .failure(.timedOut)
        }
        if result.executionError != nil || result.exitStatus == nil {
            return .failure(.commandFailed)
        }
        guard let status = result.exitStatus else {
            return .failure(.commandFailed)
        }
        if status == 0 {
            return .success(result.stdout ?? "")
        }
        if status == LiveShellExitCode.daemonUnavailable {
            return .failure(.daemonUnavailable)
        }
        return .failure(.nonZeroExit(
            code: status,
            stderr: (result.stderr ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        ))
    }
}

/// Static exit codes published by livesh and liveshctl.
enum LiveShellExitCode {
    /// The daemon no longer owns this shell.
    static let shellLost: Int32 = 66
    /// The daemon socket is unreachable.
    static let daemonUnavailable: Int32 = 69
}
