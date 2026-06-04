import Foundation

struct SortAssistantSuggestionWorkspaceMetadata: Equatable {
    private static let fallbackTitle = String(localized: "workspace.displayName.fallback", defaultValue: "Workspace")
    private static let maxTitleLength = 36

    let title: String
    let paneCount: Int

    init(title: String, paneCount: Int) {
        self.title = Self.normalizedTitle(title)
        self.paneCount = max(0, paneCount)
    }

    var displayText: String {
        if paneCount == 1 {
            let format = String(
                localized: "sortAssistant.suggestions.workspaceMetadata.onePane",
                defaultValue: "%@ - 1 pane"
            )
            return String(format: format, title)
        }
        let format = String(
            localized: "sortAssistant.suggestions.workspaceMetadata.multiplePanes",
            defaultValue: "%@ - %lld panes"
        )
        return String(format: format, title, Int64(paneCount))
    }

    private static func normalizedTitle(_ rawTitle: String) -> String {
        let singleLine = rawTitle
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let title = singleLine.isEmpty ? fallbackTitle : singleLine
        guard title.count > maxTitleLength else { return title }
        let end = title.index(title.startIndex, offsetBy: maxTitleLength)
        return String(title[..<end]) + "..."
    }
}
