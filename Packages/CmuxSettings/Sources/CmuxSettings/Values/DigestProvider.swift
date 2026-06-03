import Foundation

/// CLI backend used by cmux-digest to summarize workspace state.
///
/// Stored under the catalog entry ``DigestCatalogSection/provider`` as its raw
/// string (`claude-code` / `codex`), matching the legacy `digest.provider`
/// UserDefaults value.
public enum DigestProvider: String, CaseIterable, Sendable, SettingCodable {
    /// Summaries are produced via the Claude Code CLI (default).
    case claudeCode = "claude-code"
    /// Summaries are produced via the Codex CLI.
    case codex
}
