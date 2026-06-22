import SwiftUI

/// Column header for the custom site-search shortcuts editor: Name, Shortcut,
/// URL template, Active. Mirrors the legacy in-app header row.
struct BrowserSiteSearchHeaderRow: View {
    var body: some View {
        HStack(spacing: 8) {
            Text(String(localized: "settings.browser.siteSearch.name", defaultValue: "Name"))
                .frame(width: 120, alignment: .leading)
            Text(String(localized: "settings.browser.siteSearch.shortcut", defaultValue: "Shortcut"))
                .frame(width: 84, alignment: .leading)
            Text(String(localized: "settings.browser.siteSearch.urlTemplate", defaultValue: "URL with %s in place of query"))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(String(localized: "settings.browser.siteSearch.active", defaultValue: "Active"))
                .frame(width: 54, alignment: .center)
            Color.clear.frame(width: 24, height: 1)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}
