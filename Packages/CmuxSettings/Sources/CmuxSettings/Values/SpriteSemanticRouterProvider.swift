import Foundation

/// Backend that powers the sprite's local semantic router.
///
/// The router decides how a sprite request is handled before falling back to
/// Claude Code. ``ollama`` targets a local Ollama server; ``openAICompatible``
/// targets any OpenAI-compatible `/v1` endpoint. Stored under the catalog entry
/// ``AutomationCatalogSection/spriteSemanticRouterProvider`` as its raw string
/// (`ollama` / `openai_compatible`), matching the legacy
/// `sprite.semanticRouter.provider` UserDefaults value.
public enum SpriteSemanticRouterProvider: String, CaseIterable, Sendable, SettingCodable {
    /// Local Ollama server (default). Base URL defaults to `http://localhost:11434`.
    case ollama
    /// Any OpenAI-compatible chat-completions endpoint.
    case openAICompatible = "openai_compatible"
}
