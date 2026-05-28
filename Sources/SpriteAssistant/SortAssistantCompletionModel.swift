import Foundation

struct SortAssistantWorkspaceMentionResolution: Equatable {
    let target: SortAssistantWorkspaceTarget
    let cleanedText: String
}

struct SortAssistantCompletionItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case slashCommand
        case workspaceMention
    }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String?
    let insertionText: String
}

struct SortAssistantCompletionModel: Equatable {
    enum Kind: Equatable {
        case slashCommand
        case workspaceMention
    }

    let kind: Kind
    let replacementRange: NSRange
    let items: [SortAssistantCompletionItem]

    @MainActor
    static func make(
        text: String,
        selectedRange: NSRange,
        tabManager: TabManager
    ) -> SortAssistantCompletionModel? {
        guard selectedRange.length == 0 else { return nil }
        let clampedLocation = min(max(selectedRange.location, 0), (text as NSString).length)
        let cursorRange = NSRange(location: clampedLocation, length: 0)
        guard let cursor = stringIndex(forUTF16Offset: cursorRange.location, in: text) else {
            return nil
        }

        if let slash = slashCompletion(text: text, cursor: cursor) {
            return slash
        }
        return workspaceMentionCompletion(
            text: text,
            cursor: cursor,
            tabManager: tabManager
        )
    }

    func applying(_ item: SortAssistantCompletionItem, to text: String) -> (text: String, cursorLocation: Int) {
        let next = (text as NSString).replacingCharacters(in: replacementRange, with: item.insertionText)
        let cursorLocation = replacementRange.location + (item.insertionText as NSString).length
        return (next, cursorLocation)
    }

    private static func slashCompletion(text: String, cursor: String.Index) -> SortAssistantCompletionModel? {
        let prefix = text[..<cursor]
        guard prefix.hasPrefix("/") else { return nil }
        guard !prefix.contains(where: { $0.isWhitespace }) else { return nil }

        let query = String(prefix.dropFirst())
        let descriptors = SortAssistantSlashCommand.completions(matching: query)
        guard !descriptors.isEmpty,
              let range = nsRange(text.startIndex..<cursor, in: text) else {
            return nil
        }

        let items = descriptors.map { descriptor in
            SortAssistantCompletionItem(
                id: descriptor.name,
                kind: .slashCommand,
                title: descriptor.displayText,
                subtitle: descriptor.summary,
                insertionText: descriptor.insertionText
            )
        }
        return SortAssistantCompletionModel(kind: .slashCommand, replacementRange: range, items: items)
    }

    @MainActor
    private static func workspaceMentionCompletion(
        text: String,
        cursor: String.Index,
        tabManager: TabManager
    ) -> SortAssistantCompletionModel? {
        guard let tokenRange = mentionTokenRange(before: cursor, in: text) else { return nil }
        let query = String(text[tokenRange].dropFirst())
        let options = workspaceCompletionItems(
            matching: query,
            tabManager: tabManager
        )
        guard !options.isEmpty,
              let range = nsRange(tokenRange, in: text) else {
            return nil
        }
        return SortAssistantCompletionModel(kind: .workspaceMention, replacementRange: range, items: options)
    }

    private static func mentionTokenRange(before cursor: String.Index, in text: String) -> Range<String.Index>? {
        guard cursor <= text.endIndex else { return nil }
        var scan = cursor
        while scan > text.startIndex {
            let previous = text.index(before: scan)
            let character = text[previous]
            if character == "@" {
                return previous..<cursor
            }
            if character.isWhitespace || character == "{" || character == "}" {
                break
            }
            scan = previous
        }
        return nil
    }

    @MainActor
    private static func workspaceCompletionItems(
        matching query: String,
        tabManager: TabManager
    ) -> [SortAssistantCompletionItem] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let selectedWorkspaceId = tabManager.selectedTabId
        let ranked = tabManager.tabs.enumerated().compactMap { index, workspace -> (Int, SortAssistantCompletionItem)? in
            guard let rank = workspaceMatchRank(
                workspace: workspace,
                index: index,
                selectedWorkspaceId: selectedWorkspaceId,
                query: normalizedQuery
            ) else {
                return nil
            }
            let title = workspace.displayTitle
            let subtitle = workspaceSubtitle(workspace: workspace, selectedWorkspaceId: selectedWorkspaceId)
            return (
                rank,
                SortAssistantCompletionItem(
                    id: workspace.id.uuidString,
                    kind: .workspaceMention,
                    title: "@\(title)",
                    subtitle: subtitle,
                    insertionText: "@{\(escapedMentionTitle(title))} "
                )
            )
        }

        return ranked
            .sorted { lhs, rhs in
                if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
                return lhs.1.title.localizedCaseInsensitiveCompare(rhs.1.title) == .orderedAscending
            }
            .map(\.1)
    }

    @MainActor
    private static func workspaceMatchRank(
        workspace: Workspace,
        index: Int,
        selectedWorkspaceId: UUID?,
        query: String
    ) -> Int? {
        if query.isEmpty {
            return workspace.id == selectedWorkspaceId ? 0 : 20 + index
        }

        let title = workspace.displayTitle.lowercased()
        let rawTitle = workspace.title.lowercased()
        let directoryName = workspaceDirectoryName(workspace)?.lowercased()
        let branch = workspace.gitBranch?.branch.lowercased()
        let id = workspace.id.uuidString.lowercased()

        if id.hasPrefix(query) { return 1 }
        if title == query || rawTitle == query { return 2 }
        if title.hasPrefix(query) || rawTitle.hasPrefix(query) { return 3 }
        if directoryName == query { return 4 }
        if directoryName?.hasPrefix(query) == true { return 5 }
        if branch == query { return 6 }
        if branch?.hasPrefix(query) == true { return 7 }
        if title.contains(query) || rawTitle.contains(query) { return 8 }
        if directoryName?.contains(query) == true { return 9 }
        if branch?.contains(query) == true { return 10 }
        return nil
    }

    @MainActor
    private static func workspaceSubtitle(workspace: Workspace, selectedWorkspaceId: UUID?) -> String? {
        var parts: [String] = []
        if workspace.id == selectedWorkspaceId {
            parts.append(String(localized: "sortAssistant.completion.workspace.current", defaultValue: "Current"))
        }
        if let branch = workspace.gitBranch?.branch.trimmingCharacters(in: .whitespacesAndNewlines),
           !branch.isEmpty {
            parts.append(branch)
        }
        if let directoryName = workspaceDirectoryName(workspace) {
            parts.append(directoryName)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    @MainActor
    private static func workspaceDirectoryName(_ workspace: Workspace) -> String? {
        let candidates = [
            workspace.focusedPanelId.flatMap { workspace.panelDirectories[$0] },
            workspace.surfaceTabBarDirectory,
            workspace.currentDirectory,
        ]
        for candidate in candidates {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty else { continue }
            let name = URL(fileURLWithPath: trimmed).lastPathComponent
            return name.isEmpty ? trimmed : name
        }
        return nil
    }

    private static func escapedMentionTitle(_ title: String) -> String {
        title.replacingOccurrences(of: "}", with: "")
    }

    private static func stringIndex(forUTF16Offset offset: Int, in text: String) -> String.Index? {
        guard let utf16Index = text.utf16.index(
            text.utf16.startIndex,
            offsetBy: offset,
            limitedBy: text.utf16.endIndex
        ) else {
            return nil
        }
        return String.Index(utf16Index, within: text)
    }

    private static func nsRange(_ range: Range<String.Index>, in text: String) -> NSRange? {
        let lower = range.lowerBound.samePosition(in: text.utf16)
        let upper = range.upperBound.samePosition(in: text.utf16)
        guard let lower, let upper else { return nil }
        return NSRange(
            location: text.utf16.distance(from: text.utf16.startIndex, to: lower),
            length: text.utf16.distance(from: lower, to: upper)
        )
    }
}
