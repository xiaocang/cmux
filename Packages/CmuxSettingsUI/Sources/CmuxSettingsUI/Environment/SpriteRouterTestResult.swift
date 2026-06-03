import Foundation

/// Outcome of a sprite semantic-router connectivity test, returned by
/// ``SettingsHostActions/testSpriteRouter(provider:model:baseURL:timeoutSeconds:)``.
///
/// The host runs the test and formats a user-facing ``message`` (it owns the
/// route-decision details), so the settings UI only renders the message and
/// colors it by ``passed``.
public struct SpriteRouterTestResult: Sendable, Equatable {
    /// Whether the router returned a correctly-formatted, expected decision.
    public let passed: Bool
    /// Localized, user-facing status message describing the outcome.
    public let message: String

    public init(passed: Bool, message: String) {
        self.passed = passed
        self.message = message
    }
}
