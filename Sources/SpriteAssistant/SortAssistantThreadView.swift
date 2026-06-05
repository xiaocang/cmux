import AppKit
import CMUXWorkstream
import Combine
import Darwin
import Foundation
import MCP
import SwiftUI

struct SortAssistantThreadView: View {
    enum CompletionLayout {
        case inline
        case overlay
    }

    @ObservedObject var coordinator: SortAssistantCoordinator
    @ObservedObject var tabManager: TabManager
    @ObservedObject var workspaceTabStore: WorkspaceTabStore
    var showsHeader = true
    var showsAssistantMessageAvatar = true
    var completionLayout: CompletionLayout = .inline

    @State private var draft = ""
    @State private var draftSelection = NSRange(location: 0, length: 0)
    @State private var draftSelectionRevision = 0
    @State private var completionSelection = 0
    @State private var keyboardOptionSelection = 0
    @State private var dismissedCompletionKey: String?
    @State private var memoriesExpanded = false
    @State private var expandedMessageIds: Set<UUID> = []
    @State private var keyboardFocusedMessageId: UUID?
    @StateObject private var messageScrollController = SortAssistantMessageScrollController()
    @FocusState private var inputFocused: Bool

    static let completionPanelMaxHeight: CGFloat = 156
    static let completionPanelSpacing: CGFloat = 6
    private static let memoryStripCollapsedCount = 3
    private static let floatingScrollableContentMaxHeight: CGFloat = 320

    private enum KeyboardOption {
        case semanticConfirm
        case semanticCancel
        case dimension(String)
        case choice(SortAssistantChoicePrompt.Option)
        case memorySave
        case memoryDiscard
        case result(SortAssistantResultAction)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsHeader {
                header
            }
            promptAndMessageContent
            inputSection
        }
        .padding(.horizontal, showsHeader ? 10 : 12)
        .padding(.vertical, showsHeader ? 8 : 12)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(SortAssistantAccessibility.thread)
        .onAppear {
            coordinator.attach(
                tabManager: tabManager,
                workspaceTabStore: workspaceTabStore
            )
            coordinator.drainExternalGoal(
                tabManager: tabManager,
                workspaceTabStore: workspaceTabStore
            )
            focusInputIfRequested()
        }
        .onChange(of: coordinator.externalGoalSequence) { _, _ in
            coordinator.drainExternalGoal(
                tabManager: tabManager,
                workspaceTabStore: workspaceTabStore
            )
        }
        .onChange(of: coordinator.entryFocusSequence) { _, _ in
            focusInputIfRequested()
        }
        .onChange(of: keyboardOptions.count) { _, count in
            keyboardOptionSelection = clampedKeyboardOptionSelection(count: count)
        }
        .onChange(of: tabManager.selectedTabId) { _, _ in
            coordinator.attach(
                tabManager: tabManager,
                workspaceTabStore: workspaceTabStore
            )
        }
        .onChange(of: coordinator.memories.count) { _, count in
            if count <= Self.memoryStripCollapsedCount {
                memoriesExpanded = false
            }
        }
        .onChange(of: coordinator.messages.map(\.id)) { _, _ in
            pruneMessageKeyboardState()
        }
    }

    @ViewBuilder
    private var promptAndMessageContent: some View {
        if completionLayout == .overlay {
            ScrollView {
                promptAndMessageStack
            }
            .frame(maxHeight: Self.floatingScrollableContentMaxHeight)
            .scrollIndicators(.automatic)
        } else {
            promptAndMessageStack
        }
    }

    private var promptAndMessageStack: some View {
        VStack(alignment: .leading, spacing: 10) {
            messages
            if let confirmation = coordinator.semanticActionConfirmation {
                semanticActionConfirmationCard(confirmation)
            }
            let digest = proactiveSuggestionDigestForDisplay
            let suggestion = digest.flatMap { primarySuggestion(for: $0) }
                ?? coordinator.visibleSuggestions.first
            if let suggestion {
                suggestionCards(
                    [suggestion],
                    digest: digest,
                    semanticTitle: digest?.text.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            if let prompt = coordinator.choicePrompt {
                choicePromptCard(prompt)
            }
            if let question = coordinator.dimensionQuestion {
                dimensionQuestion(question)
            }
            if let candidate = coordinator.memoryCandidate {
                memoryCandidateCard(candidate)
            }
            if !coordinator.memories.isEmpty {
                memoryStrip
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            SortAssistantMascotButton(
                presentation: .threadHeader,
                isActive: coordinator.isSorting,
                state: coordinator.mascotState,
                action: coordinator.activateEntry
            )
            .accessibilityIdentifier(SortAssistantAccessibility.headerMascotButton)
            Text(String(localized: "sortAssistant.feed.title", defaultValue: "Sort Assistant"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            if coordinator.isSorting {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.55)
                    .frame(width: 14, height: 14)
            }
            Button {
                coordinator.clearCurrentSession()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .disabled(!coordinator.hasCurrentSessionState)
            .help(String(localized: "sortAssistant.session.clear", defaultValue: "Clear current session"))
        }
    }

    private var messages: some View {
        Group {
            if coordinator.messages.isEmpty {
                if showsAssistantMessageAvatar {
                    SortAssistantMascotIntroView(
                        isSorting: coordinator.isSorting,
                        state: coordinator.mascotState,
                        action: coordinator.activateEntry
                    )
                } else {
                    Text(String(localized: "sortAssistant.mascot.prompt", defaultValue: "What should move up in the workspace order?"))
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 2)
                        .padding(.vertical, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                let messagesSnapshot = coordinator.messages
                let anchorId = coordinator.latestResultAnchorMessageId
                let result = coordinator.latestResult
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(messagesSnapshot) { message in
                                VStack(alignment: .leading, spacing: 8) {
                                    SortAssistantMessageRow(
                                        message: message,
                                        showsAssistantAvatar: showsAssistantMessageAvatar,
                                        isExpanded: expandedMessageIds.contains(message.id),
                                        isKeyboardFocused: keyboardFocusedMessageId == message.id,
                                        onToggleExpanded: {
                                            toggleMessageExpansion(message.id)
                                        }
                                    )
                                    .id(message.id)
                                    .accessibilityIdentifier(
                                        message.accessibilityIdentifier
                                            ?? SortAssistantAccessibility.messageRow(message.id)
                                    )

                                    if anchorId == message.id, let result {
                                        resultCard(result)
                                            .id(result.id)
                                    }
                                }
                            }
                            if anchorId == nil, let result {
                                resultCard(result)
                                    .id(result.id)
                            }
                        }
                        .padding(.vertical, 4)
                        .background(
                            SortAssistantScrollViewResolver { scrollView in
                                messageScrollController.attach(scrollView: scrollView)
                            }
                        )
                    }
                    .accessibilityIdentifier(SortAssistantAccessibility.messageList)
                    .frame(maxHeight: 220)
                    .scrollIndicators(.automatic)
                    .onAppear {
                        scrollToLatestMessage(proxy)
                    }
                    .onChange(of: coordinator.messages.last?.id) { _, _ in
                        if keyboardFocusedMessageId == nil {
                            scrollToLatestMessage(proxy)
                        }
                    }
                    .onChange(of: coordinator.latestResult?.id) { _, _ in
                        if keyboardFocusedMessageId == nil {
                            scrollToLatestMessage(proxy)
                        }
                    }
                    .onChange(of: keyboardFocusedMessageId) { _, messageId in
                        guard let messageId else { return }
                        scrollToMessage(messageId, proxy: proxy, anchor: .center)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func suggestionCards(
        _ suggestions: [ProactiveSuggestion],
        digest: SortAssistantProactiveSuggestionDigest?,
        semanticTitle: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "sortAssistant.suggestions.title", defaultValue: "Suggestions"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            ForEach(Array(suggestions.prefix(1))) { suggestion in
                SortAssistantSuggestionCardView(
                    suggestion: suggestion,
                    workspaceMetadata: workspaceMetadata(for: suggestion.workspaceId).displayText,
                    icon: suggestionIcon(for: suggestion.type),
                    isCollapsed: digest?.foldedSuggestionIds.contains(suggestion.id) ?? false,
                    semanticTitle: semanticTitle,
                    onOpen: {
                        coordinator.acceptVisibleSuggestion(suggestion)
                    },
                    onDismiss: {
                        coordinator.dismissVisibleSuggestion(suggestion)
                    }
                )
            }
        }
        .accessibilityIdentifier(SortAssistantAccessibility.suggestionList)
    }

    private func primarySuggestion(for digest: SortAssistantProactiveSuggestionDigest) -> ProactiveSuggestion? {
        for suggestionId in digest.suggestionIds {
            if let suggestion = coordinator.visibleSuggestions.first(where: { $0.id == suggestionId }) {
                return suggestion
            }
        }
        return coordinator.visibleSuggestions.first
    }

    private var proactiveSuggestionDigestForDisplay: SortAssistantProactiveSuggestionDigest? {
        guard let digest = coordinator.proactiveSuggestionDigest,
              !digest.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return digest
    }

    private func suggestionIcon(for type: String) -> String {
        switch type {
        case ProactiveSuggestionTypes.reviewAgentWaitingUser:
            return "person.crop.circle.badge.exclamationmark"
        case ProactiveSuggestionTypes.fixCIFailure:
            return "xmark.octagon"
        case ProactiveSuggestionTypes.mergeReady:
            return "checkmark.seal"
        case ProactiveSuggestionTypes.workspaceNeedsAttention:
            return "bell.badge"
        default:
            return "sparkles"
        }
    }

    private func semanticActionConfirmationCard(_ confirmation: SortAssistantSemanticActionConfirmation) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.shield")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 15)
                Text(confirmation.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }

            Text(confirmation.message)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if !confirmation.reasons.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(confirmation.reasons, id: \.self) { reason in
                        Text(reason)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }

            HStack(spacing: 6) {
                Button {
                    coordinator.confirmSemanticAction()
                } label: {
                    Label(
                        String(localized: "sortAssistant.actionReview.confirmButton", defaultValue: "Confirm"),
                        systemImage: "checkmark.shield"
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier(SortAssistantAccessibility.semanticActionConfirmButton)

                Button {
                    coordinator.dismissSemanticActionConfirmation()
                } label: {
                    Label(
                        String(localized: "sortAssistant.actionReview.cancelButton", defaultValue: "Cancel"),
                        systemImage: "xmark"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier(SortAssistantAccessibility.semanticActionCancelButton)
            }
            .font(.system(size: 10, weight: .medium))
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(SortAssistantAccessibility.semanticActionConfirmation)
    }

    private func workspaceMetadata(for workspaceId: UUID) -> SortAssistantSuggestionWorkspaceMetadata {
        guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else {
            return SortAssistantSuggestionWorkspaceMetadata(title: "", paneCount: 0)
        }
        return SortAssistantSuggestionWorkspaceMetadata(
            title: workspace.displayTitle,
            paneCount: workspace.bonsplitController.allPaneIds.count
        )
    }

    private func scrollToLatestMessage(_ proxy: ScrollViewProxy) {
        let id: UUID?
        if coordinator.latestResultAnchorMessageId == coordinator.messages.last?.id {
            id = coordinator.latestResult?.id ?? coordinator.messages.last?.id
        } else {
            id = coordinator.messages.last?.id ?? coordinator.latestResult?.id
        }
        guard let id else { return }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.16)) {
                proxy.scrollTo(id, anchor: .bottom)
            }
        }
    }

    private func scrollToMessage(_ id: UUID, proxy: ScrollViewProxy, anchor: UnitPoint) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.12)) {
                proxy.scrollTo(id, anchor: anchor)
            }
        }
    }

    private func toggleMessageExpansion(_ id: UUID) {
        withAnimation(.easeInOut(duration: 0.12)) {
            if expandedMessageIds.contains(id) {
                expandedMessageIds.remove(id)
            } else {
                expandedMessageIds.insert(id)
            }
            keyboardFocusedMessageId = id
        }
    }

    private var collapsedMessageIds: [UUID] {
        coordinator.messages.compactMap { message in
            guard SortAssistantMessageCollapseRules.isCollapsible(message),
                  !expandedMessageIds.contains(message.id) else {
                return nil
            }
            return message.id
        }
    }

    private func moveCollapsedMessageFocus(delta: Int) -> Bool {
        let ids = collapsedMessageIds
        guard !ids.isEmpty else { return false }

        guard let focused = keyboardFocusedMessageId else {
            keyboardFocusedMessageId = delta < 0 ? ids.last : ids.first
            return true
        }
        guard let currentIndex = ids.firstIndex(of: focused) else {
            return false
        }

        let nextIndex = (currentIndex + delta + ids.count) % ids.count
        keyboardFocusedMessageId = ids[nextIndex]
        return true
    }

    private func activateFocusedCollapsedMessage() -> Bool {
        guard let focused = keyboardFocusedMessageId,
              collapsedMessageIds.contains(focused) else {
            return false
        }
        withAnimation(.easeInOut(duration: 0.12)) {
            expandedMessageIds.insert(focused)
        }
        return true
    }

    private func pruneMessageKeyboardState() {
        let liveIds = Set(coordinator.messages.map(\.id))
        expandedMessageIds.formIntersection(liveIds)
        if let focused = keyboardFocusedMessageId,
           !liveIds.contains(focused) {
            keyboardFocusedMessageId = nil
        }
    }

    private func dimensionQuestion(_ question: SortAssistantDimensionQuestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(
                localized: "sortAssistant.dimension.question",
                defaultValue: "Choose the priority dimension for this sort."
            ))
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.primary)
            .textSelection(.enabled)

            HStack(spacing: 6) {
                dimensionButton(
                    id: "urgency",
                    label: String(localized: "sortAssistant.dimension.urgency", defaultValue: "Urgency"),
                    goal: question.goal,
                    keyboardIndex: 0
                )
                dimensionButton(
                    id: "importance",
                    label: String(localized: "sortAssistant.dimension.importance", defaultValue: "Importance"),
                    goal: question.goal,
                    keyboardIndex: 1
                )
                dimensionButton(
                    id: "progress",
                    label: String(localized: "sortAssistant.dimension.progress", defaultValue: "Progress"),
                    goal: question.goal,
                    keyboardIndex: 2
                )
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        )
    }

    private func dimensionButton(id: String, label: String, goal: String, keyboardIndex: Int) -> some View {
        Button(label) {
            coordinator.answerDimensionQuestion(
                dimensionId: id,
                goal: goal,
                tabManager: tabManager,
                workspaceTabStore: workspaceTabStore
            )
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .font(.system(size: 10, weight: .medium))
        .help(keyboardOptionHelp(index: keyboardIndex))
        .overlay {
            keyboardSelectionOverlay(isSelected: keyboardIndex == keyboardOptionSelection)
        }
    }

    private func resultCard(_ result: SortAssistantSortResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(result.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            if !result.changes.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(result.changes, id: \.self) { change in
                        Text(change)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .textSelection(.enabled)
                    }
                }
                .accessibilityIdentifier(SortAssistantAccessibility.sortPreviewList)
            }
            if let rationale = result.rationale {
                resultMarkdown(rationale)
            }
            if !result.actions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(result.actions.enumerated()), id: \.element) { index, action in
                        resultActionButton(action, result: result, keyboardIndex: index)
                    }
                }
                .font(.system(size: 10, weight: .medium))
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
        )
        .accessibilityIdentifier(SortAssistantAccessibility.resultCard)
    }

    private func choicePromptCard(_ prompt: SortAssistantChoicePrompt) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(prompt.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            if let message = prompt.message {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if prompt.isMultiQuestion {
                multiQuestionChoicePrompt(prompt)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(prompt.options.enumerated()), id: \.element.id) { index, option in
                        Button {
                            coordinator.answerChoicePrompt(
                                option,
                                tabManager: tabManager,
                                workspaceTabStore: workspaceTabStore
                            )
                        } label: {
                            choicePromptOptionRow(
                                option,
                                icon: "target",
                                trailingIcon: "chevron.right",
                                isSelected: false
                            )
                        }
                        .buttonStyle(.plain)
                        .help(keyboardOptionHelp(index: index))
                        .overlay {
                            keyboardSelectionOverlay(isSelected: index == keyboardOptionSelection)
                        }
                    }
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor.opacity(0.075))
        )
        .accessibilityIdentifier(SortAssistantAccessibility.choicePrompt)
    }

    private func multiQuestionChoicePrompt(_ prompt: SortAssistantChoicePrompt) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(prompt.questions) { question in
                VStack(alignment: .leading, spacing: 5) {
                    Text(question.title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                    if let message = question.message {
                        Text(message)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(question.options) { option in
                            let selected = coordinator.choicePromptSelections[question.id]?.id == option.id
                            Button {
                                coordinator.selectChoicePromptOption(
                                    option,
                                    questionId: question.id
                                )
                            } label: {
                                choicePromptOptionRow(
                                    option,
                                    icon: selected ? "checkmark.circle.fill" : "circle",
                                    trailingIcon: nil,
                                    isSelected: selected
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            HStack(spacing: 6) {
                Button {
                    coordinator.submitChoicePromptSelections(
                        tabManager: tabManager,
                        workspaceTabStore: workspaceTabStore
                    )
                } label: {
                    Label(
                        String(localized: "sortAssistant.choice.submit", defaultValue: "Submit choices"),
                        systemImage: "checkmark"
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!coordinator.isChoicePromptReady(prompt))

                Button {
                    coordinator.dismissChoicePrompt()
                } label: {
                    Label(
                        String(localized: "sortAssistant.choice.cancel", defaultValue: "Cancel"),
                        systemImage: "xmark"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .font(.system(size: 10, weight: .medium))
        }
    }

    private func choicePromptOptionRow(
        _ option: SortAssistantChoicePrompt.Option,
        icon: String,
        trailingIcon: String?,
        isSelected: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(width: 14, height: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(option.title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let subtitle = option.subtitle {
                    Text(subtitle)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 0)
            if let trailingIcon {
                Image(systemName: trailingIcon)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 3)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(
                    isSelected
                        ? Color.accentColor.opacity(0.16)
                        : Color.primary.opacity(0.045)
                )
        )
    }

    @ViewBuilder
    private func resultMarkdown(_ markdown: String) -> some View {
        if let attributed = try? AttributedString(markdown: markdown) {
            Text(attributed)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } else {
            Text(markdown)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func resultActionButton(
        _ action: SortAssistantResultAction,
        result: SortAssistantSortResult,
        keyboardIndex: Int
    ) -> some View {
        switch action {
        case .apply:
            Button {
                performResultAction(.apply, result: result)
            } label: {
                Label(String(localized: "sortAssistant.preview.apply", defaultValue: "Apply"), systemImage: "checkmark")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!result.canApply)
            .help(keyboardOptionHelp(index: keyboardIndex))
            .accessibilityIdentifier(SortAssistantAccessibility.resultActionButton(action))
            .overlay {
                keyboardSelectionOverlay(isSelected: keyboardIndex == keyboardOptionSelection)
            }
        case .partialApply:
            Button {
                performResultAction(.partialApply, result: result)
            } label: {
                Label(String(localized: "sortAssistant.preview.partialApply", defaultValue: "Partial"), systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!result.canApplyPartially)
            .help(keyboardOptionHelp(index: keyboardIndex))
            .accessibilityIdentifier(SortAssistantAccessibility.resultActionButton(action))
            .overlay {
                keyboardSelectionOverlay(isSelected: keyboardIndex == keyboardOptionSelection)
            }
        case .ignore:
            Button {
                performResultAction(.ignore, result: result)
            } label: {
                Label(String(localized: "sortAssistant.preview.ignore", defaultValue: "Ignore"), systemImage: "xmark")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!result.canIgnore)
            .help(keyboardOptionHelp(index: keyboardIndex))
            .accessibilityIdentifier(SortAssistantAccessibility.resultActionButton(action))
            .overlay {
                keyboardSelectionOverlay(isSelected: keyboardIndex == keyboardOptionSelection)
            }
        case .explain:
            Button {
                performResultAction(.explain, result: result)
            } label: {
                Label(String(localized: "sortAssistant.preview.explainMore", defaultValue: "Explain"), systemImage: "questionmark.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(keyboardOptionHelp(index: keyboardIndex))
            .accessibilityIdentifier(SortAssistantAccessibility.resultActionButton(action))
            .overlay {
                keyboardSelectionOverlay(isSelected: keyboardIndex == keyboardOptionSelection)
            }
        case .undo:
            Button {
                performResultAction(.undo, result: result)
            } label: {
                Label(String(localized: "sortAssistant.undo", defaultValue: "Undo"), systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!result.canUndo)
            .help(keyboardOptionHelp(index: keyboardIndex))
            .accessibilityIdentifier(SortAssistantAccessibility.resultActionButton(action))
            .overlay {
                keyboardSelectionOverlay(isSelected: keyboardIndex == keyboardOptionSelection)
            }
        case .remember:
            Button {
                performResultAction(.remember, result: result)
            } label: {
                Label(String(localized: "sortAssistant.remember", defaultValue: "Remember"), systemImage: "bookmark")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(keyboardOptionHelp(index: keyboardIndex))
            .accessibilityIdentifier(SortAssistantAccessibility.resultActionButton(action))
            .overlay {
                keyboardSelectionOverlay(isSelected: keyboardIndex == keyboardOptionSelection)
            }
        }
    }

    private var keyboardOptions: [KeyboardOption] {
        if coordinator.semanticActionConfirmation != nil {
            return [.semanticConfirm, .semanticCancel]
        }
        if let choicePrompt = coordinator.choicePrompt {
            guard !choicePrompt.isMultiQuestion else { return [] }
            return choicePrompt.options.map { .choice($0) }
        }
        if coordinator.dimensionQuestion != nil {
            return [.dimension("urgency"), .dimension("importance"), .dimension("progress")]
        }
        if coordinator.memoryCandidate != nil {
            return [.memorySave, .memoryDiscard]
        }
        if let result = coordinator.latestResult {
            return result.actions.map { .result($0) }
        }
        return []
    }

    private func activateKeyboardOption(at index: Int) -> Bool {
        let options = keyboardOptions
        guard options.indices.contains(index) else { return false }
        keyboardOptionSelection = index
        return activateKeyboardOption(options[index])
    }

    private func activatePrimaryKeyboardOption() -> Bool {
        let options = keyboardOptions
        guard !options.isEmpty else {
            return activateFocusedCollapsedMessage()
        }
        let index = clampedKeyboardOptionSelection(count: options.count)
        keyboardOptionSelection = index
        return activateKeyboardOption(options[index])
    }

    private func activateCancelKeyboardOption() -> Bool {
        if coordinator.semanticActionConfirmation != nil {
            coordinator.dismissSemanticActionConfirmation()
            return true
        }
        if coordinator.choicePrompt != nil {
            coordinator.dismissChoicePrompt()
            return true
        }
        if coordinator.memoryCandidate != nil {
            coordinator.discardMemoryCandidate()
            return true
        }
        if keyboardFocusedMessageId != nil {
            keyboardFocusedMessageId = nil
            return true
        }
        guard let result = coordinator.latestResult,
              result.actions.contains(.ignore),
              isResultActionEnabled(.ignore, result: result) else {
            return false
        }
        performResultAction(.ignore, result: result)
        return true
    }

    private func moveKeyboardOptionSelection(delta: Int) -> Bool {
        let count = keyboardOptions.count
        guard count > 0 else {
            if moveCollapsedMessageFocus(delta: delta) {
                return true
            }
            return messageScrollController.scroll(direction: delta)
        }
        keyboardOptionSelection = (clampedKeyboardOptionSelection(count: count) + delta + count) % count
        return true
    }

    private func clampedKeyboardOptionSelection(count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(keyboardOptionSelection, 0), count - 1)
    }

    private func activateKeyboardOption(_ option: KeyboardOption) -> Bool {
        switch option {
        case .semanticConfirm:
            coordinator.confirmSemanticAction()
            return true
        case .semanticCancel:
            coordinator.dismissSemanticActionConfirmation()
            return true
        case .dimension(let id):
            guard let question = coordinator.dimensionQuestion else { return false }
            coordinator.answerDimensionQuestion(
                dimensionId: id,
                goal: question.goal,
                tabManager: tabManager,
                workspaceTabStore: workspaceTabStore
            )
            return true
        case .choice(let choice):
            coordinator.answerChoicePrompt(
                choice,
                tabManager: tabManager,
                workspaceTabStore: workspaceTabStore
            )
            return true
        case .memorySave:
            coordinator.confirmMemoryCandidate()
            return true
        case .memoryDiscard:
            coordinator.discardMemoryCandidate()
            return true
        case .result(let action):
            guard let result = coordinator.latestResult,
                  isResultActionEnabled(action, result: result) else {
                return false
            }
            performResultAction(action, result: result)
            return true
        }
    }

    private func performResultAction(_ action: SortAssistantResultAction, result: SortAssistantSortResult) {
        guard isResultActionEnabled(action, result: result) else { return }
        switch action {
        case .apply:
            coordinator.applyLatestPreview(tabManager: tabManager, workspaceTabStore: workspaceTabStore)
        case .partialApply:
            coordinator.applyLatestPreviewPartially(tabManager: tabManager, workspaceTabStore: workspaceTabStore)
        case .ignore:
            coordinator.rejectLatestPreview()
        case .explain:
            coordinator.explainLatestPreview()
        case .undo:
            coordinator.undo(tabManager: tabManager)
        case .remember:
            coordinator.createMemoryCandidateFromResult()
        }
    }

    private func isResultActionEnabled(_ action: SortAssistantResultAction, result: SortAssistantSortResult) -> Bool {
        switch action {
        case .apply:
            return result.canApply
        case .partialApply:
            return result.canApplyPartially
        case .ignore:
            return result.canIgnore
        case .undo:
            return result.canUndo
        case .explain, .remember:
            return true
        }
    }

    private func keyboardOptionHelp(index: Int) -> String {
        String(
            format: String(localized: "sortAssistant.option.keyboardHelp", defaultValue: "Press %d, or use arrow keys then Return."),
            index + 1
        )
    }

    @ViewBuilder
    private func keyboardSelectionOverlay(isSelected: Bool) -> some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(Color.accentColor.opacity(0.78), lineWidth: 1)
                .padding(-2)
        }
    }

    private func memoryCandidateCard(_ candidate: SortAssistantMemoryCandidate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(memoryCandidateTitle(candidate))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            SortAssistantMemoryCandidateTextEditor(
                placeholder: memoryCandidatePlaceholder(candidate),
                text: Binding(
                    get: { coordinator.memoryCandidate?.text ?? candidate.text },
                    set: { coordinator.updateMemoryCandidate(text: $0) }
                )
            )
            .frame(height: 58)
            HStack(spacing: 6) {
                Button(String(localized: "sortAssistant.memory.save", defaultValue: "Save")) {
                    coordinator.confirmMemoryCandidate()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help(keyboardOptionHelp(index: 0))
                .overlay {
                    keyboardSelectionOverlay(isSelected: keyboardOptionSelection == 0)
                }
                Button(String(localized: "sortAssistant.memory.discard", defaultValue: "Discard")) {
                    coordinator.discardMemoryCandidate()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(keyboardOptionHelp(index: 1))
                .overlay {
                    keyboardSelectionOverlay(isSelected: keyboardOptionSelection == 1)
                }
            }
            .font(.system(size: 10, weight: .medium))
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        )
    }

    private func memoryCandidateTitle(_ candidate: SortAssistantMemoryCandidate) -> String {
        switch candidate.target {
        case .freeSort:
            return String(localized: "sortAssistant.memory.candidate", defaultValue: "Free sort memory candidate")
        case .sprite:
            return String(localized: "sortAssistant.spriteMemory.candidate", defaultValue: "Sprite memory candidate")
        }
    }

    private func memoryCandidatePlaceholder(_ candidate: SortAssistantMemoryCandidate) -> String {
        switch candidate.target {
        case .freeSort:
            return String(localized: "sortAssistant.memory.placeholder", defaultValue: "Sorting preference")
        case .sprite:
            return String(localized: "sortAssistant.spriteMemory.placeholder", defaultValue: "Project or session memory")
        }
    }

    private var memoryStrip: some View {
        let allMemories = coordinator.memories
        let hiddenCount = max(0, allMemories.count - Self.memoryStripCollapsedCount)
        let visibleMemories = memoriesExpanded
            ? allMemories
            : Array(allMemories.prefix(Self.memoryStripCollapsedCount))

        return VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "sortAssistant.memory.saved", defaultValue: "Free sort memories"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            if memoriesExpanded && allMemories.count > Self.memoryStripCollapsedCount {
                ScrollView {
                    memoryRows(visibleMemories)
                }
                .frame(maxHeight: 128)
                .scrollIndicators(.automatic)
            } else {
                memoryRows(visibleMemories)
            }

            if hiddenCount > 0 {
                Button {
                    memoriesExpanded.toggle()
                } label: {
                    Label {
                        Text(memoryOverflowTitle(hiddenCount: hiddenCount))
                    } icon: {
                        Image(systemName: memoriesExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            }
        }
    }

    private func memoryRows(_ memories: [SortAssistantMemory]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(memories) { memory in
                memoryRow(memory)
            }
        }
    }

    private func memoryRow(_ memory: SortAssistantMemory) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(memory.text)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button {
                coordinator.deleteMemory(memory)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .help(String(localized: "sortAssistant.memory.delete", defaultValue: "Delete memory"))
        }
    }

    private func memoryOverflowTitle(hiddenCount: Int) -> String {
        if memoriesExpanded {
            return String(localized: "sortAssistant.memory.showLess", defaultValue: "Show less")
        }
        return String(
            format: String(localized: "sortAssistant.memory.showMoreFormat", defaultValue: "+%d more"),
            hiddenCount
        )
    }

    @ViewBuilder
    private var inputSection: some View {
        switch completionLayout {
        case .inline:
            VStack(alignment: .leading, spacing: Self.completionPanelSpacing) {
                if let completionModel {
                    completionPanel(completionModel)
                }
                inputRow
            }
        case .overlay:
            inputRow
                .overlay(alignment: .topLeading) {
                    if let completionModel {
                        completionPanel(completionModel)
                            .frame(height: completionOverlayHeight(for: completionModel), alignment: .top)
                            .offset(y: -completionOverlayHeight(for: completionModel) - Self.completionPanelSpacing)
                            .zIndex(10)
                    }
                }
        }
    }

    private func completionOverlayHeight(for model: SortAssistantCompletionModel) -> CGFloat {
        let rowHeight: CGFloat = 30
        let chromeHeight: CGFloat = 8
        let contentHeight = CGFloat(model.items.count) * rowHeight + chromeHeight
        return min(Self.completionPanelMaxHeight, max(34, contentHeight))
    }

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 6) {
            SortAssistantInputTextField(
                placeholder: String(localized: "sortAssistant.input.placeholder", defaultValue: "Sort workspaces or say what to remember..."),
                text: $draft,
                selection: $draftSelection,
                selectionRevision: draftSelectionRevision,
                isFocused: Binding(
                    get: { inputFocused },
                    set: { inputFocused = $0 }
                ),
                hasCompletion: completionModel != nil,
                onSubmit: sendDraft,
                onMoveCompletion: moveCompletionSelection(delta:),
                onAcceptCompletion: acceptSelectedCompletion,
                onDismissCompletion: dismissCompletion,
                keyboardOptionCount: keyboardOptions.count,
                onActivateKeyboardOption: activateKeyboardOption(at:),
                onActivatePrimaryKeyboardOption: activatePrimaryKeyboardOption,
                onCancelKeyboardOption: activateCancelKeyboardOption,
                onMoveKeyboardOption: moveKeyboardOptionSelection(delta:)
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(minHeight: 30)
            .background(
                SortAssistantPixelPanelShape(cornerLength: 4)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.92))
            )
            .overlay(
                SortAssistantPixelPanelShape(cornerLength: 4)
                    .stroke(Color.primary.opacity(inputFocused ? 0.54 : 0.32), lineWidth: 1)
            )
            .overlay(
                SortAssistantPixelPanelShape(cornerLength: 2)
                    .stroke(Color.white.opacity(0.28), lineWidth: 1)
                    .padding(2)
            )
            .accessibilityIdentifier(SortAssistantAccessibility.inputField)

            Button(action: sendDraft) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(draftTrimmed.isEmpty ? Color.secondary : Color.accentColor)
                    .frame(width: 30, height: 30)
                    .background(
                        SortAssistantPixelPanelShape(cornerLength: 4)
                            .fill(Color(nsColor: .textBackgroundColor).opacity(0.92))
                    )
                    .overlay(
                        SortAssistantPixelPanelShape(cornerLength: 4)
                            .stroke(Color.primary.opacity(draftTrimmed.isEmpty ? 0.22 : 0.46), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .disabled(draftTrimmed.isEmpty || coordinator.isSorting)
            .help(String(localized: "sortAssistant.input.send", defaultValue: "Send"))
            .accessibilityIdentifier(SortAssistantAccessibility.sendButton)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(SortAssistantAccessibility.input)
    }

    private var completionModel: SortAssistantCompletionModel? {
        guard let model = SortAssistantCompletionModel.make(
            text: draft,
            selectedRange: draftSelection,
            tabManager: tabManager
        ) else {
            return nil
        }
        guard dismissedCompletionKey != completionSuppressionKey(for: model) else {
            return nil
        }
        return model
    }

    private func completionPanel(_ model: SortAssistantCompletionModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                    completionRow(item, isSelected: index == clampedCompletionSelection(for: model))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            acceptCompletion(item, model: model)
                        }
                }
            }
        }
        .frame(maxHeight: Self.completionPanelMaxHeight)
        .scrollIndicators(.automatic)
        .padding(4)
        .background(
            SortAssistantPixelPanelShape(cornerLength: 4)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.98))
        )
        .overlay(
            SortAssistantPixelPanelShape(cornerLength: 4)
                .stroke(Color.primary.opacity(0.28), lineWidth: 1)
        )
    }

    private func completionRow(_ item: SortAssistantCompletionItem, isSelected: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: item.kind == .slashCommand ? "terminal" : "at")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(width: 14, height: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, item.subtitle == nil ? 6 : 4)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.13) : Color.clear)
        )
    }

    private var draftTrimmed: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func clampedCompletionSelection(for model: SortAssistantCompletionModel) -> Int {
        guard !model.items.isEmpty else { return 0 }
        return min(max(completionSelection, 0), model.items.count - 1)
    }

    private func moveCompletionSelection(delta: Int) {
        guard let completionModel, !completionModel.items.isEmpty else { return }
        let count = completionModel.items.count
        completionSelection = (clampedCompletionSelection(for: completionModel) + delta + count) % count
    }

    @discardableResult
    private func acceptSelectedCompletion() -> Bool {
        guard let completionModel, !completionModel.items.isEmpty else { return false }
        acceptCompletion(
            completionModel.items[clampedCompletionSelection(for: completionModel)],
            model: completionModel
        )
        return true
    }

    private func acceptCompletion(_ item: SortAssistantCompletionItem, model: SortAssistantCompletionModel) {
        let applied = model.applying(item, to: draft)
        draft = applied.text
        let acceptedSelection = NSRange(location: applied.cursorLocation, length: 0)
        draftSelection = acceptedSelection
        draftSelectionRevision += 1
        completionSelection = 0
        if let acceptedModel = SortAssistantCompletionModel.make(
            text: applied.text,
            selectedRange: acceptedSelection,
            tabManager: tabManager
        ) {
            dismissedCompletionKey = completionSuppressionKey(for: acceptedModel)
        } else {
            dismissedCompletionKey = nil
        }
        inputFocused = true
    }

    private func dismissCompletion() {
        if let completionModel {
            dismissedCompletionKey = completionSuppressionKey(for: completionModel)
        }
        completionSelection = 0
    }

    private func sendDraft() {
        let text = draftTrimmed
        guard !text.isEmpty else { return }
        draft = ""
        draftSelection = NSRange(location: 0, length: 0)
        draftSelectionRevision += 1
        completionSelection = 0
        dismissedCompletionKey = nil
        keyboardFocusedMessageId = nil
        coordinator.submit(
            text,
            tabManager: tabManager,
            workspaceTabStore: workspaceTabStore
        )
    }

    private func focusInputIfRequested() {
        guard coordinator.entryFocusSequence > 0 else { return }
        DispatchQueue.main.async {
            inputFocused = true
        }
    }

    private func completionSuppressionKey(for model: SortAssistantCompletionModel) -> String {
        let token = (draft as NSString).substring(with: model.replacementRange)
        return "\(model.kind):\(model.replacementRange.location):\(model.replacementRange.length):\(token)"
    }
}

private struct SortAssistantSuggestionCardView: View {
    let suggestion: ProactiveSuggestion
    let workspaceMetadata: String
    let icon: String
    let isCollapsed: Bool
    let semanticTitle: String?
    let onOpen: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 16, height: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(semanticTitle ?? suggestion.title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(semanticTitle == nil ? 2 : 3)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(SortAssistantAccessibility.suggestionCard(suggestion))
                    Text(workspaceMetadata)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if semanticTitle == nil,
                       !isCollapsed,
                       let reason = suggestion.reason?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !reason.isEmpty {
                        Text(reason)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)

                if !isCollapsed {
                    Text(String(format: "%.0f%%", suggestion.confidence * 100))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityLabel(String(
                            localized: "sortAssistant.suggestions.confidence",
                            defaultValue: "Confidence"
                        ))
                }
            }

            HStack(spacing: 6) {
                Button(action: onOpen) {
                    Label(
                        String(localized: "sortAssistant.suggestions.open", defaultValue: "Open"),
                        systemImage: "arrow.right.circle"
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier(SortAssistantAccessibility.suggestionOpenButton(suggestion))

                Button(action: onDismiss) {
                    Label(
                        String(localized: "sortAssistant.suggestions.dismiss", defaultValue: "Dismiss"),
                        systemImage: "xmark"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier(SortAssistantAccessibility.suggestionDismissButton(suggestion))
            }
            .font(.system(size: 10, weight: .medium))
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor.opacity(0.07))
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(SortAssistantAccessibility.suggestionCard(suggestion))
    }
}
