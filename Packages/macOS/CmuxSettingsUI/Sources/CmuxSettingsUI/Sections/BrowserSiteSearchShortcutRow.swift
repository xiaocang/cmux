import CmuxSettings
import SwiftUI

/// One editable row in the custom site-search shortcuts editor: name, keyword,
/// URL template, an active toggle, and a remove button, with an inline
/// validation message. Mirrors the legacy in-app row.
struct BrowserSiteSearchShortcutRow: View {
    let id: UUID
    @Binding var name: String
    @Binding var shortcut: String
    @Binding var urlTemplate: String
    @Binding var isActive: Bool
    let onRemove: () -> Void

    private var shortcutIsValid: Bool { BrowserSiteSearchShortcut.isValidShortcut(shortcut) }
    private var urlTemplateIsValid: Bool { BrowserSiteSearchShortcut.isValidURLTemplate(urlTemplate) }
    private var rowSuffix: String { id.uuidString }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TextField(String(localized: "settings.browser.siteSearch.name.placeholder", defaultValue: "GitHub"), text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                    .accessibilityIdentifier("SettingsBrowserSiteSearchNameField.\(rowSuffix)")

                TextField(String(localized: "settings.browser.siteSearch.shortcut.placeholder", defaultValue: "gh"), text: $shortcut)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 84)
                    .accessibilityIdentifier("SettingsBrowserSiteSearchShortcutField.\(rowSuffix)")

                TextField(String(localized: "settings.browser.siteSearch.urlTemplate.placeholder", defaultValue: "https://github.com/search?q=%s"), text: $urlTemplate)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(minWidth: 220, maxWidth: .infinity)
                    .accessibilityIdentifier("SettingsBrowserSiteSearchURLTemplateField.\(rowSuffix)")

                Toggle("", isOn: $isActive)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 54)
                    .accessibilityLabel(String(localized: "settings.browser.siteSearch.active", defaultValue: "Active"))
                    .accessibilityIdentifier("SettingsBrowserSiteSearchActiveToggle.\(rowSuffix)")

                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .frame(width: 24)
                .help(String(localized: "settings.browser.siteSearch.remove", defaultValue: "Remove site search"))
                .accessibilityIdentifier("SettingsBrowserSiteSearchRemoveButton.\(rowSuffix)")
            }

            if !shortcutIsValid || !urlTemplateIsValid {
                Text(validationMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("SettingsBrowserSiteSearchValidation.\(rowSuffix)")
            }
        }
    }

    private var validationMessage: String {
        if !shortcutIsValid {
            return String(localized: "settings.browser.siteSearch.invalidShortcut", defaultValue: "Shortcut cannot be empty or contain spaces.")
        }
        return String(localized: "settings.browser.siteSearch.invalidTemplate", defaultValue: "URL must use http or https and include %s.")
    }
}
