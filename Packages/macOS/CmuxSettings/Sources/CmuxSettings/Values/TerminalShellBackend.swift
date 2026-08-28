import Foundation

/// Whether new terminal panes run their shell directly or through livesh.
public enum TerminalShellBackend: String, CaseIterable, Sendable, SettingCodable {
    /// Run the shell directly under cmux.
    case direct
    /// Run the shell in a daemon-owned PTY that can survive cmux restarts.
    case livesh
}
