import Foundation

/// Key that activates site-search mode after typing a site shortcut in the
/// browser address bar.
///
/// Stored under the catalog entry ``BrowserCatalogSection/siteSearchActivation``
/// as its raw string, matching the legacy `browserSiteSearchActivationShortcut`
/// UserDefaults value. Defaults to ``tab``.
public enum BrowserSiteSearchActivation: String, CaseIterable, Sendable, SettingCodable {
    /// Press Tab to enter site search (default).
    case tab
    /// Press Space or Tab to enter site search.
    case spaceOrTab
}
