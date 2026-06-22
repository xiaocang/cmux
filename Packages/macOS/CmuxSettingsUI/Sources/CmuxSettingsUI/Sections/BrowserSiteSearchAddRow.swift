import SwiftUI

/// The "add a new site search" row at the bottom of the editor: draft name,
/// keyword, and URL-template fields plus an add button enabled only when the
/// draft is valid. Mirrors the legacy in-app add row.
struct BrowserSiteSearchAddRow: View {
    @Binding var name: String
    @Binding var shortcut: String
    @Binding var urlTemplate: String
    let canAdd: Bool
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField(String(localized: "settings.browser.siteSearch.name.placeholder", defaultValue: "GitHub"), text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)
                .onSubmit { if canAdd { onAdd() } }
                .accessibilityIdentifier("SettingsBrowserSiteSearchNewNameField")

            TextField(String(localized: "settings.browser.siteSearch.shortcut.placeholder", defaultValue: "gh"), text: $shortcut)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .frame(width: 84)
                .onSubmit { if canAdd { onAdd() } }
                .accessibilityIdentifier("SettingsBrowserSiteSearchNewShortcutField")

            TextField(String(localized: "settings.browser.siteSearch.urlTemplate.placeholder", defaultValue: "https://github.com/search?q=%s"), text: $urlTemplate)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 220, maxWidth: .infinity)
                .onSubmit { if canAdd { onAdd() } }
                .accessibilityIdentifier("SettingsBrowserSiteSearchNewURLTemplateField")

            Color.clear.frame(width: 54, height: 1)

            Button(action: onAdd) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .frame(width: 24)
            .disabled(!canAdd)
            .help(String(localized: "settings.browser.siteSearch.add", defaultValue: "Add site search"))
            .accessibilityIdentifier("SettingsBrowserSiteSearchAddButton")
        }
    }
}
