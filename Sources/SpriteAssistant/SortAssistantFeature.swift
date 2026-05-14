import AppKit
import CMUXWorkstream
import Foundation
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
    @FocusState private var inputFocused: Bool

    static let completionPanelMaxHeight: CGFloat = 156
    static let completionPanelSpacing: CGFloat = 6

    private enum KeyboardOption {
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
            messages
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
            inputSection
        }
        .padding(.horizontal, showsHeader ? 10 : 12)
        .padding(.vertical, showsHeader ? 8 : 12)
        .fixedSize(horizontal: false, vertical: true)
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
    }

    private var header: some View {
        HStack(spacing: 6) {
            SortAssistantMascotButton(
                presentation: .threadHeader,
                isActive: coordinator.isSorting,
                state: coordinator.mascotState,
                action: coordinator.activateEntry
            )
            .accessibilityIdentifier("SortAssistantHeaderMascotButton")
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
                                        showsAssistantAvatar: showsAssistantMessageAvatar
                                    )
                                    .id(message.id)

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
                    }
                    .frame(maxHeight: 220)
                    .scrollIndicators(.automatic)
                    .onAppear {
                        scrollToLatestMessage(proxy)
                    }
                    .onChange(of: coordinator.messages.last?.id) { _, _ in
                        scrollToLatestMessage(proxy)
                    }
                    .onChange(of: coordinator.latestResult?.id) { _, _ in
                        scrollToLatestMessage(proxy)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(prompt.options.enumerated()), id: \.element.id) { index, option in
                    Button {
                        coordinator.answerChoicePrompt(
                            option,
                            tabManager: tabManager,
                            workspaceTabStore: workspaceTabStore
                        )
                    } label: {
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: "target")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
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
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 3)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.primary.opacity(0.045))
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
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor.opacity(0.075))
        )
    }

    @ViewBuilder
    private func resultMarkdown(_ markdown: String) -> some View {
        if let attributed = try? AttributedString(markdown: markdown) {
            Text(attributed)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
        } else {
            Text(markdown)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(2)
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
            .overlay {
                keyboardSelectionOverlay(isSelected: keyboardIndex == keyboardOptionSelection)
            }
        }
    }

    private var keyboardOptions: [KeyboardOption] {
        if let choicePrompt = coordinator.choicePrompt {
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
        guard !options.isEmpty else { return false }
        let index = clampedKeyboardOptionSelection(count: options.count)
        keyboardOptionSelection = index
        return activateKeyboardOption(options[index])
    }

    private func activateCancelKeyboardOption() -> Bool {
        if coordinator.choicePrompt != nil {
            coordinator.dismissChoicePrompt()
            return true
        }
        if coordinator.memoryCandidate != nil {
            coordinator.discardMemoryCandidate()
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
        guard count > 0 else { return false }
        keyboardOptionSelection = (clampedKeyboardOptionSelection(count: count) + delta + count) % count
        return true
    }

    private func clampedKeyboardOptionSelection(count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(keyboardOptionSelection, 0), count - 1)
    }

    private func activateKeyboardOption(_ option: KeyboardOption) -> Bool {
        switch option {
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
            TextField(
                memoryCandidatePlaceholder(candidate),
                text: Binding(
                    get: { coordinator.memoryCandidate?.text ?? candidate.text },
                    set: { coordinator.updateMemoryCandidate(text: $0) }
                ),
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11))
            .lineLimit(2...5)
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
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "sortAssistant.memory.saved", defaultValue: "Free sort memories"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(coordinator.memories.prefix(3)) { memory in
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
        }
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
            .accessibilityIdentifier("SortAssistantInput")

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
        }
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

    private func acceptSelectedCompletion() {
        guard let completionModel, !completionModel.items.isEmpty else { return }
        acceptCompletion(
            completionModel.items[clampedCompletionSelection(for: completionModel)],
            model: completionModel
        )
    }

    private func acceptCompletion(_ item: SortAssistantCompletionItem, model: SortAssistantCompletionModel) {
        let applied = model.applying(item, to: draft)
        draft = applied.text
        draftSelection = NSRange(location: applied.cursorLocation, length: 0)
        draftSelectionRevision += 1
        completionSelection = 0
        dismissedCompletionKey = nil
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

private final class SortAssistantNativeTextField: NSTextField {
    var onHandleKeyEvent: ((NSEvent, NSTextView?) -> Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        usesSingleLineMode = true
        isEditable = true
        isSelectable = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func keyDown(with event: NSEvent) {
        if (currentEditor() as? NSTextView)?.hasMarkedText() == true {
            super.keyDown(with: event)
            return
        }
        if onHandleKeyEvent?(event, currentEditor() as? NSTextView) == true {
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if (currentEditor() as? NSTextView)?.hasMarkedText() == true {
            return super.performKeyEquivalent(with: event)
        }
        if onHandleKeyEvent?(event, currentEditor() as? NSTextView) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private struct SortAssistantInputTextField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    @Binding var selection: NSRange
    let selectionRevision: Int
    @Binding var isFocused: Bool
    let hasCompletion: Bool
    let onSubmit: () -> Void
    let onMoveCompletion: (Int) -> Void
    let onAcceptCompletion: () -> Void
    let onDismissCompletion: () -> Void
    let keyboardOptionCount: Int
    let onActivateKeyboardOption: (Int) -> Bool
    let onActivatePrimaryKeyboardOption: () -> Bool
    let onCancelKeyboardOption: () -> Bool
    let onMoveKeyboardOption: (Int) -> Bool

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SortAssistantInputTextField
        var isProgrammaticMutation = false
        weak var parentField: SortAssistantNativeTextField?
        var pendingFocusRequest = false
        var appliedSelectionRevision = 0

        init(parent: SortAssistantInputTextField) {
            self.parent = parent
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            publishSelection(from: obj.object as? NSTextField)
            if !parent.isFocused {
                DispatchQueue.main.async {
                    self.parent.isFocused = true
                }
            }
        }

        func controlTextDidChange(_ obj: Notification) {
            guard !isProgrammaticMutation,
                  let field = obj.object as? NSTextField else {
                return
            }
            parent.text = field.stringValue
            publishSelection(from: field)
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            publishSelection(from: obj.object as? NSTextField)
            if parent.isFocused {
                DispatchQueue.main.async {
                    self.parent.isFocused = false
                }
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveDown(_:)):
                if parent.hasCompletion {
                    parent.onMoveCompletion(+1)
                } else if parent.isDraftEmpty, parent.onMoveKeyboardOption(+1) {
                    parent.selection = textView.selectedRange()
                } else {
                    return false
                }
                parent.selection = textView.selectedRange()
                return true
            case #selector(NSResponder.moveUp(_:)):
                if parent.hasCompletion {
                    parent.onMoveCompletion(-1)
                } else if parent.isDraftEmpty, parent.onMoveKeyboardOption(-1) {
                    parent.selection = textView.selectedRange()
                } else {
                    return false
                }
                parent.selection = textView.selectedRange()
                return true
            case #selector(NSResponder.insertTab(_:)):
                guard parent.hasCompletion else { return false }
                parent.onAcceptCompletion()
                return true
            case #selector(NSResponder.insertNewline(_:)):
                guard !textView.hasMarkedText() else { return false }
                if parent.hasCompletion {
                    parent.onAcceptCompletion()
                } else if parent.isDraftEmpty, parent.onActivatePrimaryKeyboardOption() {
                    parent.selection = textView.selectedRange()
                } else {
                    parent.selection = textView.selectedRange()
                    parent.onSubmit()
                }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                guard !textView.hasMarkedText() else { return false }
                if parent.hasCompletion {
                    parent.onDismissCompletion()
                } else if parent.isDraftEmpty, parent.onCancelKeyboardOption() {
                    parent.selection = textView.selectedRange()
                } else {
                    parent.selection = textView.selectedRange()
                    parent.isFocused = false
                    parentField?.window?.makeFirstResponder(nil)
                }
                return true
            default:
                parent.selection = textView.selectedRange()
                return false
            }
        }

        func handleKeyEvent(_ event: NSEvent, editor: NSTextView?) -> Bool {
            guard !(editor?.hasMarkedText() ?? false) else { return false }
            let flags = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .subtracting([.numericPad, .function, .capsLock])
            guard flags.isEmpty else { return false }

            if parent.isDraftEmpty, !parent.hasCompletion {
                if let optionIndex = SortAssistantInputTextField.keyboardOptionIndex(for: event.keyCode),
                   optionIndex < parent.keyboardOptionCount {
                    parent.onActivateKeyboardOption(optionIndex)
                    publishSelection(from: parentField)
                    return true
                }
                switch event.keyCode {
                case 123, 126:
                    guard parent.onMoveKeyboardOption(-1) else { return false }
                    publishSelection(from: parentField)
                    return true
                case 124, 125:
                    guard parent.onMoveKeyboardOption(+1) else { return false }
                    publishSelection(from: parentField)
                    return true
                case 36, 76:
                    guard parent.onActivatePrimaryKeyboardOption() else { break }
                    publishSelection(from: parentField)
                    return true
                case 53:
                    guard parent.onCancelKeyboardOption() else { break }
                    publishSelection(from: parentField)
                    return true
                default:
                    break
                }
            }

            switch event.keyCode {
            case 125:
                guard parent.hasCompletion else { return false }
                parent.onMoveCompletion(+1)
                publishSelection(from: parentField)
                return true
            case 126:
                guard parent.hasCompletion else { return false }
                parent.onMoveCompletion(-1)
                publishSelection(from: parentField)
                return true
            case 48:
                guard parent.hasCompletion else { return false }
                parent.onAcceptCompletion()
                return true
            case 36, 76:
                if parent.hasCompletion {
                    parent.onAcceptCompletion()
                } else {
                    parent.onSubmit()
                }
                return true
            case 53:
                if parent.hasCompletion {
                    parent.onDismissCompletion()
                } else {
                    parent.isFocused = false
                    parentField?.window?.makeFirstResponder(nil)
                }
                return true
            default:
                return false
            }
        }

        func publishSelection(from field: NSTextField?) {
            let textLength = ((field?.stringValue ?? "") as NSString).length
            let selectedRange = (field?.currentEditor() as? NSTextView)?.selectedRange()
                ?? NSRange(location: textLength, length: 0)
            if parent.selection != selectedRange {
                parent.selection = selectedRange
            }
        }

        func applySelectionToEditorIfNeeded(
            field: SortAssistantNativeTextField,
            force: Bool
        ) {
            guard let editor = field.currentEditor() as? NSTextView,
                  !editor.hasMarkedText() else {
                return
            }
            let targetSelection = SortAssistantInputTextField.clamped(parent.selection, text: editor.string)
            guard force || editor.selectedRange() != targetSelection else { return }
            editor.setSelectedRange(targetSelection)

            let expectedText = parent.text
            let expectedSelection = targetSelection
            let expectedRevision = parent.selectionRevision
            DispatchQueue.main.async { [weak self, weak field] in
                guard let self,
                      self.parent.selectionRevision == expectedRevision,
                      self.parent.text == expectedText,
                      self.parent.selection == expectedSelection,
                      let field,
                      let editor = field.currentEditor() as? NSTextView,
                      editor.string == expectedText,
                      !editor.hasMarkedText() else {
                    return
                }
                if editor.selectedRange() != expectedSelection {
                    editor.setSelectedRange(expectedSelection)
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> SortAssistantNativeTextField {
        let field = SortAssistantNativeTextField(frame: .zero)
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.stringValue = text
        field.setAccessibilityIdentifier("SortAssistantInputField")
        field.onHandleKeyEvent = { [weak coordinator = context.coordinator] event, editor in
            coordinator?.handleKeyEvent(event, editor: editor) ?? false
        }
        context.coordinator.parentField = field
        return field
    }

    func updateNSView(_ nsView: SortAssistantNativeTextField, context: Context) {
        context.coordinator.parent = self
        context.coordinator.parentField = nsView
        nsView.placeholderString = placeholder
        let forceSelection = context.coordinator.appliedSelectionRevision != selectionRevision

        if let editor = nsView.currentEditor() as? NSTextView {
            if editor.string != text, !editor.hasMarkedText() {
                context.coordinator.isProgrammaticMutation = true
                editor.string = text
                nsView.stringValue = text
                context.coordinator.isProgrammaticMutation = false
            }
            context.coordinator.applySelectionToEditorIfNeeded(
                field: nsView,
                force: forceSelection
            )
            context.coordinator.appliedSelectionRevision = selectionRevision
        } else if nsView.stringValue != text {
            nsView.stringValue = text
        }

        guard let window = nsView.window else { return }
        let firstResponder = window.firstResponder
        let isFirstResponder =
            firstResponder === nsView ||
            nsView.currentEditor() != nil ||
            ((firstResponder as? NSTextView)?.delegate as? NSTextField) === nsView

        if isFocused, !isFirstResponder, !context.coordinator.pendingFocusRequest {
            context.coordinator.pendingFocusRequest = true
            DispatchQueue.main.async { [weak nsView, weak coordinator = context.coordinator] in
                coordinator?.pendingFocusRequest = false
                guard let coordinator, coordinator.parent.isFocused else { return }
                guard let nsView, let window = nsView.window else { return }
                window.makeFirstResponder(nsView)
                coordinator.applySelectionToEditorIfNeeded(field: nsView, force: true)
                coordinator.appliedSelectionRevision = coordinator.parent.selectionRevision
            }
        }
    }

    static func dismantleNSView(_ nsView: SortAssistantNativeTextField, coordinator: Coordinator) {
        nsView.delegate = nil
        nsView.onHandleKeyEvent = nil
        coordinator.parentField = nil
    }

    private var isDraftEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func keyboardOptionIndex(for keyCode: UInt16) -> Int? {
        switch keyCode {
        case 18, 83: return 0
        case 19, 84: return 1
        case 20, 85: return 2
        case 21, 86: return 3
        case 23, 87: return 4
        case 22, 88: return 5
        case 26, 89: return 6
        case 28, 91: return 7
        case 25, 92: return 8
        default: return nil
        }
    }

    private static func clamped(_ range: NSRange, text: String) -> NSRange {
        let length = (text as NSString).length
        let location = min(max(range.location, 0), length)
        let rangeLength = min(max(range.length, 0), length - location)
        return NSRange(location: location, length: rangeLength)
    }
}

private struct SortAssistantMessageRow: View {
    let message: SortAssistantMessage
    var showsAssistantAvatar = true

    @State private var isExpanded = false
    @State private var copied = false
    @State private var copyFeedbackToken: UUID?
    private let collapsedLineLimit = 6

    var body: some View {
        Group {
            if message.kind == .user {
                userBubble
            } else {
                assistantBubble
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var assistantBubble: some View {
        HStack(alignment: .bottom, spacing: 7) {
            if showsAssistantAvatar {
                SortAssistantMascotAvatar(size: 28, state: avatarState)
                    .padding(.bottom, 1)
            }

            bubbleContent(
                foreground: assistantForeground,
                fill: assistantFill,
                stroke: assistantStroke,
                tailEdge: .leading,
                includesStatusIcon: message.kind != .assistant
            )

            Spacer(minLength: showsAssistantAvatar ? 28 : 44)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var userBubble: some View {
        HStack(alignment: .bottom, spacing: 7) {
            Spacer(minLength: 52)

            bubbleContent(
                foreground: Color.primary,
                fill: Color.primary.opacity(0.070),
                stroke: Color.primary.opacity(0.060),
                tailEdge: .trailing,
                includesStatusIcon: false
            )
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func bubbleContent(
        foreground: Color,
        fill: Color,
        stroke: Color,
        tailEdge: SortAssistantBubbleTail.Edge,
        includesStatusIcon: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 6) {
                if includesStatusIcon {
                    Image(systemName: message.icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(message.tint)
                        .padding(.top, 2)
                }

                Text(message.text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(foreground)
                    .lineLimit(isMessageExpanded ? nil : collapsedLineLimit)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if showsCopyButton || showsExpandButton {
                HStack(spacing: 8) {
                    if showsCopyButton {
                        Button {
                            copyMessageText()
                        } label: {
                            Label(
                                copied
                                    ? String(localized: "sortAssistant.copy.copied", defaultValue: "Copied")
                                    : String(localized: "sortAssistant.copy", defaultValue: "Copy"),
                                systemImage: copied ? "checkmark" : "doc.on.doc"
                            )
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.mini)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(copied ? Color.accentColor : Color.secondary)
                        .help(String(localized: "sortAssistant.copy.help", defaultValue: "Copy this answer"))
                    }

                    if showsExpandButton {
                        Button {
                            withAnimation(.easeInOut(duration: 0.12)) {
                                isExpanded.toggle()
                            }
                        } label: {
                            Label(
                                isExpanded
                                    ? String(localized: "sortAssistant.message.collapse", defaultValue: "Collapse")
                                    : String(localized: "sortAssistant.message.expand", defaultValue: "Expand"),
                                systemImage: isExpanded ? "chevron.up" : "chevron.down"
                            )
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.mini)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.secondary)
                        .help(
                            isExpanded
                                ? String(localized: "sortAssistant.message.collapse.help", defaultValue: "Collapse this answer")
                                : String(localized: "sortAssistant.message.expand.help", defaultValue: "Expand this answer")
                        )
                    }
                }
            }
        }
        .padding(.horizontal, message.kind == .assistant ? 2 : 10)
        .padding(.vertical, message.kind == .assistant ? 1 : 7)
        .frame(maxWidth: 254, alignment: .leading)
        .background(
            SortAssistantPixelPanelShape(cornerLength: message.kind == .assistant ? 0 : 4)
                .fill(fill)
        )
        .overlay(
            SortAssistantPixelPanelShape(cornerLength: message.kind == .assistant ? 0 : 4)
                .stroke(stroke, lineWidth: message.kind == .assistant ? 0 : 1)
        )
        .overlay(alignment: tailEdge.alignment) {
            if message.kind != .assistant {
                SortAssistantBubbleTail(edge: tailEdge)
                    .fill(fill)
                    .frame(width: 8, height: 10)
                    .offset(x: tailEdge.offsetX)
            }
        }
    }

    private var showsCopyButton: Bool {
        message.kind == .assistant || message.kind == .error
    }

    private var showsExpandButton: Bool {
        guard message.kind == .assistant || message.kind == .error else { return false }
        return message.text.count > 260
            || message.text.filter { $0 == "\n" }.count + 1 > collapsedLineLimit
    }

    private var isMessageExpanded: Bool {
        !showsExpandButton || isExpanded
    }

    private func copyMessageText() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(message.text, forType: .string)

        let token = UUID()
        copyFeedbackToken = token
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard copyFeedbackToken == token else { return }
            copied = false
            copyFeedbackToken = nil
        }
    }

    private var assistantForeground: Color {
        message.kind == .error ? Color.red : Color.primary
    }

    private var avatarState: SortAssistantMascotState {
        switch message.kind {
        case .progress:
            return .review
        case .error:
            return .failed
        case .assistant:
            return .idle
        case .user:
            return .idle
        }
    }

    private var assistantFill: Color {
        switch message.kind {
        case .assistant:
            return .clear
        case .progress:
            return Color.blue.opacity(0.075)
        case .error:
            return Color.red.opacity(0.075)
        case .user:
            return Color.primary.opacity(0.070)
        }
    }

    private var assistantStroke: Color {
        switch message.kind {
        case .assistant:
            return .clear
        case .progress:
            return Color.blue.opacity(0.14)
        case .error:
            return Color.red.opacity(0.14)
        case .user:
            return Color.primary.opacity(0.060)
        }
    }
}

struct SortAssistantPixelPanelShape: InsettableShape {
    var cornerLength: CGFloat = 6
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let bounds = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let step = min(max(cornerLength, 0), bounds.width / 3, bounds.height / 3)

        guard step > 0 else {
            path.addRect(bounds)
            return path
        }

        path.move(to: CGPoint(x: bounds.minX + step, y: bounds.minY))
        path.addLine(to: CGPoint(x: bounds.maxX - step, y: bounds.minY))
        path.addLine(to: CGPoint(x: bounds.maxX - step, y: bounds.minY + step))
        path.addLine(to: CGPoint(x: bounds.maxX, y: bounds.minY + step))
        path.addLine(to: CGPoint(x: bounds.maxX, y: bounds.maxY - step))
        path.addLine(to: CGPoint(x: bounds.maxX - step, y: bounds.maxY - step))
        path.addLine(to: CGPoint(x: bounds.maxX - step, y: bounds.maxY))
        path.addLine(to: CGPoint(x: bounds.minX + step, y: bounds.maxY))
        path.addLine(to: CGPoint(x: bounds.minX + step, y: bounds.maxY - step))
        path.addLine(to: CGPoint(x: bounds.minX, y: bounds.maxY - step))
        path.addLine(to: CGPoint(x: bounds.minX, y: bounds.minY + step))
        path.addLine(to: CGPoint(x: bounds.minX + step, y: bounds.minY + step))
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> SortAssistantPixelPanelShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}

private struct SortAssistantBubbleTail: Shape {
    enum Edge {
        case leading
        case trailing

        var alignment: Alignment {
            switch self {
            case .leading: return .leading
            case .trailing: return .trailing
            }
        }

        var offsetX: CGFloat {
            switch self {
            case .leading: return -5
            case .trailing: return 5
            }
        }
    }

    let edge: Edge

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let tab = rect.width * 0.52
        let upper = rect.height * 0.32
        let lower = rect.height * 0.68

        switch edge {
        case .leading:
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX + tab, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX + tab, y: upper))
            path.addLine(to: CGPoint(x: rect.minX, y: upper))
            path.addLine(to: CGPoint(x: rect.minX, y: lower))
            path.addLine(to: CGPoint(x: rect.minX + tab, y: lower))
            path.addLine(to: CGPoint(x: rect.minX + tab, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        case .trailing:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - tab, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - tab, y: upper))
            path.addLine(to: CGPoint(x: rect.maxX, y: upper))
            path.addLine(to: CGPoint(x: rect.maxX, y: lower))
            path.addLine(to: CGPoint(x: rect.maxX - tab, y: lower))
            path.addLine(to: CGPoint(x: rect.maxX - tab, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
        path.closeSubpath()
        return path
    }
}

struct SortAssistantMessage: Identifiable, Equatable {
    enum Kind: Equatable {
        case user
        case assistant
        case progress
        case error
    }

    let id = UUID()
    let kind: Kind
    let text: String

    var icon: String {
        switch kind {
        case .user: return "person"
        case .assistant: return "sparkles"
        case .progress: return "arrow.triangle.2.circlepath"
        case .error: return "exclamationmark.triangle"
        }
    }

    var tint: Color {
        switch kind {
        case .user: return .secondary
        case .assistant: return .accentColor
        case .progress: return .blue
        case .error: return .red
        }
    }
}

struct SortAssistantDimensionQuestion: Equatable {
    let goal: String
    let mode: SortAssistantRunMode
}

struct SortAssistantChoicePrompt: Identifiable, Equatable, Sendable {
    struct Option: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
        let subtitle: String?
        let goal: String
    }

    let id: UUID
    let title: String
    let message: String?
    let options: [Option]
    let followUpIntent: SortAssistantIntent?
    let forceApply: Bool
    let workspaceTarget: SortAssistantWorkspaceTarget?

    init(
        id: UUID = UUID(),
        title: String,
        message: String?,
        options: [Option],
        followUpIntent: SortAssistantIntent? = nil,
        forceApply: Bool = false,
        workspaceTarget: SortAssistantWorkspaceTarget? = nil
    ) {
        self.id = id
        self.title = title
        self.message = message
        self.options = options
        self.followUpIntent = followUpIntent
        self.forceApply = forceApply
        self.workspaceTarget = workspaceTarget
    }

    func preparedForFollowUp(
        intent: SortAssistantIntent,
        forceApply: Bool,
        workspaceTarget: SortAssistantWorkspaceTarget?
    ) -> SortAssistantChoicePrompt {
        SortAssistantChoicePrompt(
            id: id,
            title: title,
            message: message,
            options: options,
            followUpIntent: followUpIntent ?? intent,
            forceApply: self.forceApply || forceApply,
            workspaceTarget: self.workspaceTarget ?? workspaceTarget
        )
    }
}

enum SortAssistantResultMode: Equatable, Sendable {
    case preview
    case applied
}

enum SortAssistantRunMode: Equatable, Sendable {
    case preview
    case apply

    var assistantContextValue: String {
        switch self {
        case .preview: return "preview"
        case .apply: return "applied"
        }
    }
}

enum SortAssistantResultAction: String, Codable, Hashable, CaseIterable, Sendable {
    case apply
    case partialApply = "partial_apply"
    case ignore
    case explain
    case undo
    case remember
}

struct SortAssistantSortResult: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let goal: String
    let dimensionLabel: String
    let changes: [String]
    let rationale: String?
    let patchId: UUID?
    var mode: SortAssistantResultMode
    var canUndo: Bool
    var canApply: Bool
    var canApplyPartially: Bool
    var canIgnore: Bool
    var actions: [SortAssistantResultAction]
}

struct SortAssistantMemory: Identifiable, Codable, Equatable {
    let id: UUID
    var text: String
    let createdAt: Date
}

struct SortAssistantMemoryCandidate: Identifiable, Equatable {
    enum Target: Equatable {
        case freeSort
        case sprite
    }

    let id = UUID()
    var text: String
    let sourceSummary: String?
    let target: Target

    init(text: String, sourceSummary: String?, target: Target = .freeSort) {
        self.text = text
        self.sourceSummary = sourceSummary
        self.target = target
    }
}

struct SortAssistantResultPresentation: Equatable {
    let markdown: String?
    let actions: [SortAssistantResultAction]

    static func parse(_ raw: String?) -> SortAssistantResultPresentation {
        guard let raw else {
            return SortAssistantResultPresentation(markdown: nil, actions: [])
        }
        var markdown = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var parsedActions: [SortAssistantResultAction] = []

        if markdown.hasPrefix("---\n"),
           let closingRange = markdown.range(of: "\n---", range: markdown.index(markdown.startIndex, offsetBy: 4)..<markdown.endIndex) {
            let metaBlock = String(markdown[markdown.index(markdown.startIndex, offsetBy: 4)..<closingRange.lowerBound])
            parsedActions.append(contentsOf: actions(fromFrontMatter: metaBlock))
            let bodyStart = markdown.index(closingRange.upperBound, offsetBy: 0)
            markdown = String(markdown[bodyStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let commentRange = markdown.range(of: "<!-- cmux-meta:"),
           let endRange = markdown.range(of: "-->", range: commentRange.upperBound..<markdown.endIndex) {
            let json = String(markdown[commentRange.upperBound..<endRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            parsedActions.append(contentsOf: actions(fromJSON: json))
            markdown.removeSubrange(commentRange.lowerBound..<endRange.upperBound)
            markdown = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return SortAssistantResultPresentation(
            markdown: markdown.isEmpty ? nil : markdown,
            actions: unique(parsedActions)
        )
    }

    private static func actions(fromFrontMatter metaBlock: String) -> [SortAssistantResultAction] {
        for line in metaBlock.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "-", with: "_")
            guard ["cmux_result_actions", "result_actions", "actions"].contains(key) else { continue }
            return actions(fromList: parts[1])
        }
        return []
    }

    private static func actions(fromJSON json: String) -> [SortAssistantResultAction] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        let value = object["cmux_result_actions"] ?? object["result_actions"] ?? object["actions"]
        if let list = value as? [String] {
            return list.compactMap(SortAssistantResultAction.init(rawValue:))
        }
        if let string = value as? String {
            return actions(fromList: string)
        }
        return []
    }

    private static func actions(fromList raw: String) -> [SortAssistantResultAction] {
        raw
            .trimmingCharacters(in: CharacterSet(charactersIn: " []"))
            .split { character in
                character == "," || character == " " || character == "\t"
            }
            .map { token in
                token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'[] \t"))
            }
            .compactMap(SortAssistantResultAction.init(rawValue:))
    }

    private static func unique(_ actions: [SortAssistantResultAction]) -> [SortAssistantResultAction] {
        var seen: Set<SortAssistantResultAction> = []
        return actions.filter { seen.insert($0).inserted }
    }
}

private struct SortAssistantMemoryEvent: Codable {
    enum EventType: String, Codable {
        case created
    }

    let schemaVersion: String
    let eventType: EventType
    let memoryId: String
    let text: String
    let createdAt: String
}

private enum SortAssistantWorkstreamPersistence {
    static let shared = WorkstreamPersistence(fileURL: WorkstreamPersistence.defaultFileURL())
}

private enum SpriteMemorySource: Equatable {
    case workspace(URL)
}

private struct SpriteMemoryLoadResult {
    let memories: [SortAssistantMemory]
    let sources: [UUID: SpriteMemorySource]
}

private enum SpriteWorkspaceMemoryDocument {
    static let fileName = "memory.md"
    private static let startMarker = "<!-- cmux-memory:start -->"
    private static let endMarker = "<!-- cmux-memory:end -->"
    private static let idPrefix = "<!-- cmux-memory:id="
    private static let iso8601Formatter = ISO8601DateFormatter()

    static func fileURL(directory: String?) -> URL? {
        guard let directory else { return nil }
        let expanded = (directory.trimmingCharacters(in: .whitespacesAndNewlines) as NSString)
            .expandingTildeInPath
        guard !expanded.isEmpty else { return nil }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return URL(fileURLWithPath: expanded, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
            .standardizedFileURL
    }

    static func load(directory: String?) -> SpriteMemoryLoadResult {
        guard let url = fileURL(directory: directory),
              let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) else {
            return SpriteMemoryLoadResult(memories: [], sources: [:])
        }

        var memories: [SortAssistantMemory] = []
        var sources: [UUID: SpriteMemorySource] = [:]
        for line in content.components(separatedBy: .newlines) {
            guard let id = memoryId(in: line),
                  let text = memoryText(in: line) else {
                continue
            }
            let memory = SortAssistantMemory(
                id: id,
                text: text,
                createdAt: createdAt(in: line) ?? Date.distantPast
            )
            memories.append(memory)
            sources[id] = .workspace(url)
        }

        return SpriteMemoryLoadResult(
            memories: memories.sorted { $0.createdAt > $1.createdAt },
            sources: sources
        )
    }

    @discardableResult
    static func append(_ memory: SortAssistantMemory, directory: String?) throws -> URL? {
        guard let url = fileURL(directory: directory) else { return nil }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var content = (try? String(contentsOf: url, encoding: .utf8)) ?? "# Memory\n"
        let entry = entryLine(for: memory)
        if let start = content.range(of: startMarker),
           let end = content.range(of: endMarker, range: start.upperBound..<content.endIndex) {
            var section = String(content[start.upperBound..<end.lowerBound])
            if !section.hasSuffix("\n") {
                section += "\n"
            }
            section += entry + "\n"
            content.replaceSubrange(start.upperBound..<end.lowerBound, with: section)
        } else {
            if !content.hasSuffix("\n") {
                content += "\n"
            }
            if !content.hasSuffix("\n\n") {
                content += "\n"
            }
            content += """
            \(startMarker)
            ## cmux memories

            \(entry)
            \(endMarker)
            """
            content += "\n"
        }
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @discardableResult
    static func delete(memoryId: UUID?, containing text: String?, from url: URL) throws -> Int {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        let normalizedText = text?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        var removed = 0
        let kept = content.components(separatedBy: .newlines).filter { line in
            guard line.contains(idPrefix) else { return true }
            let matchesId = memoryId != nil && Self.memoryId(in: line) == memoryId
            let matchesText = normalizedText?.isEmpty == false
                && (memoryText(in: line)?.lowercased().contains(normalizedText ?? "") == true)
            if matchesId || matchesText {
                removed += 1
                return false
            }
            return true
        }
        guard removed > 0 else { return 0 }
        try kept.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return removed
    }

    private static func entryLine(for memory: SortAssistantMemory) -> String {
        "- \(iso8601Formatter.string(from: memory.createdAt)) - \(sanitize(memory.text)) \(idPrefix)\(memory.id.uuidString) -->"
    }

    private static func memoryId(in line: String) -> UUID? {
        guard let start = line.range(of: idPrefix),
              let end = line.range(of: "-->", range: start.upperBound..<line.endIndex) else {
            return nil
        }
        let raw = line[start.upperBound..<end.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return UUID(uuidString: raw)
    }

    private static func memoryText(in line: String) -> String? {
        let withoutComment: Substring
        if let comment = line.range(of: idPrefix) {
            withoutComment = line[..<comment.lowerBound]
        } else {
            withoutComment = Substring(line)
        }
        var text = String(withoutComment)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("-") || text.hasPrefix("*") {
            text.removeFirst()
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let separator = text.range(of: " - "),
           looksLikeISO8601Prefix(String(text[..<separator.lowerBound])) {
            text = String(text[separator.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.isEmpty ? nil : text
    }

    private static func createdAt(in line: String) -> Date? {
        var text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("-") || text.hasPrefix("*") {
            text.removeFirst()
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let separator = text.range(of: " - ") else { return nil }
        let rawDate = String(text[..<separator.lowerBound])
        guard looksLikeISO8601Prefix(rawDate) else { return nil }
        return iso8601Formatter.date(from: rawDate)
    }

    private static func looksLikeISO8601Prefix(_ text: String) -> Bool {
        text.count >= 20 && text.contains("T") && text.hasSuffix("Z")
    }

    private static func sanitize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "<!--", with: "")
            .replacingOccurrences(of: "-->", with: "")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum SortAssistantIntent: String, Equatable, Sendable {
    case askContext = "ask_context"
    case clearSession = "clear_session"
    case explainCurrentOrder = "explain_current_order"
    case proposeSort = "propose_sort"
    case applySort = "apply_sort"
    case manualReorderFeedback = "manual_reorder_feedback"
    case rememberPreference = "remember_preference"
    case forgetPreference = "forget_preference"
    case rememberSpriteMemory = "remember_sprite_memory"
    case forgetSpriteMemory = "forget_sprite_memory"
    case undoSort = "undo_sort"
    case normalChat = "normal_chat"
}

struct SortAssistantIntentDecision: Equatable, Sendable {
    let intent: SortAssistantIntent
    let confidence: Double
    let reason: String?
}

enum SortAssistantActionMode: String, Equatable, Sendable {
    case readOnly = "read_only"
    case previewOnly = "preview_only"
    case applyAllowed = "apply_allowed"
}

enum SortAssistantMemoryWritePolicy: String, Equatable, Sendable {
    case none
    case eventLog = "event_log"
    case candidate
    case longTerm = "long_term"
}

private enum SortAssistantClaudeWorkDirectory {
    static func url() throws -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let url = base
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("sprite-assistant-claude", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

struct SortAssistantActionRoute: Equatable, Sendable {
    let mode: SortAssistantActionMode
    let needsConfirmation: Bool
    let allowedTools: [String]
    let memoryWritePolicy: SortAssistantMemoryWritePolicy

    var runMode: SortAssistantRunMode {
        mode == .applyAllowed && !needsConfirmation ? .apply : .preview
    }
}

struct SortAssistantSlashCommand: Equatable {
    enum Operation: Equatable {
        case clearSession
        case help
        case askContext(String)
        case undoSort
        case explainCurrentOrder(String)
        case proposeSort(String)
        case applySort(String)
        case listMemories
        case rememberSpriteMemory(String)
        case forgetSpriteMemory(String)
        case rememberFreeSortMemory(String)
        case forgetFreeSortMemory(String)
        case setPinned(Bool)
        case setLocked(Bool)
        case selectWorkspace
    }

    let name: String
    let argument: String
    let operation: Operation

    static func parse(_ text: String) -> SortAssistantSlashCommand? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let nameEnd = trimmed.firstIndex(where: { $0.isWhitespace }) ?? trimmed.endIndex
        let name = String(trimmed[..<nameEnd]).lowercased()
        let argument = String(trimmed[nameEnd...])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        switch name {
        case "/clear", "/new":
            return SortAssistantSlashCommand(name: name, argument: argument, operation: .clearSession)
        case "/help", "/?":
            return SortAssistantSlashCommand(name: name, argument: argument, operation: .help)
        case "/repo", "/git":
            let goal = argument.isEmpty
                ? String(localized: "sortAssistant.slash.repo.defaultGoal", defaultValue: "Tell me the current repository context.")
                : argument
            return SortAssistantSlashCommand(name: name, argument: argument, operation: .askContext(goal))
        case "/context", "/ctx":
            let goal = argument.isEmpty
                ? String(localized: "sortAssistant.slash.context.defaultGoal", defaultValue: "Summarize the current workspace context.")
                : argument
            return SortAssistantSlashCommand(name: name, argument: argument, operation: .askContext(goal))
        case "/undo":
            return SortAssistantSlashCommand(
                name: name,
                argument: argument,
                operation: .undoSort
            )
        case "/explain":
            let goal = argument.isEmpty
                ? String(localized: "sortAssistant.slash.explain.defaultGoal", defaultValue: "Explain the current workspace order.")
                : argument
            return SortAssistantSlashCommand(name: name, argument: argument, operation: .explainCurrentOrder(goal))
        case "/sort":
            let goal = argument.isEmpty
                ? String(localized: "sortAssistant.slash.sort.defaultGoal", defaultValue: "Suggest a workspace sort.")
                : argument
            return SortAssistantSlashCommand(name: name, argument: argument, operation: .proposeSort(goal))
        case "/apply":
            let goal = argument.isEmpty
                ? String(localized: "sortAssistant.slash.apply.defaultGoal", defaultValue: "Apply a workspace sort using the current signals.")
                : argument
            return SortAssistantSlashCommand(name: name, argument: argument, operation: .applySort(goal))
        case "/memory", "/mem":
            return SortAssistantSlashCommand(
                name: name,
                argument: argument,
                operation: .listMemories
            )
        case "/remember":
            return SortAssistantSlashCommand(
                name: name,
                argument: argument,
                operation: .rememberSpriteMemory(argument)
            )
        case "/forget":
            return SortAssistantSlashCommand(
                name: name,
                argument: argument,
                operation: .forgetSpriteMemory(argument)
            )
        case "/remember-sort":
            return SortAssistantSlashCommand(
                name: name,
                argument: argument,
                operation: .rememberFreeSortMemory(argument)
            )
        case "/forget-sort":
            return SortAssistantSlashCommand(
                name: name,
                argument: argument,
                operation: .forgetFreeSortMemory(argument)
            )
        case "/pin":
            return SortAssistantSlashCommand(name: name, argument: argument, operation: .setPinned(true))
        case "/unpin":
            return SortAssistantSlashCommand(name: name, argument: argument, operation: .setPinned(false))
        case "/lock":
            return SortAssistantSlashCommand(name: name, argument: argument, operation: .setLocked(true))
        case "/unlock":
            return SortAssistantSlashCommand(name: name, argument: argument, operation: .setLocked(false))
        case "/select", "/focus":
            return SortAssistantSlashCommand(name: name, argument: argument, operation: .selectWorkspace)
        default:
            return nil
        }
    }
}

struct SortAssistantSlashCommandDescriptor: Identifiable, Equatable {
    let name: String
    let aliases: [String]
    let argumentHint: String?
    let summary: String

    var id: String { name }

    var displayText: String {
        guard let argumentHint else { return name }
        return "\(name) \(argumentHint)"
    }

    var insertionText: String {
        argumentHint == nil ? name : "\(name) "
    }

    func matches(query: String) -> Bool {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedQuery.isEmpty else { return true }
        return ([name] + aliases).contains { commandName in
            commandName
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .lowercased()
                .hasPrefix(normalizedQuery)
                || commandName.lowercased().hasPrefix("/\(normalizedQuery)")
        }
    }
}

extension SortAssistantSlashCommand {
    static var descriptors: [SortAssistantSlashCommandDescriptor] {
        [
            SortAssistantSlashCommandDescriptor(
                name: "/help",
                aliases: ["/?"],
                argumentHint: nil,
                summary: String(localized: "sortAssistant.slash.help.summary", defaultValue: "Show available commands")
            ),
            SortAssistantSlashCommandDescriptor(
                name: "/clear",
                aliases: ["/new"],
                argumentHint: nil,
                summary: String(localized: "sortAssistant.slash.clear.summary", defaultValue: "Clear the current conversation")
            ),
            SortAssistantSlashCommandDescriptor(
                name: "/repo",
                aliases: ["/git"],
                argumentHint: "[@workspace]",
                summary: String(localized: "sortAssistant.slash.repo.summary", defaultValue: "Explain repository context")
            ),
            SortAssistantSlashCommandDescriptor(
                name: "/context",
                aliases: ["/ctx"],
                argumentHint: "[@workspace]",
                summary: String(localized: "sortAssistant.slash.context.summary", defaultValue: "Summarize workspace context")
            ),
            SortAssistantSlashCommandDescriptor(
                name: "/sort",
                aliases: [],
                argumentHint: "[goal]",
                summary: String(localized: "sortAssistant.slash.sort.summary", defaultValue: "Preview a workspace sort")
            ),
            SortAssistantSlashCommandDescriptor(
                name: "/apply",
                aliases: [],
                argumentHint: "[goal]",
                summary: String(localized: "sortAssistant.slash.apply.summary", defaultValue: "Apply a workspace sort")
            ),
            SortAssistantSlashCommandDescriptor(
                name: "/undo",
                aliases: [],
                argumentHint: nil,
                summary: String(localized: "sortAssistant.slash.undo.summary", defaultValue: "Undo the last assistant sort")
            ),
            SortAssistantSlashCommandDescriptor(
                name: "/explain",
                aliases: [],
                argumentHint: "[question]",
                summary: String(localized: "sortAssistant.slash.explain.summary", defaultValue: "Explain the current order")
            ),
            SortAssistantSlashCommandDescriptor(
                name: "/memory",
                aliases: ["/mem"],
                argumentHint: nil,
                summary: String(localized: "sortAssistant.slash.memory.summary", defaultValue: "List saved memories")
            ),
            SortAssistantSlashCommandDescriptor(
                name: "/remember",
                aliases: [],
                argumentHint: "<memory>",
                summary: String(localized: "sortAssistant.slash.remember.summary", defaultValue: "Save sprite workspace memory")
            ),
            SortAssistantSlashCommandDescriptor(
                name: "/forget",
                aliases: [],
                argumentHint: "<memory>",
                summary: String(localized: "sortAssistant.slash.forget.summary", defaultValue: "Forget sprite workspace memory")
            ),
            SortAssistantSlashCommandDescriptor(
                name: "/remember-sort",
                aliases: [],
                argumentHint: "<preference>",
                summary: String(localized: "sortAssistant.slash.rememberSort.summary", defaultValue: "Propose a free-sort memory")
            ),
            SortAssistantSlashCommandDescriptor(
                name: "/forget-sort",
                aliases: [],
                argumentHint: "<memory>",
                summary: String(localized: "sortAssistant.slash.forgetSort.summary", defaultValue: "Forget free-sort memory")
            ),
            SortAssistantSlashCommandDescriptor(
                name: "/pin",
                aliases: [],
                argumentHint: "[@workspace]",
                summary: String(localized: "sortAssistant.slash.pin.summary", defaultValue: "Pin a workspace")
            ),
            SortAssistantSlashCommandDescriptor(
                name: "/unpin",
                aliases: [],
                argumentHint: "[@workspace]",
                summary: String(localized: "sortAssistant.slash.unpin.summary", defaultValue: "Unpin a workspace")
            ),
            SortAssistantSlashCommandDescriptor(
                name: "/lock",
                aliases: [],
                argumentHint: "[@workspace]",
                summary: String(localized: "sortAssistant.slash.lock.summary", defaultValue: "Lock a workspace in sorting")
            ),
            SortAssistantSlashCommandDescriptor(
                name: "/unlock",
                aliases: [],
                argumentHint: "[@workspace]",
                summary: String(localized: "sortAssistant.slash.unlock.summary", defaultValue: "Unlock a workspace for sorting")
            ),
            SortAssistantSlashCommandDescriptor(
                name: "/select",
                aliases: ["/focus"],
                argumentHint: "@workspace",
                summary: String(localized: "sortAssistant.slash.select.summary", defaultValue: "Select a workspace")
            ),
        ]
    }

    static func completions(matching query: String) -> [SortAssistantSlashCommandDescriptor] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let options = descriptors.flatMap { descriptor -> [SortAssistantSlashCommandDescriptor] in
            var matches: [SortAssistantSlashCommandDescriptor] = []
            if descriptor.matches(query: normalizedQuery) {
                matches.append(descriptor)
            }
            for alias in descriptor.aliases {
                let aliasDescriptor = SortAssistantSlashCommandDescriptor(
                    name: alias,
                    aliases: [],
                    argumentHint: descriptor.argumentHint,
                    summary: descriptor.summary
                )
                if aliasDescriptor.matches(query: normalizedQuery) {
                    matches.append(aliasDescriptor)
                }
            }
            return matches
        }
        var seen: Set<String> = []
        return options
            .filter { seen.insert($0.name).inserted }
            .sorted { lhs, rhs in
                if lhs.name == "/help" { return true }
                if rhs.name == "/help" { return false }
                return lhs.name < rhs.name
            }
    }
}

struct SortAssistantWorkspaceTarget: Equatable, Sendable {
    let id: UUID
    let title: String
    let directory: String?
}

private struct SortAssistantWorkspaceMentionResolution: Equatable {
    let target: SortAssistantWorkspaceTarget
    let cleanedText: String
}

private struct SortAssistantCompletionItem: Identifiable, Equatable {
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

private struct SortAssistantCompletionModel: Equatable {
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

struct SortAssistantIntentRouter: Sendable {
    private static let semanticConfidenceFloor = 0.35
    private static let semanticTimeoutSeconds: TimeInterval = 8
    private static let clearSessionCommands = ["/clear", "/new"]
    private static let sortKeywords = [
        "sort", "sorting", "reorder", "rank", "prioritize", "priority", "arrange",
        "sidebar", "free sort", "order", "排序", "重排", "优先",
        "侧边栏", "顺序"
    ]
    private static let contextKeywords = [
        " repo ", " repository ", "current repo", "current repository", " git ", " branch ",
        " remote ", " remotes ", " worktree ", " worktrees ", " cwd ", "current directory",
        " directory ", " github ", " ghpr ", "pull request", " pr ", " prs ",
        " ci ", " review ", " jira ", " submodule ",
        "当前仓库", "仓库", "代码库", "当前目录", "目录", "分支", "远端",
        "拉取请求", "评审", "子模块"
    ]

    func immediateIntent(for text: String, externalGoal: Bool = false) -> SortAssistantIntent? {
        if Self.clearSessionCommands.contains(Self.slashCommandName(text)) {
            return .clearSession
        }
        if externalGoal {
            return .applySort
        }
        return nil
    }

    func semanticIntent(
        for text: String,
        externalGoal: Bool = false,
        conversationContext: [String] = []
    ) async -> SortAssistantIntentDecision {
        if let immediate = immediateIntent(for: text, externalGoal: externalGoal) {
            return SortAssistantIntentDecision(intent: immediate, confidence: 1, reason: "deterministic")
        }

        return await Task.detached(priority: .userInitiated) {
            do {
                let decision = try Self.classifyWithClaudeCode(
                    text: text,
                    externalGoal: externalGoal,
                    conversationContext: conversationContext
                )
                guard decision.intent != .clearSession else {
                    return Self.fallbackDecision(for: text)
                }
                guard decision.confidence >= Self.semanticConfidenceFloor else {
                    return Self.fallbackDecision(for: text)
                }
                return decision
            } catch {
                return Self.fallbackDecision(for: text)
            }
        }.value
    }

    private static func fallbackDecision(for text: String) -> SortAssistantIntentDecision {
        let lower = normalizedIntentText(text)
        let intent: SortAssistantIntent
        let isSortRelated = containsAny(lower, sortKeywords + [
            "workspace", "first", "top", "bottom", "urgent", "urgency",
            "工作区", "放到", "移动", "置顶", "紧急"
        ])
        if containsAny(lower, ["undo", "revert", "撤销", "恢复刚才", "还原"]) {
            intent = .undoSort
        } else if containsAny(lower, ["forget", "delete memory", "忘记", "别记", "删除记忆"]) {
            intent = isSortRelated ? .forgetPreference : .forgetSpriteMemory
        } else if containsAny(lower, ["remember", "from now on", "以后", "记住", "下次", "以后都"]) {
            intent = isSortRelated ? .rememberPreference : .rememberSpriteMemory
        } else if !isSortRelated && containsAny(lower, contextKeywords) {
            intent = .askContext
        } else if isSortRelated && containsAny(lower, ["why", "explain", "为什么", "解释"]) {
            intent = .explainCurrentOrder
        } else if containsAny(lower, ["feedback", "i moved", "我拖", "我移动", "刚才拖"]) {
            intent = .manualReorderFeedback
        } else if isSortRelated && containsAny(lower, ["apply", "sort it", "directly", "直接", "排好", "执行"]) {
            intent = .applySort
        } else if isSortRelated && containsAny(lower, ["suggest", "proposal", "preview", "recommend", "建议", "怎么排", "如何排", "先看看"]) {
            intent = .proposeSort
        } else if isSortRelated {
            intent = .proposeSort
        } else {
            intent = .normalChat
        }
        return SortAssistantIntentDecision(intent: intent, confidence: 0.2, reason: "fallback")
    }

    private static func classifyWithClaudeCode(
        text: String,
        externalGoal: Bool,
        conversationContext: [String]
    ) throws -> SortAssistantIntentDecision {
        let executable = claudeCodeExecutable()
        if executable.contains("/") && !FileManager.default.isExecutableFile(atPath: executable) {
            throw NSError(domain: "SortAssistantIntentRouter", code: 1)
        }

        let output = try runClaudeCode(
            executable: executable,
            arguments: [
                "-p", semanticUserPrompt(
                    text: text,
                    externalGoal: externalGoal,
                    conversationContext: conversationContext
                ),
                "--output-format", "json",
                "--append-system-prompt", semanticSystemPrompt,
                "--allowed-tools", "",
                "--model", "haiku"
            ],
            timeoutSeconds: semanticTimeoutSeconds
        )
        guard output.status == 0 else {
            throw NSError(domain: "SortAssistantIntentRouter", code: Int(output.status))
        }

        let content = claudeResultText(from: output.stdout) ?? output.stdout
        return try parseDecision(from: content)
    }

    private static var semanticSystemPrompt: String {
        """
        You are the semantic intent router for cmux's workspace sidebar sort assistant.
        Return only one strict JSON object with this schema:
        {"intent":"ask_context|clear_session|explain_current_order|propose_sort|apply_sort|manual_reorder_feedback|remember_preference|forget_preference|remember_sprite_memory|forget_sprite_memory|undo_sort|normal_chat","confidence":0.0,"reason":"short"}

        Intent meanings:
        - ask_context: the user asks what list/context/signals you can see, including GitHub, ghpr, PR, CI, review, Jira, Git, branch, submodule, current directory, or repository context.
        - clear_session: reserved for exact slash commands handled outside this semantic router; do not return it for natural-language input.
        - explain_current_order: the user asks why the sidebar is ordered this way.
        - propose_sort: the user asks for a recommendation, preview, suggestion, or how to sort without clearly asking to apply it.
        - apply_sort: the user asks to actually sort, reorder, move, arrange, rank, or prioritize workspaces/sidebar items.
        - manual_reorder_feedback: the user reports a manual drag/move or gives feedback about a reorder they already made.
        - remember_preference: the user asks you to save a future free-sort/sidebar sorting preference.
        - forget_preference: the user asks you to forget/delete a saved free-sort/sidebar sorting preference.
        - remember_sprite_memory: the user asks you to remember a project/session fact in the workspace memory.md, not a sorting preference.
        - forget_sprite_memory: the user asks you to forget/delete a project/session fact from workspace memory.md, not a sorting preference.
        - undo_sort: the user asks to undo/revert the assistant's previous sort.
        - normal_chat: greetings, identity questions, help/meta questions, or anything not about workspace sorting/memory/order.

        Important routing rules:
        - Do not classify slash commands. Slash commands are handled before semantic routing.
        - Never classify natural-language clear/reset/new-chat requests as clear_session. clear_session is reserved for exact slash commands handled outside this semantic router.
        - Do not classify "who are you", "who you are", "what are you", or "what can you do" as apply_sort.
        - Classify the latest input using recentConversation when it is a follow-up. Pronouns like "it", "that", and "this" may refer to the previous assistant answer.
        - Questions or follow-ups about GitHub/ghpr/PR/CI/review/Jira/Git/repository/current repo/current directory/submodule context are ask_context unless the user asks to sort or reorder with those signals.
        - If the input is not about sorting the workspace sidebar, classify normal_chat.
        - If it is about organizing workspaces but does not request mutation, prefer propose_sort.
        - If it explicitly asks to apply/do/execute the reorder, classify apply_sort.
        - Remember/forget requests about workspace sorting/sidebar order are remember_preference/forget_preference.
        - Remember/forget requests about project facts, current task context, user instructions, or general session memory are remember_sprite_memory/forget_sprite_memory.
        """
    }

    private static func semanticUserPrompt(
        text: String,
        externalGoal: Bool,
        conversationContext: [String]
    ) -> String {
        let payload: [String: Any] = [
            "input": text,
            "externalGoal": externalGoal,
            "recentConversation": conversationContext,
            "surface": "cmux_workspace_sidebar_sort_assistant"
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        let json = String(data: data, encoding: .utf8) ?? #"{"input":""}"#
        return "Classify this user input:\n\(json)"
    }

    private static func claudeCodeExecutable() -> String {
        if let custom = ClaudeCodeIntegrationSettings.customClaudePath(),
           !custom.isEmpty {
            return custom
        }
        if let custom = ProcessInfo.processInfo.environment["CMUX_CUSTOM_CLAUDE_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            return custom
        }
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.claude/local/claude",
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return "claude"
    }

    private struct ProcessOutput {
        let stdout: String
        let stderr: String
        let status: Int32
    }

    private static func runClaudeCode(
        executable: String,
        arguments: [String],
        timeoutSeconds: TimeInterval
    ) throws -> ProcessOutput {
        let process = Process()
        if executable.contains("/") {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
        }
        process.currentDirectoryURL = try SortAssistantClaudeWorkDirectory.url()

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let timeout = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + timeoutSeconds,
            execute: timeout
        )

        do {
            try process.run()
        } catch {
            timeout.cancel()
            throw error
        }
        process.waitUntilExit()
        timeout.cancel()

        return ProcessOutput(
            stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            status: process.terminationStatus
        )
    }

    private static func claudeResultText(from stdout: String) -> String? {
        guard let data = stdout.data(using: .utf8),
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let isError = envelope["is_error"] as? Bool, isError {
            return nil
        }
        return envelope["result"] as? String
    }

    private static func parseDecision(from content: String) throws -> SortAssistantIntentDecision {
        guard let json = firstJSONObject(in: content),
              let data = json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawIntent = object["intent"] as? String,
              let intent = SortAssistantIntent(rawValue: rawIntent.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw NSError(domain: "SortAssistantIntentRouter", code: 2)
        }
        let confidence = doubleValue(object["confidence"]) ?? 0
        let reason = object["reason"] as? String
        return SortAssistantIntentDecision(
            intent: intent,
            confidence: min(max(confidence, 0), 1),
            reason: reason
        )
    }

    private static func firstJSONObject(in content: String) -> String? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"), trimmed.hasSuffix("}") {
            return trimmed
        }
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"),
              start <= end else {
            return nil
        }
        return String(trimmed[start...end])
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String {
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private func containsAny(_ text: String, _ needles: [String]) -> Bool {
        Self.containsAny(text, needles)
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private static func normalizedIntentText(_ text: String) -> String {
        var lower = text.lowercased()
        for separator in [".", ",", "?", "!", ":", ";", "/", "\\", "-", "_", "(", ")", "[", "]", "{", "}", "\n", "\t"] {
            lower = lower.replacingOccurrences(of: separator, with: " ")
        }
        return " " + lower + " "
    }

    private static func slashCommandName(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return "" }
        return trimmed
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .first
            .map { String($0).lowercased() } ?? ""
    }
}

struct SortAssistantActionRouter {
    private static let contextReadTools = [
        "sprite_memory_query",
        "context_collect",
        "repository_context",
        "github_context",
        "github_pr_context",
        "ghpr_context",
        "ghpr_status",
        "workspace_digest_get",
        "workspace_digest_progress",
    ]

    private static func withContextReadTools(_ tools: [String]) -> [String] {
        tools + contextReadTools
    }

    func route(for intent: SortAssistantIntent) -> SortAssistantActionRoute {
        switch intent {
        case .askContext, .clearSession, .explainCurrentOrder, .normalChat:
            return SortAssistantActionRoute(
                mode: .readOnly,
                needsConfirmation: false,
                allowedTools: Self.withContextReadTools(["memory_query", "sort_context", "sort_explain", "list_state"]),
                memoryWritePolicy: .none
            )
        case .proposeSort:
            return SortAssistantActionRoute(
                mode: .previewOnly,
                needsConfirmation: true,
                allowedTools: Self.withContextReadTools(["memory_query", "sort_context", "sort_preview", "sort_explain", "list_state"]),
                memoryWritePolicy: .eventLog
            )
        case .applySort:
            return SortAssistantActionRoute(
                mode: .applyAllowed,
                needsConfirmation: false,
                allowedTools: Self.withContextReadTools(["memory_query", "sort_context", "sort_preview", "sort_apply", "sort_undo", "list_state"]),
                memoryWritePolicy: .eventLog
            )
        case .manualReorderFeedback:
            return SortAssistantActionRoute(
                mode: .readOnly,
                needsConfirmation: false,
                allowedTools: Self.withContextReadTools(["memory_write_candidate", "memory_query"]),
                memoryWritePolicy: .candidate
            )
        case .rememberPreference:
            return SortAssistantActionRoute(
                mode: .readOnly,
                needsConfirmation: true,
                allowedTools: Self.withContextReadTools(["memory_write_candidate", "memory_query"]),
                memoryWritePolicy: .candidate
            )
        case .forgetPreference:
            return SortAssistantActionRoute(
                mode: .readOnly,
                needsConfirmation: true,
                allowedTools: ["memory_forget", "memory_query"],
                memoryWritePolicy: .longTerm
            )
        case .rememberSpriteMemory:
            return SortAssistantActionRoute(
                mode: .readOnly,
                needsConfirmation: false,
                allowedTools: Self.withContextReadTools(["sprite_memory_write", "sprite_memory_query"]),
                memoryWritePolicy: .longTerm
            )
        case .forgetSpriteMemory:
            return SortAssistantActionRoute(
                mode: .readOnly,
                needsConfirmation: true,
                allowedTools: ["sprite_memory_forget", "sprite_memory_query"],
                memoryWritePolicy: .longTerm
            )
        case .undoSort:
            return SortAssistantActionRoute(
                mode: .applyAllowed,
                needsConfirmation: false,
                allowedTools: ["sort_undo", "list_state"],
                memoryWritePolicy: .eventLog
            )
        }
    }
}

struct SortAssistantMCPRunResult: Sendable {
    struct Card: Sendable {
        let title: String
        let dimensionLabel: String?
        let changes: [String]
        let rationale: String?
        let patchId: UUID?
        let mode: SortAssistantResultMode
        let actions: [SortAssistantResultAction]
    }

    let message: String
    let card: Card?
    let choicePrompt: SortAssistantChoicePrompt?

    init(
        message: String,
        card: Card?,
        choicePrompt: SortAssistantChoicePrompt? = nil
    ) {
        self.message = message
        self.card = card
        self.choicePrompt = choicePrompt
    }

    static func parse(_ raw: String) throws -> SortAssistantMCPRunResult {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SortAssistantMCPRunResultParseError(raw: raw)
        }
        guard let json = firstJSONObject(in: raw),
              let data = json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return SortAssistantMCPRunResult(message: trimmed, card: nil)
        }

        if let nested = Self.string(object["result"]),
           nested != trimmed,
           isAbsent(object["message"]),
           isAbsent(object["assistant_message"]),
           isAbsent(object["card"]),
           isAbsent(object["choicePrompt"]),
           isAbsent(object["choice_prompt"]),
           isAbsent(object["clarification"]) {
            return try parse(nested)
        }

        let message = Self.string(object["message"])
            ?? Self.string(object["assistant_message"])
            ?? Self.string(object["text"])
            ?? Self.contentText(object["content"])
            ?? ""
        let cardObject = object["card"] as? [String: Any]
            ?? object["result"] as? [String: Any]
        let card = cardObject.flatMap(Self.card)
        let promptObject = object["choicePrompt"] as? [String: Any]
            ?? object["choice_prompt"] as? [String: Any]
            ?? object["clarification"] as? [String: Any]
            ?? object["choice"] as? [String: Any]
        let choicePrompt = promptObject.flatMap(Self.choicePrompt)
        if message.isEmpty, card == nil, choicePrompt == nil {
            throw SortAssistantMCPRunResultParseError(raw: raw)
        }
        return SortAssistantMCPRunResult(message: message, card: card, choicePrompt: choicePrompt)
    }

    private static func card(_ object: [String: Any]) -> Card? {
        guard let title = string(object["title"]) else { return nil }
        let mode: SortAssistantResultMode = {
            switch string(object["mode"])?.lowercased() {
            case "applied", "apply": return .applied
            default: return .preview
            }
        }()
        let patchId = string(object["patchId"] ?? object["patch_id"]).flatMap(UUID.init(uuidString:))
        return Card(
            title: title,
            dimensionLabel: string(object["dimensionLabel"] ?? object["dimension_label"]),
            changes: stringArray(object["changes"]),
            rationale: string(object["rationale"] ?? object["markdown"]),
            patchId: patchId,
            mode: mode,
            actions: resultActions(object["actions"] ?? object["result_actions"] ?? object["cmux_result_actions"])
        )
    }

    private static func choicePrompt(_ object: [String: Any]) -> SortAssistantChoicePrompt? {
        let title = string(object["title"])
            ?? string(object["question"])
            ?? string(object["label"])
        let message = string(object["message"])
            ?? string(object["body"])
            ?? string(object["description"])
        let options = choiceOptions(object["options"] ?? object["choices"])
        guard let title, !options.isEmpty else { return nil }
        let followUpIntent = string(object["intent"] ?? object["followUpIntent"] ?? object["follow_up_intent"])
            .flatMap(SortAssistantIntent.init(rawValue:))
        let forceApply = bool(object["forceApply"] ?? object["force_apply"]) ?? false
        return SortAssistantChoicePrompt(
            title: title,
            message: message,
            options: options,
            followUpIntent: followUpIntent,
            forceApply: forceApply
        )
    }

    private static func choiceOptions(_ value: Any?) -> [SortAssistantChoicePrompt.Option] {
        let parsed: [SortAssistantChoicePrompt.Option]
        if let list = value as? [[String: Any]] {
            parsed = list.enumerated().compactMap { index, object in
                choiceOption(object, fallbackIndex: index)
            }
        } else if let list = value as? [Any] {
            parsed = list.enumerated().compactMap { index, value in
                if let object = value as? [String: Any] {
                    return choiceOption(object, fallbackIndex: index)
                }
                guard let title = string(value) else { return nil }
                return SortAssistantChoicePrompt.Option(
                    id: optionId(title, fallbackIndex: index),
                    title: title,
                    subtitle: nil,
                    goal: title
                )
            }
        } else {
            parsed = []
        }

        var seen: Set<String> = []
        return parsed.filter { option in
            seen.insert(option.id).inserted
        }
    }

    private static func choiceOption(
        _ object: [String: Any],
        fallbackIndex: Int
    ) -> SortAssistantChoicePrompt.Option? {
        guard let title = string(object["title"] ?? object["label"] ?? object["name"]) else {
            return nil
        }
        let subtitle = string(object["subtitle"] ?? object["description"] ?? object["detail"])
        let goal = string(object["goal"] ?? object["prompt"] ?? object["value"])
            ?? [title, subtitle].compactMap { $0 }.joined(separator: ": ")
        return SortAssistantChoicePrompt.Option(
            id: string(object["id"]) ?? optionId(title, fallbackIndex: fallbackIndex),
            title: title,
            subtitle: subtitle,
            goal: goal
        )
    }

    private static func optionId(_ title: String, fallbackIndex: Int) -> String {
        let normalized = title
            .lowercased()
            .unicodeScalars
            .map { scalar -> Character in
                CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
            }
            .reduce(into: "") { partial, character in
                if character == "-", partial.last == "-" {
                    return
                }
                partial.append(character)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return normalized.isEmpty ? "choice-\(fallbackIndex + 1)" : normalized
    }

    private static func firstJSONObject(in content: String) -> String? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"), trimmed.hasSuffix("}") {
            return trimmed
        }
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"),
              start <= end else {
            return nil
        }
        return String(trimmed[start...end])
    }

    private static func string(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        let raw: String?
        if let value = value as? String {
            raw = value
        } else if let value = value as? CustomStringConvertible {
            raw = value.description
        } else {
            raw = nil
        }
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isAbsent(_ value: Any?) -> Bool {
        value == nil || value is NSNull
    }

    private static func stringArray(_ value: Any?) -> [String] {
        if let list = value as? [String] {
            return list
        }
        if let list = value as? [Any] {
            return list.compactMap(string)
        }
        return []
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool {
            return value
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let string = string(value)?.lowercased() {
            switch string {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        }
        return nil
    }

    private static func contentText(_ value: Any?) -> String? {
        if let list = value as? [[String: Any]] {
            let text = list
                .compactMap { item in
                    string(item["text"] ?? item["content"] ?? item["message"])
                }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        if let list = value as? [Any] {
            let text = list
                .compactMap { item -> String? in
                    if let object = item as? [String: Any] {
                        return string(object["text"] ?? object["content"] ?? object["message"])
                    }
                    return string(item)
                }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        return string(value)
    }

    private static func resultActions(_ value: Any?) -> [SortAssistantResultAction] {
        let raw: [String]
        if let list = value as? [String] {
            raw = list
        } else if let list = value as? [Any] {
            raw = list.compactMap(string)
        } else if let string = string(value) {
            raw = string
                .trimmingCharacters(in: CharacterSet(charactersIn: " []"))
                .split { $0 == "," || $0 == " " || $0 == "\t" }
                .map { String($0) }
        } else {
            raw = []
        }
        var seen: Set<SortAssistantResultAction> = []
        return raw.compactMap { token in
            SortAssistantResultAction(rawValue: token.trimmingCharacters(in: .whitespacesAndNewlines))
        }.filter { action in
            seen.insert(action).inserted
        }
    }
}

struct SortAssistantMCPRunResultParseError: LocalizedError, Sendable {
    let raw: String

    var errorDescription: String? {
        let trimmed = raw
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let detail: String
        if trimmed.isEmpty {
            detail = String(localized: "sortAssistant.mcp.parse.empty", defaultValue: "empty Claude response")
        } else {
            detail = Self.shortened(trimmed)
        }
        return String(
            localized: "sortAssistant.mcp.parse.failed",
            defaultValue: "Could not parse sprite MCP response: \(detail)"
        )
    }

    private static func shortened(_ text: String) -> String {
        guard text.count > 420 else { return text }
        let end = text.index(text.startIndex, offsetBy: 420)
        return String(text[..<end]) + "..."
    }
}

struct SortAssistantMCPRequest: Sendable {
    let goal: String
    let intent: SortAssistantIntent
    let route: SortAssistantActionRoute
    let conversationContext: [String]
    let workspaceId: String?
    let workspaceDirectory: String?
    let socketPath: String
    let cmuxCLIPath: String
}

struct SortAssistantMCPClientProcessError: LocalizedError, Sendable {
    let status: Int32
    let stdout: String
    let stderr: String

    var errorDescription: String? {
        let detail = [stderr, stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
            ?? String(localized: "sortAssistant.mcp.claudeNoDetails", defaultValue: "Claude Code exited without details.")
        return String(
            localized: "sortAssistant.mcp.claudeExited",
            defaultValue: "Claude Code exited \(status): \(Self.shortened(detail))"
        )
    }

    private static func shortened(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\n", with: " ")
        guard normalized.count > 420 else { return normalized }
        let end = normalized.index(normalized.startIndex, offsetBy: 420)
        return String(normalized[..<end]) + "..."
    }
}

struct SortAssistantMCPClient: Sendable {
    func run(_ request: SortAssistantMCPRequest) async throws -> SortAssistantMCPRunResult {
        try await Task.detached(priority: .userInitiated) {
            try Self.perform(request)
        }.value
    }

    private static func perform(_ request: SortAssistantMCPRequest) throws -> SortAssistantMCPRunResult {
        let executable = claudeCodeExecutable()
        if executable.contains("/") && !FileManager.default.isExecutableFile(atPath: executable) {
            throw NSError(domain: "SortAssistantMCPClient", code: 1)
        }

        let configURL = try writeMCPConfig(request)
        defer { try? FileManager.default.removeItem(at: configURL) }

        let output = try runClaudeCode(
            executable: executable,
            arguments: claudeArguments(request: request, mcpConfigURL: configURL)
        )
        guard output.status == 0 else {
            throw SortAssistantMCPClientProcessError(
                status: output.status,
                stdout: output.stdout,
                stderr: output.stderr
            )
        }
        let content = claudeResultText(from: output.stdout) ?? output.stdout
        return try SortAssistantMCPRunResult.parse(content)
    }

    private static func claudeArguments(
        request: SortAssistantMCPRequest,
        mcpConfigURL: URL
    ) -> [String] {
        let allowedTools = request.route.allowedTools
            .map { "mcp__cmux_sprite__\($0)" }
            .joined(separator: ",")
        return [
            "-p", userPrompt(request),
            "--output-format", "json",
            "--append-system-prompt", systemPrompt,
            "--mcp-config", mcpConfigURL.path,
            "--strict-mcp-config",
            "--allowed-tools", allowedTools,
            "--model", "haiku",
        ]
    }

    private static var systemPrompt: String {
        """
        You are the super-agent brain for cmux's sprite workspace sort assistant.
        You must use the provided cmux_sprite MCP tools for workspace sorting, memory, list state, preview, apply, undo, explanations, and contextual data. Do not claim you changed sorting unless a tool result confirms it.

        Return only one strict JSON object:
        {
          "message": "short user-facing sentence",
          "choicePrompt": {
            "title": "short question title",
            "message": "optional context sentence",
            "options": [
              {
                "id": "stable_snake_case_id",
                "title": "short option title",
                "subtitle": "one-line option description",
                "goal": "complete follow-up sort goal to run when selected"
              }
            ]
          },
          "card": {
            "title": "short title",
            "mode": "preview|applied",
            "dimensionLabel": "optional label",
            "changes": ["short visible change"],
            "rationale": "markdown body; may include cmux_result_actions front matter",
            "patchId": "optional UUID",
            "actions": ["apply","partial_apply","ignore","explain","undo","remember"]
          }
        }
        Use null for choicePrompt when no choice should be shown.
        Use null for card when no result card should be shown.

        Behavior:
        - Keep two memory domains separate:
          - memory_query / memory_write_candidate / memory_forget are free-sort memories for sidebar sorting preferences only.
          - sprite_memory_query / sprite_memory_write / sprite_memory_forget are sprite workspace memories from memory.md for project/session facts.
        - Use memory_query before relying on prior sorting preferences.
        - Use sprite_memory_query before relying on general project/session memory.
        - Use context_collect for plugin-contributed context, repository_context for the current local Git repository, ghpr_context or github_pr_context for linked pull-request details, github_context for cached sidebar GitHub metadata, and workspace_digest_get for digest context.
        - If the user asks about the current repository, current directory, Git, branch, remotes, GitHub, ghpr, PRs, CI, reviews, Jira, or asks to sort by urgency/priority signals that may come from PRs, gather the relevant MCP context before answering or sorting.
        - For ask_context about repositories or GitHub, call repository_context and github_context first. Do not answer with a generic self-description.
        - Context tools may return null or empty data when integrations are disabled or no PR is linked; report that briefly instead of inventing context.
        - Never tell the user that sprite sort assistant tools are unavailable. The cmux_sprite MCP tools in this session are the available tools. If one tool returns empty/error data, use the other available tool outputs and explain the limitation concretely.
        - If a sort request is ambiguous and requires the user to pick an interpretation, return choicePrompt instead of a prose bullet-list question. For example, "urgent" can mean unfinished local work, linked PR review/CI activity, or current workspace urgency signals. Each option must include a complete follow-up goal; do not ask the user to type a free-form reply for those common choices.
        - For propose_sort, call memory_query, sort_context, then sort_preview. Return a preview card only if sort_preview succeeds.
        - For apply_sort, call memory_query, sort_context, sort_preview, then sort_apply. Return an applied card only if sort_apply succeeds.
        - For explain_current_order or ask_context, call sort_context and/or sort_explain/list_state and return a concise explanation.
        - For normal_chat, answer conversationally using recentConversation and current context when relevant. If the user asks a follow-up about a repository, directory, branch, submodule, GitHub, PR, CI, Jira, or prior context answer, gather context tools instead of returning a generic capability statement.
        - For remember_preference or manual_reorder_feedback, call memory_write_candidate and tell the user to review it before it is saved as a free-sort memory.
        - For forget_preference, call memory_forget only when the user supplied an id or concrete text to forget; otherwise explain what is saved from memory_query.
        - For remember_sprite_memory, call sprite_memory_write and report the saved memory.md path from the tool result. The sprite decides what to save; do not ask the user to confirm a candidate first.
        - For forget_sprite_memory, call sprite_memory_forget only when the user supplied an id or concrete text to forget; otherwise explain what is saved from sprite_memory_query.
        - For undo_sort, call sort_undo and report the tool result.
        - Never invent patch ids, workspace ids, changes, or memory ids.
        - Include result card actions only when the tool result supports the action.
        """
    }

    private static func userPrompt(_ request: SortAssistantMCPRequest) -> String {
        let payload: [String: Any] = [
            "goal": request.goal,
            "intent": request.intent.rawValue,
            "workspaceId": request.workspaceId.map { $0 as Any } ?? NSNull(),
            "workspaceDirectory": request.workspaceDirectory.map { $0 as Any } ?? NSNull(),
            "recentConversation": request.conversationContext,
            "route": [
                "mode": request.route.mode.rawValue,
                "needsConfirmation": request.route.needsConfirmation,
                "allowedTools": request.route.allowedTools,
                "memoryWritePolicy": request.route.memoryWritePolicy.rawValue,
            ],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        let json = String(data: data, encoding: .utf8) ?? "{}"
        return "Handle this sprite assistant request through MCP tools:\n\(json)"
    }

    private static func writeMCPConfig(_ request: SortAssistantMCPRequest) throws -> URL {
        var env: [String: String] = [
            "CMUX_SOCKET_PATH": request.socketPath,
        ]
        if let workspaceId = request.workspaceId, !workspaceId.isEmpty {
            env["CMUX_WORKSPACE_ID"] = workspaceId
        }
        if let workspaceDirectory = request.workspaceDirectory, !workspaceDirectory.isEmpty {
            env["CMUX_WORKSPACE_DIRECTORY"] = workspaceDirectory
        }

        let config: [String: Any] = [
            "mcpServers": [
                "cmux_sprite": [
                    "command": request.cmuxCLIPath,
                    "args": [
                        "--socket",
                        request.socketPath,
                        "mcp",
                        "sprite-assistant",
                    ],
                    "env": env,
                ],
            ],
        ]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sprite-mcp-\(UUID().uuidString).json")
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: [.atomic])
        return url
    }

    private static func claudeCodeExecutable() -> String {
        if let custom = ClaudeCodeIntegrationSettings.customClaudePath(),
           !custom.isEmpty {
            return custom
        }
        if let custom = ProcessInfo.processInfo.environment["CMUX_CUSTOM_CLAUDE_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            return custom
        }
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.claude/local/claude",
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return "claude"
    }

    private struct ProcessOutput {
        let stdout: String
        let stderr: String
        let status: Int32
    }

    private static func runClaudeCode(
        executable: String,
        arguments: [String]
    ) throws -> ProcessOutput {
        let process = Process()
        if executable.contains("/") {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
        }
        process.currentDirectoryURL = try SortAssistantClaudeWorkDirectory.url()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw error
        }
        process.waitUntilExit()
        return ProcessOutput(
            stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            status: process.terminationStatus
        )
    }

    private static func claudeResultText(from stdout: String) -> String? {
        guard let data = stdout.data(using: .utf8),
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let isError = envelope["is_error"] as? Bool, isError {
            return nil
        }
        return envelope["result"] as? String
    }
}

struct SortAssistantSortContext: Codable, Equatable {
    struct CurrentList: Codable, Equatable {
        let listId: String
        let revision: Int
        let visibleItemIds: [String]
        let selectedItemIds: [String]?
        let lockedItemIds: [String]?
        let pinnedItemIds: [String]?
    }

    struct RecentMove: Codable, Equatable {
        let itemId: String
        let fromIndex: Int
        let toIndex: Int
        let reason: String?
    }

    struct ShortTermMemory: Codable, Equatable {
        let recentMoves: [RecentMove]
        let activeConstraints: [String]
        let lastAssistantProposal: [String]?
    }

    struct LongTermMemory: Codable, Equatable {
        let userPreferences: [String]
        let projectRules: [String]
        let workspaceRules: [String]
    }

    struct ItemSignals: Codable, Equatable {
        let title: String
        let deadline: String?
        let priority: String?
        let status: String?
        let assignee: String?
        let customerImpact: Double?
        let blockedBy: [String]?
        let tags: [String]?
    }

    let userIntent: String
    let currentList: CurrentList
    let shortTermMemory: ShortTermMemory
    let longTermMemory: LongTermMemory
    let itemSignals: [String: ItemSignals]
}

enum SortGroupField: String, Codable, Equatable {
    case project
    case priority
    case status
    case assignee
    case tag
}

enum SortPinPosition: String, Codable, Equatable {
    case top
    case bottom
}

enum SortOperation: Equatable {
    case moveBefore(itemId: UUID, beforeItemId: UUID)
    case moveAfter(itemId: UUID, afterItemId: UUID)
    case batchReorder(itemIds: [UUID], preserveLockedItems: Bool)
    case pin(itemId: UUID, position: SortPinPosition)
    case lock(itemId: UUID)
    case groupBy(field: SortGroupField)

    var itemIds: [UUID] {
        switch self {
        case .moveBefore(let itemId, let beforeItemId):
            return [itemId, beforeItemId]
        case .moveAfter(let itemId, let afterItemId):
            return [itemId, afterItemId]
        case .batchReorder(let itemIds, _):
            return itemIds
        case .pin(let itemId, _), .lock(let itemId):
            return [itemId]
        case .groupBy:
            return []
        }
    }
}

extension SortOperation: Codable {
    private enum OperationType: String, Codable {
        case moveBefore = "move_before"
        case moveAfter = "move_after"
        case batchReorder = "batch_reorder"
        case pin
        case lock
        case groupBy = "group_by"
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case itemId
        case beforeItemId
        case afterItemId
        case itemIds
        case preserveLockedItems
        case position
        case field
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(OperationType.self, forKey: .type)
        switch type {
        case .moveBefore:
            self = .moveBefore(
                itemId: try container.decode(UUID.self, forKey: .itemId),
                beforeItemId: try container.decode(UUID.self, forKey: .beforeItemId)
            )
        case .moveAfter:
            self = .moveAfter(
                itemId: try container.decode(UUID.self, forKey: .itemId),
                afterItemId: try container.decode(UUID.self, forKey: .afterItemId)
            )
        case .batchReorder:
            self = .batchReorder(
                itemIds: try container.decode([UUID].self, forKey: .itemIds),
                preserveLockedItems: try container.decodeIfPresent(Bool.self, forKey: .preserveLockedItems) ?? true
            )
        case .pin:
            self = .pin(
                itemId: try container.decode(UUID.self, forKey: .itemId),
                position: try container.decodeIfPresent(SortPinPosition.self, forKey: .position) ?? .top
            )
        case .lock:
            self = .lock(itemId: try container.decode(UUID.self, forKey: .itemId))
        case .groupBy:
            self = .groupBy(field: try container.decode(SortGroupField.self, forKey: .field))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .moveBefore(let itemId, let beforeItemId):
            try container.encode(OperationType.moveBefore, forKey: .type)
            try container.encode(itemId, forKey: .itemId)
            try container.encode(beforeItemId, forKey: .beforeItemId)
        case .moveAfter(let itemId, let afterItemId):
            try container.encode(OperationType.moveAfter, forKey: .type)
            try container.encode(itemId, forKey: .itemId)
            try container.encode(afterItemId, forKey: .afterItemId)
        case .batchReorder(let itemIds, let preserveLockedItems):
            try container.encode(OperationType.batchReorder, forKey: .type)
            try container.encode(itemIds, forKey: .itemIds)
            try container.encode(preserveLockedItems, forKey: .preserveLockedItems)
        case .pin(let itemId, let position):
            try container.encode(OperationType.pin, forKey: .type)
            try container.encode(itemId, forKey: .itemId)
            try container.encode(position, forKey: .position)
        case .lock(let itemId):
            try container.encode(OperationType.lock, forKey: .type)
            try container.encode(itemId, forKey: .itemId)
        case .groupBy(let field):
            try container.encode(OperationType.groupBy, forKey: .type)
            try container.encode(field, forKey: .field)
        }
    }
}

struct SortPatch: Identifiable, Codable, Equatable {
    let id: UUID
    let listId: String
    let baseRevision: Int
    let operations: [SortOperation]
    let rationale: String?
    let confidence: Double?
    var requiresConfirmation: Bool

    init(
        id: UUID = UUID(),
        listId: String,
        baseRevision: Int,
        operations: [SortOperation],
        rationale: String? = nil,
        confidence: Double? = nil,
        requiresConfirmation: Bool
    ) {
        self.id = id
        self.listId = listId
        self.baseRevision = baseRevision
        self.operations = operations
        self.rationale = rationale
        self.confidence = confidence
        self.requiresConfirmation = requiresConfirmation
    }
}

struct SortEnginePreview: Equatable {
    let patch: SortPatch
    let orderBefore: [UUID]
    let orderAfter: [UUID]
    let changes: [String]
    let affectedItemIds: [UUID]
    let rationale: String?
    let requiresConfirmation: Bool
}

struct SortEngineApplyResult: Equatable {
    let preview: SortEnginePreview
    let undoPatch: SortPatch
    let revisionAfter: Int
}

enum SortEngineError: LocalizedError, Equatable {
    case wrongList(String)
    case emptyPatch
    case revisionConflict(expected: Int, actual: Int)
    case unknownItem(UUID)
    case lockedItemMoved(UUID)
    case pinnedConstraint(UUID)
    case applyFailed

    var errorDescription: String? {
        switch self {
        case .wrongList(let listId):
            return String(localized: "sortAssistant.error.wrongList", defaultValue: "Unsupported sort list: \(listId)")
        case .emptyPatch:
            return String(localized: "sortAssistant.error.emptyPatch", defaultValue: "The sort patch has no operations.")
        case .revisionConflict(let expected, let actual):
            return String(
                localized: "sortAssistant.error.revisionConflict",
                defaultValue: "The workspace order changed before the sort could apply. Expected revision \(expected), found \(actual)."
            )
        case .unknownItem(let itemId):
            return String(localized: "sortAssistant.error.unknownItem", defaultValue: "The sort patch references an unknown workspace: \(itemId.uuidString).")
        case .lockedItemMoved(let itemId):
            return String(localized: "sortAssistant.error.lockedItemMoved", defaultValue: "A locked workspace would move: \(itemId.uuidString).")
        case .pinnedConstraint(let itemId):
            return String(localized: "sortAssistant.error.pinnedConstraint", defaultValue: "A pinned workspace would leave the pinned section: \(itemId.uuidString).")
        case .applyFailed:
            return String(localized: "sortAssistant.error.applyFailed", defaultValue: "The workspace order could not be applied.")
        }
    }
}

final class SortAssistantLockStore {
    private let defaults: UserDefaults
    private let key = "sortAssistant.lockedWorkspaceIds"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func lockedItemIds() -> Set<UUID> {
        let values = defaults.stringArray(forKey: key) ?? []
        return Set(values.compactMap(UUID.init(uuidString:)))
    }

    func setLocked(_ locked: Bool, itemId: UUID) {
        var ids = lockedItemIds()
        if locked {
            ids.insert(itemId)
        } else {
            ids.remove(itemId)
        }
        defaults.set(ids.map(\.uuidString).sorted(), forKey: key)
    }
}

@MainActor
final class SortEngine {
    static let workspaceListId = "workspace-sidebar"

    private let lockStore: SortAssistantLockStore

    init(lockStore: SortAssistantLockStore = SortAssistantLockStore()) {
        self.lockStore = lockStore
    }

    static func revision(for tabs: [Workspace]) -> Int {
        var hash: UInt64 = 14_695_981_039_346_656_037
        func feed(_ string: String) {
            for byte in string.utf8 {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
        }
        for tab in tabs {
            feed(tab.id.uuidString)
            feed(tab.isPinned ? ":pinned" : ":unpinned")
        }
        return Int(hash & 0x7fff_ffff)
    }

    func lockedItemIds() -> Set<UUID> {
        lockStore.lockedItemIds()
    }

    func setLocked(_ locked: Bool, itemId: UUID) {
        lockStore.setLocked(locked, itemId: itemId)
    }

    func preview(
        patch: SortPatch,
        tabs: [Workspace],
        itemSignals: [UUID: SortAssistantSortContext.ItemSignals] = [:]
    ) throws -> SortEnginePreview {
        let plan = try resolvePlan(patch: patch, tabs: tabs, itemSignals: itemSignals)
        let titleById = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0.title) })
        return SortEnginePreview(
            patch: patch,
            orderBefore: tabs.map(\.id),
            orderAfter: plan.orderAfter,
            changes: Self.topChanges(
                before: tabs.map(\.id),
                after: plan.orderAfter,
                titleById: titleById
            ),
            affectedItemIds: affectedItemIds(before: tabs.map(\.id), after: plan.orderAfter, operations: patch.operations),
            rationale: patch.rationale,
            requiresConfirmation: patch.requiresConfirmation
        )
    }

    func apply(
        patch: SortPatch,
        tabManager: TabManager,
        itemSignals: [UUID: SortAssistantSortContext.ItemSignals] = [:]
    ) throws -> SortEngineApplyResult {
        let plan = try resolvePlan(patch: patch, tabs: tabManager.tabs, itemSignals: itemSignals)
        let before = tabManager.tabs.map(\.id)
        let titleById = Dictionary(uniqueKeysWithValues: tabManager.tabs.map { ($0.id, $0.title) })

        for change in plan.pinChanges {
            guard let workspace = tabManager.tabs.first(where: { $0.id == change.itemId }) else {
                throw SortEngineError.unknownItem(change.itemId)
            }
            tabManager.setPinned(workspace, pinned: true)
        }
        for change in plan.lockChanges {
            lockStore.setLocked(change.locked, itemId: change.itemId)
        }

        guard tabManager.reorderWorkspaces(to: plan.orderAfter) else {
            throw SortEngineError.applyFailed
        }

        let revisionAfter = Self.revision(for: tabManager.tabs)
        let undoPatch = SortPatch(
            listId: patch.listId,
            baseRevision: revisionAfter,
            operations: [.batchReorder(itemIds: before, preserveLockedItems: false)],
            rationale: String(localized: "sortAssistant.undo.patchRationale", defaultValue: "Restore the previous workspace order."),
            confidence: 1,
            requiresConfirmation: false
        )
        let preview = SortEnginePreview(
            patch: patch,
            orderBefore: before,
            orderAfter: tabManager.tabs.map(\.id),
            changes: Self.topChanges(
                before: before,
                after: tabManager.tabs.map(\.id),
                titleById: titleById
            ),
            affectedItemIds: affectedItemIds(before: before, after: tabManager.tabs.map(\.id), operations: patch.operations),
            rationale: patch.rationale,
            requiresConfirmation: patch.requiresConfirmation
        )
        return SortEngineApplyResult(
            preview: preview,
            undoPatch: undoPatch,
            revisionAfter: revisionAfter
        )
    }

    private struct ResolvedPlan {
        let orderAfter: [UUID]
        let pinChanges: [(itemId: UUID, position: SortPinPosition)]
        let lockChanges: [(itemId: UUID, locked: Bool)]
    }

    private func resolvePlan(
        patch: SortPatch,
        tabs: [Workspace],
        itemSignals: [UUID: SortAssistantSortContext.ItemSignals]
    ) throws -> ResolvedPlan {
        guard patch.listId == Self.workspaceListId else {
            throw SortEngineError.wrongList(patch.listId)
        }
        guard !patch.operations.isEmpty else {
            throw SortEngineError.emptyPatch
        }
        let actualRevision = Self.revision(for: tabs)
        guard patch.baseRevision == actualRevision else {
            throw SortEngineError.revisionConflict(expected: patch.baseRevision, actual: actualRevision)
        }

        let knownIds = Set(tabs.map(\.id))
        for operation in patch.operations {
            for itemId in operation.itemIds where !knownIds.contains(itemId) {
                throw SortEngineError.unknownItem(itemId)
            }
        }

        var order = tabs.map(\.id)
        var pinnedIds = Set(tabs.filter(\.isPinned).map(\.id))
        let initiallyLockedIds = lockStore.lockedItemIds()
        var lockedIds = initiallyLockedIds
        var pinChanges: [(itemId: UUID, position: SortPinPosition)] = []
        var lockChanges: [(itemId: UUID, locked: Bool)] = []

        for operation in patch.operations {
            switch operation {
            case .batchReorder(let itemIds, let preserveLockedItems):
                order = rankedOrder(
                    currentOrder: order,
                    prioritizedIds: itemIds,
                    pinnedIds: pinnedIds
                )
                if preserveLockedItems {
                    order = preserveLockedPositions(
                        before: tabs.map(\.id),
                        after: order,
                        lockedIds: initiallyLockedIds
                    )
                } else {
                    try validateLockedPositions(before: tabs.map(\.id), after: order, lockedIds: initiallyLockedIds)
                }
            case .moveBefore(let itemId, let beforeItemId):
                guard !lockedIds.contains(itemId) else { throw SortEngineError.lockedItemMoved(itemId) }
                order = move(itemId: itemId, before: beforeItemId, in: order)
                order = pinnedFirst(order, pinnedIds: pinnedIds)
            case .moveAfter(let itemId, let afterItemId):
                guard !lockedIds.contains(itemId) else { throw SortEngineError.lockedItemMoved(itemId) }
                order = move(itemId: itemId, after: afterItemId, in: order)
                order = pinnedFirst(order, pinnedIds: pinnedIds)
            case .pin(let itemId, let position):
                pinnedIds.insert(itemId)
                pinChanges.append((itemId, position))
                order.removeAll { $0 == itemId }
                switch position {
                case .top:
                    order.insert(itemId, at: 0)
                case .bottom:
                    let pinnedCount = order.filter { pinnedIds.contains($0) }.count
                    order.insert(itemId, at: min(pinnedCount, order.count))
                }
                order = pinnedFirst(order, pinnedIds: pinnedIds)
            case .lock(let itemId):
                lockedIds.insert(itemId)
                lockChanges.append((itemId, true))
            case .groupBy(let field):
                order = groupedOrder(
                    currentOrder: order,
                    pinnedIds: pinnedIds,
                    field: field,
                    tabs: tabs,
                    itemSignals: itemSignals
                )
            }
        }

        try validatePinnedSection(order: order, pinnedIds: pinnedIds)
        try validateLockedPositions(before: tabs.map(\.id), after: order, lockedIds: initiallyLockedIds)

        return ResolvedPlan(
            orderAfter: order,
            pinChanges: pinChanges,
            lockChanges: lockChanges
        )
    }

    private func rankedOrder(
        currentOrder: [UUID],
        prioritizedIds: [UUID],
        pinnedIds: Set<UUID>
    ) -> [UUID] {
        var rankById: [UUID: Int] = [:]
        for id in prioritizedIds where rankById[id] == nil {
            rankById[id] = rankById.count
        }
        let indexed = currentOrder.enumerated().map { (index: $0.offset, id: $0.element) }
        return indexed.sorted { lhs, rhs in
            if pinnedIds.contains(lhs.id) != pinnedIds.contains(rhs.id) {
                return pinnedIds.contains(lhs.id)
            }
            switch (rankById[lhs.id], rankById[rhs.id]) {
            case let (lhsRank?, rhsRank?):
                if lhsRank != rhsRank { return lhsRank < rhsRank }
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                break
            }
            return lhs.index < rhs.index
        }.map(\.id)
    }

    private func preserveLockedPositions(
        before: [UUID],
        after: [UUID],
        lockedIds: Set<UUID>
    ) -> [UUID] {
        guard !lockedIds.isEmpty else { return after }
        var output = after.filter { !lockedIds.contains($0) }
        for (index, id) in before.enumerated() where lockedIds.contains(id) {
            output.removeAll { $0 == id }
            output.insert(id, at: min(index, output.count))
        }
        return output
    }

    private func validateLockedPositions(
        before: [UUID],
        after: [UUID],
        lockedIds: Set<UUID>
    ) throws {
        guard !lockedIds.isEmpty else { return }
        let beforeIndex = Dictionary(uniqueKeysWithValues: before.enumerated().map { ($0.element, $0.offset) })
        let afterIndex = Dictionary(uniqueKeysWithValues: after.enumerated().map { ($0.element, $0.offset) })
        for itemId in lockedIds {
            guard beforeIndex[itemId] == afterIndex[itemId] else {
                throw SortEngineError.lockedItemMoved(itemId)
            }
        }
    }

    private func validatePinnedSection(order: [UUID], pinnedIds: Set<UUID>) throws {
        guard !pinnedIds.isEmpty else { return }
        var seenUnpinned = false
        for id in order {
            if pinnedIds.contains(id), seenUnpinned {
                throw SortEngineError.pinnedConstraint(id)
            }
            if !pinnedIds.contains(id) {
                seenUnpinned = true
            }
        }
    }

    private func pinnedFirst(_ order: [UUID], pinnedIds: Set<UUID>) -> [UUID] {
        order.filter { pinnedIds.contains($0) } + order.filter { !pinnedIds.contains($0) }
    }

    private func move(itemId: UUID, before targetId: UUID, in order: [UUID]) -> [UUID] {
        var output = order
        output.removeAll { $0 == itemId }
        let index = output.firstIndex(of: targetId) ?? output.endIndex
        output.insert(itemId, at: index)
        return output
    }

    private func move(itemId: UUID, after targetId: UUID, in order: [UUID]) -> [UUID] {
        var output = order
        output.removeAll { $0 == itemId }
        let index = output.firstIndex(of: targetId).map { output.index(after: $0) } ?? output.endIndex
        output.insert(itemId, at: index)
        return output
    }

    private func groupedOrder(
        currentOrder: [UUID],
        pinnedIds: Set<UUID>,
        field: SortGroupField,
        tabs: [Workspace],
        itemSignals: [UUID: SortAssistantSortContext.ItemSignals]
    ) -> [UUID] {
        let titleById = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0.title) })
        let indexById = Dictionary(uniqueKeysWithValues: currentOrder.enumerated().map { ($0.element, $0.offset) })
        return currentOrder.sorted { lhs, rhs in
            if pinnedIds.contains(lhs) != pinnedIds.contains(rhs) {
                return pinnedIds.contains(lhs)
            }
            let lhsValue = groupValue(for: lhs, field: field, titleById: titleById, itemSignals: itemSignals)
            let rhsValue = groupValue(for: rhs, field: field, titleById: titleById, itemSignals: itemSignals)
            if lhsValue != rhsValue {
                return lhsValue.localizedStandardCompare(rhsValue) == .orderedAscending
            }
            return (indexById[lhs] ?? 0) < (indexById[rhs] ?? 0)
        }
    }

    private func groupValue(
        for itemId: UUID,
        field: SortGroupField,
        titleById: [UUID: String],
        itemSignals: [UUID: SortAssistantSortContext.ItemSignals]
    ) -> String {
        let signal = itemSignals[itemId]
        switch field {
        case .project:
            return titleById[itemId]?.components(separatedBy: CharacterSet(charactersIn: ":-/")).first ?? ""
        case .priority:
            return signal?.priority ?? ""
        case .status:
            return signal?.status ?? ""
        case .assignee:
            return signal?.assignee ?? ""
        case .tag:
            return signal?.tags?.first ?? ""
        }
    }

    private func affectedItemIds(before: [UUID], after: [UUID], operations: [SortOperation]) -> [UUID] {
        let beforeIndex = Dictionary(uniqueKeysWithValues: before.enumerated().map { ($0.element, $0.offset) })
        var ids = operations.flatMap(\.itemIds)
        ids.append(contentsOf: after.filter { beforeIndex[$0] != after.firstIndex(of: $0) })
        var seen: Set<UUID> = []
        return ids.filter { seen.insert($0).inserted }
    }

    static func topChanges(
        before: [UUID],
        after: [UUID],
        titleById: [UUID: String]
    ) -> [String] {
        let beforeIndex = Dictionary(uniqueKeysWithValues: before.enumerated().map { ($0.element, $0.offset) })
        var changes: [String] = []
        for (index, id) in after.enumerated() {
            guard let previous = beforeIndex[id], previous != index else { continue }
            let title = titleById[id] ?? String(localized: "sortAssistant.workspace.fallback", defaultValue: "Workspace")
            changes.append("\(index + 1). \(title)")
            if changes.count >= 5 { break }
        }
        if changes.isEmpty {
            return [String(localized: "sortAssistant.result.noVisibleChanges", defaultValue: "Order was already up to date.")]
        }
        return changes
    }
}

struct SortAssistantSortEvent: Codable, Equatable {
    enum EventType: String, Codable {
        case userDragMove = "user_drag_move"
        case assistantPatchApplied = "assistant_patch_applied"
        case assistantPatchRejected = "assistant_patch_rejected"
        case undoApplied = "undo_applied"
    }

    let schemaVersion: String
    let eventType: EventType
    let eventId: UUID
    let patchId: UUID?
    let undoPatchId: UUID?
    let listId: String
    let itemId: UUID?
    let fromIndex: Int?
    let toIndex: Int?
    let revisionBefore: Int?
    let revisionAfter: Int?
    let reason: String?
    let rationale: String?
    let patch: SortPatch?
    let undoPatch: SortPatch?
    let createdAt: String
}

final class SortAssistantSortEventLog {
    static let workstreamId = "cmux-sort-assistant"
    static let toolName = "cmux.sort_event"
    static let schemaVersion = "cmux.sort_event.v1"

    private let fileURL: URL
    private let itemDecoder: JSONDecoder
    private let eventDecoder = JSONDecoder()
    private let eventEncoder = JSONEncoder()

    init(fileURL: URL = WorkstreamPersistence.defaultFileURL()) {
        self.fileURL = fileURL
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.itemDecoder = decoder
    }

    @MainActor
    func append(_ event: SortAssistantSortEvent) {
        guard let data = try? eventEncoder.encode(event),
              let resultJSON = String(data: data, encoding: .utf8) else {
            return
        }
        let item = WorkstreamItem(
            workstreamId: Self.workstreamId,
            source: .cmux,
            kind: .toolResult,
            title: Self.title(for: event.eventType),
            payload: .toolResult(
                toolName: Self.toolName,
                resultJSON: resultJSON,
                isError: false
            )
        )
        Task {
            try? await SortAssistantWorkstreamPersistence.shared.append(item)
        }
    }

    func loadEvents() -> [SortAssistantSortEvent] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        return lines.compactMap { line in
            let lineData = Data(line)
            guard let item = try? itemDecoder.decode(WorkstreamItem.self, from: lineData),
                  case .toolResult(let toolName, let resultJSON, false) = item.payload,
                  toolName == Self.toolName,
                  let eventData = resultJSON.data(using: .utf8),
                  let event = try? eventDecoder.decode(SortAssistantSortEvent.self, from: eventData),
                  event.schemaVersion == Self.schemaVersion else {
                return nil
            }
            return event
        }
    }

    private static func title(for eventType: SortAssistantSortEvent.EventType) -> String {
        switch eventType {
        case .userDragMove:
            return String(localized: "sortAssistant.event.userDragMove", defaultValue: "Workspace order changed")
        case .assistantPatchApplied:
            return String(localized: "sortAssistant.event.patchApplied", defaultValue: "Assistant sort applied")
        case .assistantPatchRejected:
            return String(localized: "sortAssistant.event.patchRejected", defaultValue: "Assistant sort rejected")
        case .undoApplied:
            return String(localized: "sortAssistant.event.undoApplied", defaultValue: "Assistant sort undone")
        }
    }
}

@MainActor
final class SortContextProvider {
    private let eventLog: SortAssistantSortEventLog
    private let engine: SortEngine

    init(eventLog: SortAssistantSortEventLog, engine: SortEngine) {
        self.eventLog = eventLog
        self.engine = engine
    }

    func context(
        userIntent: String,
        tabManager: TabManager,
        workspaceTabStore: WorkspaceTabStore,
        memories: [SortAssistantMemory],
        lastAssistantProposal: [UUID]?
    ) -> SortAssistantSortContext {
        let tabs = tabManager.tabs
        let itemSignals = Self.itemSignals(
            tabs: tabs,
            summaryPriority: workspaceTabStore.summaryPriority
        )
        let ruleBuckets = Self.ruleBuckets(memories: memories)
        return SortAssistantSortContext(
            userIntent: userIntent,
            currentList: SortAssistantSortContext.CurrentList(
                listId: SortEngine.workspaceListId,
                revision: SortEngine.revision(for: tabs),
                visibleItemIds: tabs.map { $0.id.uuidString },
                selectedItemIds: tabManager.selectedTabId.map { [$0.uuidString] },
                lockedItemIds: engine.lockedItemIds().map(\.uuidString).sorted(),
                pinnedItemIds: tabs.filter(\.isPinned).map { $0.id.uuidString }
            ),
            shortTermMemory: SortAssistantSortContext.ShortTermMemory(
                recentMoves: recentMoves(limit: 8),
                activeConstraints: activeConstraints(tabs: tabs),
                lastAssistantProposal: lastAssistantProposal?.map(\.uuidString)
            ),
            longTermMemory: SortAssistantSortContext.LongTermMemory(
                userPreferences: ruleBuckets.userPreferences,
                projectRules: ruleBuckets.projectRules,
                workspaceRules: ruleBuckets.workspaceRules
            ),
            itemSignals: itemSignals.reduce(into: [:]) { partial, pair in
                partial[pair.key.uuidString] = pair.value
            }
        )
    }

    func itemSignals(
        tabManager: TabManager,
        workspaceTabStore: WorkspaceTabStore
    ) -> [UUID: SortAssistantSortContext.ItemSignals] {
        Self.itemSignals(tabs: tabManager.tabs, summaryPriority: workspaceTabStore.summaryPriority)
    }

    private func recentMoves(limit: Int) -> [SortAssistantSortContext.RecentMove] {
        eventLog.loadEvents().reversed().compactMap { event in
            guard event.eventType == .userDragMove,
                  let itemId = event.itemId,
                  let fromIndex = event.fromIndex,
                  let toIndex = event.toIndex else {
                return nil
            }
            return SortAssistantSortContext.RecentMove(
                itemId: itemId.uuidString,
                fromIndex: fromIndex,
                toIndex: toIndex,
                reason: event.reason
            )
        }.prefix(limit).map { $0 }
    }

    private func activeConstraints(tabs: [Workspace]) -> [String] {
        var constraints = [
            "do_not_move_locked_items",
            "keep_pinned_items_at_top",
            "preserve_relative_order_when_score_ties",
        ]
        if !tabs.filter(\.isPinned).isEmpty {
            constraints.append("pinned_workspaces_are_hard_constraints")
        }
        if !engine.lockedItemIds().isEmpty {
            constraints.append("locked_workspaces_keep_absolute_positions")
        }
        return constraints
    }

    private static func itemSignals(
        tabs: [Workspace],
        summaryPriority: WorkspaceSidebarSummaryPriorityState?
    ) -> [UUID: SortAssistantSortContext.ItemSignals] {
        let summaryById: [UUID: WorkspaceSidebarSummaryPriorityItem] = (summaryPriority?.items ?? [])
            .reduce(into: [:]) { partial, item in
                guard let id = UUID(uuidString: item.workspaceId), partial[id] == nil else { return }
                partial[id] = item
            }
        return Dictionary(uniqueKeysWithValues: tabs.map { tab in
            let item = summaryById[tab.id]
            let priority = item?.scores.dimensions
                .sorted { lhs, rhs in lhs.value.rawScore > rhs.value.rawScore }
                .first
                .map { "\($0.key):\(Int($0.value.rawScore))" }
            return (
                tab.id,
                SortAssistantSortContext.ItemSignals(
                    title: item?.title ?? tab.title,
                    deadline: nil,
                    priority: priority,
                    status: item?.presentStatus ?? item?.status,
                    assignee: nil,
                    customerImpact: item?.scores.dimensions["importance"]?.rawScore,
                    blockedBy: item?.status.lowercased().contains("blocked") == true ? [item?.status ?? "blocked"] : nil,
                    tags: item?.topic.text.isEmpty == false ? [item?.topic.text ?? ""] : nil
                )
            )
        })
    }

    private static func ruleBuckets(memories: [SortAssistantMemory]) -> (
        userPreferences: [String],
        projectRules: [String],
        workspaceRules: [String]
    ) {
        var userPreferences: [String] = []
        var projectRules: [String] = []
        var workspaceRules: [String] = []
        for memory in memories {
            let lower = memory.text.lowercased()
            if lower.contains("project") || lower.contains("项目") {
                projectRules.append(memory.text)
            } else if lower.contains("workspace") || lower.contains("工作区") {
                workspaceRules.append(memory.text)
            } else {
                userPreferences.append(memory.text)
            }
        }
        return (userPreferences, projectRules, workspaceRules)
    }
}

@MainActor
final class SortOperator {
    private let engine: SortEngine
    private let eventLog: SortAssistantSortEventLog
    private let iso8601Formatter = ISO8601DateFormatter()

    init(engine: SortEngine, eventLog: SortAssistantSortEventLog) {
        self.engine = engine
        self.eventLog = eventLog
    }

    func makeBatchPatch(
        orderedIds: [UUID],
        tabs: [Workspace],
        rationale: String?,
        confidence: Double? = nil,
        requiresConfirmation: Bool
    ) -> SortPatch {
        SortPatch(
            listId: SortEngine.workspaceListId,
            baseRevision: SortEngine.revision(for: tabs),
            operations: [.batchReorder(itemIds: orderedIds, preserveLockedItems: true)],
            rationale: rationale,
            confidence: confidence,
            requiresConfirmation: requiresConfirmation
        )
    }

    func preview(
        patch: SortPatch,
        tabs: [Workspace],
        itemSignals: [UUID: SortAssistantSortContext.ItemSignals] = [:]
    ) throws -> SortEnginePreview {
        try engine.preview(patch: patch, tabs: tabs, itemSignals: itemSignals)
    }

    func apply(
        patch: SortPatch,
        tabManager: TabManager,
        itemSignals: [UUID: SortAssistantSortContext.ItemSignals] = [:],
        actor: String
    ) throws -> SortEngineApplyResult {
        let revisionBefore = SortEngine.revision(for: tabManager.tabs)
        let result = try engine.apply(patch: patch, tabManager: tabManager, itemSignals: itemSignals)
        eventLog.append(
            SortAssistantSortEvent(
                schemaVersion: SortAssistantSortEventLog.schemaVersion,
                eventType: .assistantPatchApplied,
                eventId: UUID(),
                patchId: patch.id,
                undoPatchId: result.undoPatch.id,
                listId: patch.listId,
                itemId: nil,
                fromIndex: nil,
                toIndex: nil,
                revisionBefore: revisionBefore,
                revisionAfter: result.revisionAfter,
                reason: actor,
                rationale: patch.rationale,
                patch: patch,
                undoPatch: result.undoPatch,
                createdAt: iso8601Formatter.string(from: Date())
            )
        )
        return result
    }

    func reject(patch: SortPatch, reason: String?) {
        eventLog.append(
            SortAssistantSortEvent(
                schemaVersion: SortAssistantSortEventLog.schemaVersion,
                eventType: .assistantPatchRejected,
                eventId: UUID(),
                patchId: patch.id,
                undoPatchId: nil,
                listId: patch.listId,
                itemId: nil,
                fromIndex: nil,
                toIndex: nil,
                revisionBefore: nil,
                revisionAfter: nil,
                reason: reason,
                rationale: patch.rationale,
                patch: patch,
                undoPatch: nil,
                createdAt: iso8601Formatter.string(from: Date())
            )
        )
    }

    func undo(tabManager: TabManager) throws -> SortEngineApplyResult? {
        guard let event = lastUndoableEvent() else { return nil }
        guard let undoPatch = event.undoPatch else { return nil }
        let result = try engine.apply(patch: undoPatch, tabManager: tabManager)
        eventLog.append(
            SortAssistantSortEvent(
                schemaVersion: SortAssistantSortEventLog.schemaVersion,
                eventType: .undoApplied,
                eventId: UUID(),
                patchId: event.patchId,
                undoPatchId: undoPatch.id,
                listId: undoPatch.listId,
                itemId: nil,
                fromIndex: nil,
                toIndex: nil,
                revisionBefore: undoPatch.baseRevision,
                revisionAfter: result.revisionAfter,
                reason: "assistant_undo",
                rationale: undoPatch.rationale,
                patch: undoPatch,
                undoPatch: result.undoPatch,
                createdAt: iso8601Formatter.string(from: Date())
            )
        )
        return result
    }

    func recordUserDragMove(
        itemId: UUID,
        fromIndex: Int,
        toIndex: Int,
        revision: Int,
        reason: String?
    ) {
        eventLog.append(
            SortAssistantSortEvent(
                schemaVersion: SortAssistantSortEventLog.schemaVersion,
                eventType: .userDragMove,
                eventId: UUID(),
                patchId: nil,
                undoPatchId: nil,
                listId: SortEngine.workspaceListId,
                itemId: itemId,
                fromIndex: fromIndex,
                toIndex: toIndex,
                revisionBefore: nil,
                revisionAfter: revision,
                reason: reason,
                rationale: nil,
                patch: nil,
                undoPatch: nil,
                createdAt: iso8601Formatter.string(from: Date())
            )
        )
    }

    func lastUndoableEvent() -> SortAssistantSortEvent? {
        let events = eventLog.loadEvents()
        let undonePatchIds = Set(events.compactMap { event -> UUID? in
            event.eventType == .undoApplied ? event.patchId : nil
        })
        return events.reversed().first { event in
            event.eventType == .assistantPatchApplied &&
                event.patchId.map { !undonePatchIds.contains($0) } == true &&
                event.undoPatch != nil
        }
    }

    func events() -> [SortAssistantSortEvent] {
        eventLog.loadEvents()
    }
}

enum SortAssistantPayload {
    private static let encoder = JSONEncoder()

    static func dictionary<T: Encodable>(_ value: T) -> [String: Any] {
        guard let data = try? encoder.encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }

    static func array<T: Encodable>(_ value: T) -> [[String: Any]] {
        guard let data = try? encoder.encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return object
    }
}

@MainActor
final class SortAssistantCoordinator: ObservableObject {
    static let shared = SortAssistantCoordinator()

    @Published private(set) var messages: [SortAssistantMessage] = []
    @Published private(set) var latestResult: SortAssistantSortResult? {
        didSet {
            if latestResult == nil {
                latestResultAnchorMessageId = nil
            }
        }
    }
    @Published private(set) var latestResultAnchorMessageId: UUID?
    @Published private(set) var choicePrompt: SortAssistantChoicePrompt?
    @Published private(set) var dimensionQuestion: SortAssistantDimensionQuestion?
    @Published private(set) var memoryCandidate: SortAssistantMemoryCandidate?
    @Published private(set) var memories: [SortAssistantMemory] = []
    @Published private(set) var spriteMemories: [SortAssistantMemory] = []
    @Published private(set) var isSorting = false
    @Published private(set) var presentationSequence = 0
    @Published private(set) var presentationToggleSequence = 0
    @Published private(set) var externalGoalSequence = 0
    @Published private(set) var entryFocusSequence = 0

    private static let workstreamId = "cmux-sort-assistant"
    private static let memoryToolName = "cmux.sort_memory"
    private static let memorySchemaVersion = "cmux.sort_memory.v1"
    private static let iso8601Formatter = ISO8601DateFormatter()
    private let memoryFileURL = WorkstreamPersistence.defaultFileURL()
    private let intentRouter = SortAssistantIntentRouter()
    private let actionRouter = SortAssistantActionRouter()
    private let sortEventLog: SortAssistantSortEventLog
    private let sortEngine: SortEngine
    private let sortOperator: SortOperator
    private let contextProvider: SortContextProvider
    private let mcpClient = SortAssistantMCPClient()
    private var pendingExternalGoal: (goal: String, forceApply: Bool)?
    private var pendingPreviewPatch: SortPatch?
    private var pendingPreviewSort: WorkspaceSidebarSummaryPrioritySort?
    private var pendingIntentRequestId: UUID?
    private weak var lastTabManager: TabManager?
    private weak var lastWorkspaceTabStore: WorkspaceTabStore?
    private var currentSpriteMemoryDirectory: String?
    private var currentSpriteMemoryFileURL: URL?
    private var spriteMemorySources: [UUID: SpriteMemorySource] = [:]
    private var sessionGeneration = UUID()

    private init() {
        let eventLog = SortAssistantSortEventLog(fileURL: memoryFileURL)
        let engine = SortEngine()
        self.sortEventLog = eventLog
        self.sortEngine = engine
        self.sortOperator = SortOperator(engine: engine, eventLog: eventLog)
        self.contextProvider = SortContextProvider(eventLog: eventLog, engine: engine)
        memories = Self.loadLegacyMemories(from: memoryFileURL)
    }

    var hasCurrentSessionState: Bool {
        !messages.isEmpty
            || latestResult != nil
            || choicePrompt != nil
            || dimensionQuestion != nil
            || memoryCandidate != nil
            || isSorting
    }

    var mascotState: SortAssistantMascotState {
        if isSorting {
            return .running
        }
        if messages.last?.kind == .error {
            return .failed
        }
        if memoryCandidate != nil || dimensionQuestion != nil || choicePrompt != nil {
            return .waiting
        }
        if let latestResult {
            switch latestResult.mode {
            case .applied:
                return .jumping
            case .preview:
                return .review
            }
        }
        if messages.last?.kind == .progress {
            return .review
        }
        return .idle
    }

    func attach(
        tabManager: TabManager,
        workspaceTabStore: WorkspaceTabStore
    ) {
        rememberStores(tabManager: tabManager, workspaceTabStore: workspaceTabStore)
    }

    func clearCurrentSession(appendConfirmation: Bool = false) {
        sessionGeneration = UUID()
        pendingIntentRequestId = nil
        pendingPreviewPatch = nil
        pendingPreviewSort = nil
        latestResult = nil
        latestResultAnchorMessageId = nil
        choicePrompt = nil
        dimensionQuestion = nil
        memoryCandidate = nil
        messages.removeAll()
        isSorting = false
        if appendConfirmation {
            append(.init(
                kind: .assistant,
                text: String(localized: "sortAssistant.session.cleared", defaultValue: "Cleared the current session.")
            ))
        }
    }

    func activateEntry() {
        if messages.isEmpty {
            append(.init(
                kind: .assistant,
                text: String(localized: "sortAssistant.entry.ready", defaultValue: "Tell me how to sort the workspace sidebar.")
            ))
        }
        togglePresentation()
        entryFocusSequence += 1
    }

    func submitExternalGoal(_ goal: String) {
        let trimmed = normalized(goal)
        guard !trimmed.isEmpty else { return }
        pendingExternalGoal = (trimmed, true)
        requestPresentation()
        externalGoalSequence += 1
    }

    func requestPresentation() {
        presentationSequence += 1
    }

    func togglePresentation() {
        presentationToggleSequence += 1
    }

    func drainExternalGoal(
        tabManager: TabManager,
        workspaceTabStore: WorkspaceTabStore
    ) {
        guard let pending = pendingExternalGoal else { return }
        pendingExternalGoal = nil
        submit(
            pending.goal,
            tabManager: tabManager,
            workspaceTabStore: workspaceTabStore,
            externalGoal: true,
            forceApply: pending.forceApply
        )
    }

    func submit(
        _ text: String,
        tabManager: TabManager,
        workspaceTabStore: WorkspaceTabStore
    ) {
        submit(
            text,
            tabManager: tabManager,
            workspaceTabStore: workspaceTabStore,
            externalGoal: false,
            forceApply: false
        )
    }

    private func submit(
        _ text: String,
        tabManager: TabManager,
        workspaceTabStore: WorkspaceTabStore,
        externalGoal: Bool,
        forceApply: Bool
    ) {
        let trimmed = normalized(text)
        guard !trimmed.isEmpty else { return }
        choicePrompt = nil
        rememberStores(tabManager: tabManager, workspaceTabStore: workspaceTabStore)
        let workspaceMention = Self.workspaceMentionResolution(in: trimmed, tabManager: tabManager)
        let workspaceTarget = workspaceMention?.target
        let routedText = effectiveRoutingText(
            from: workspaceMention?.cleanedText ?? trimmed,
            workspaceTarget: workspaceTarget
        )
        if let command = SortAssistantSlashCommand.parse(routedText) {
            handleSlashCommand(
                command,
                originalText: trimmed,
                tabManager: tabManager,
                workspaceTabStore: workspaceTabStore,
                workspaceTarget: workspaceTarget
            )
            return
        }
        if routedText.hasPrefix("/") {
            append(.init(kind: .user, text: trimmed))
            append(.init(
                kind: .error,
                text: String(localized: "sortAssistant.slash.unknown", defaultValue: "Unknown command. Try /help.")
            ))
            return
        }
        if intentRouter.immediateIntent(for: routedText, externalGoal: externalGoal) == .clearSession {
            clearCurrentSession()
            entryFocusSequence += 1
            return
        }
        append(.init(kind: .user, text: trimmed))

        if let intent = intentRouter.immediateIntent(for: routedText, externalGoal: externalGoal) {
            handleSubmitIntent(
                intent,
                trimmed: routedText,
                tabManager: tabManager,
                workspaceTabStore: workspaceTabStore,
                forceApply: forceApply,
                workspaceTarget: workspaceTarget
            )
            return
        }

        let requestId = UUID()
        pendingIntentRequestId = requestId
        let conversationContext = semanticConversationContext(workspaceTarget: workspaceTarget)
        append(.init(
            kind: .progress,
            text: String(localized: "sortAssistant.intent.running", defaultValue: "Understanding the request...")
        ))

        Task { [weak self, weak tabManager, weak workspaceTabStore] in
            let decision = await SortAssistantIntentRouter().semanticIntent(
                for: routedText,
                externalGoal: externalGoal,
                conversationContext: conversationContext
            )
            guard let self else { return }
            guard self.pendingIntentRequestId == requestId else { return }
            self.pendingIntentRequestId = nil
            guard let tabManager, let workspaceTabStore else { return }
            self.handleSubmitIntent(
                decision.intent,
                trimmed: routedText,
                tabManager: tabManager,
                workspaceTabStore: workspaceTabStore,
                forceApply: forceApply,
                workspaceTarget: workspaceTarget
            )
        }
    }

    private func effectiveRoutingText(
        from text: String,
        workspaceTarget: SortAssistantWorkspaceTarget?
    ) -> String {
        let trimmed = normalized(text)
        if !trimmed.isEmpty {
            return trimmed
        }
        if workspaceTarget != nil {
            return String(
                localized: "sortAssistant.workspaceMention.defaultGoal",
                defaultValue: "Summarize the referenced workspace context."
            )
        }
        return trimmed
    }

    private struct WorkspaceMentionCandidate {
        let range: Range<String.Index>
        let query: String
    }

    private static func workspaceMentionResolution(
        in text: String,
        tabManager: TabManager
    ) -> SortAssistantWorkspaceMentionResolution? {
        for candidate in workspaceMentionCandidates(in: text) {
            guard let target = workspaceTarget(matching: candidate.query, tabManager: tabManager) else {
                continue
            }
            return SortAssistantWorkspaceMentionResolution(
                target: target,
                cleanedText: textRemovingWorkspaceMention(candidate.range, from: text)
            )
        }
        return nil
    }

    private static func workspaceMentionCandidates(in text: String) -> [WorkspaceMentionCandidate] {
        var candidates: [WorkspaceMentionCandidate] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "@" else {
                index = text.index(after: index)
                continue
            }

            let afterAt = text.index(after: index)
            guard afterAt < text.endIndex else { break }
            if text[afterAt] == "{" {
                let contentStart = text.index(after: afterAt)
                if let close = text[contentStart...].firstIndex(of: "}") {
                    let query = String(text[contentStart..<close])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !query.isEmpty {
                        candidates.append(WorkspaceMentionCandidate(
                            range: index..<text.index(after: close),
                            query: query
                        ))
                    }
                    index = text.index(after: close)
                    continue
                }
            }

            var end = afterAt
            while end < text.endIndex, !text[end].isWhitespace {
                end = text.index(after: end)
            }
            let query = String(text[afterAt..<end])
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            if !query.isEmpty {
                candidates.append(WorkspaceMentionCandidate(range: index..<end, query: query))
            }
            index = end
        }
        return candidates
    }

    private static func workspaceTarget(
        matching query: String,
        tabManager: TabManager
    ) -> SortAssistantWorkspaceTarget? {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedQuery.isEmpty else { return nil }
        let ranked = tabManager.tabs.enumerated().compactMap { index, workspace -> (Int, Workspace)? in
            guard let rank = workspaceMentionMatchRank(
                workspace: workspace,
                index: index,
                selectedWorkspaceId: tabManager.selectedTabId,
                query: normalizedQuery
            ) else {
                return nil
            }
            return (rank, workspace)
        }
        guard let workspace = ranked.sorted(by: { lhs, rhs in
            if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
            return lhs.1.displayTitle.localizedCaseInsensitiveCompare(rhs.1.displayTitle) == .orderedAscending
        }).first?.1 else {
            return nil
        }
        return SortAssistantWorkspaceTarget(
            id: workspace.id,
            title: workspace.displayTitle,
            directory: workspaceDirectoryForMCP(workspace: workspace)
        )
    }

    private static func selectedWorkspaceTarget(tabManager: TabManager) -> SortAssistantWorkspaceTarget? {
        guard let workspace = tabManager.selectedWorkspace else { return nil }
        return SortAssistantWorkspaceTarget(
            id: workspace.id,
            title: workspace.displayTitle,
            directory: workspaceDirectoryForMCP(workspace: workspace)
        )
    }

    private static func workspaceMentionMatchRank(
        workspace: Workspace,
        index: Int,
        selectedWorkspaceId: UUID?,
        query: String
    ) -> Int? {
        let title = workspace.displayTitle.lowercased()
        let rawTitle = workspace.title.lowercased()
        let directoryName = workspaceDirectoryName(workspace)?.lowercased()
        let branch = workspace.gitBranch?.branch.lowercased()
        let id = workspace.id.uuidString.lowercased()

        if id.hasPrefix(query) { return 0 }
        if title == query || rawTitle == query { return workspace.id == selectedWorkspaceId ? 1 : 2 }
        if directoryName == query { return 3 }
        if branch == query { return 4 }
        if title.hasPrefix(query) || rawTitle.hasPrefix(query) { return 10 + index }
        if directoryName?.hasPrefix(query) == true { return 20 + index }
        if branch?.hasPrefix(query) == true { return 30 + index }
        if title.contains(query) || rawTitle.contains(query) { return 40 + index }
        if directoryName?.contains(query) == true { return 50 + index }
        if branch?.contains(query) == true { return 60 + index }
        return nil
    }

    private static func workspaceDirectoryName(_ workspace: Workspace) -> String? {
        guard let directory = workspaceDirectoryForMCP(workspace: workspace) else { return nil }
        let name = URL(fileURLWithPath: directory).lastPathComponent
        return name.isEmpty ? directory : name
    }

    private static func textRemovingWorkspaceMention(
        _ range: Range<String.Index>,
        from text: String
    ) -> String {
        var output = text
        output.replaceSubrange(range, with: " ")
        return output
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private func handleSlashCommand(
        _ command: SortAssistantSlashCommand,
        originalText: String,
        tabManager: TabManager,
        workspaceTabStore: WorkspaceTabStore,
        workspaceTarget: SortAssistantWorkspaceTarget?
    ) {
        switch command.operation {
        case .clearSession:
            clearCurrentSession()
            entryFocusSequence += 1
        case .help:
            append(.init(kind: .user, text: originalText))
            append(.init(kind: .assistant, text: Self.slashHelpText()))
        case .askContext(let goal):
            append(.init(kind: .user, text: originalText))
            handleSubmitIntent(
                .askContext,
                trimmed: goal,
                tabManager: tabManager,
                workspaceTabStore: workspaceTabStore,
                forceApply: false,
                workspaceTarget: workspaceTarget
            )
        case .undoSort:
            append(.init(kind: .user, text: originalText))
            handleSubmitIntent(
                .undoSort,
                trimmed: String(localized: "sortAssistant.slash.undo.goal", defaultValue: "Undo the latest assistant sort."),
                tabManager: tabManager,
                workspaceTabStore: workspaceTabStore,
                forceApply: false,
                workspaceTarget: workspaceTarget
            )
        case .explainCurrentOrder(let goal):
            append(.init(kind: .user, text: originalText))
            handleSubmitIntent(
                .explainCurrentOrder,
                trimmed: goal,
                tabManager: tabManager,
                workspaceTabStore: workspaceTabStore,
                forceApply: false,
                workspaceTarget: workspaceTarget
            )
        case .proposeSort(let goal):
            append(.init(kind: .user, text: originalText))
            if let sort = Self.fixedSortCommand(argument: goal) {
                runFixedSortCommand(
                    sort,
                    goal: goal,
                    mode: .preview,
                    tabManager: tabManager,
                    workspaceTabStore: workspaceTabStore
                )
                return
            }
            handleSubmitIntent(
                .proposeSort,
                trimmed: goal,
                tabManager: tabManager,
                workspaceTabStore: workspaceTabStore,
                forceApply: false,
                workspaceTarget: workspaceTarget
            )
        case .applySort(let goal):
            append(.init(kind: .user, text: originalText))
            if let sort = Self.fixedSortCommand(argument: goal) {
                runFixedSortCommand(
                    sort,
                    goal: goal,
                    mode: .apply,
                    tabManager: tabManager,
                    workspaceTabStore: workspaceTabStore
                )
                return
            }
            handleSubmitIntent(
                .applySort,
                trimmed: goal,
                tabManager: tabManager,
                workspaceTabStore: workspaceTabStore,
                forceApply: true,
                workspaceTarget: workspaceTarget
            )
        case .listMemories:
            append(.init(kind: .user, text: originalText))
            startMCPAssistant(
                goal: String(localized: "sortAssistant.slash.memory.goal", defaultValue: "List saved free-sort memories and sprite workspace memories."),
                intent: .normalChat,
                route: SortAssistantActionRoute(
                    mode: .readOnly,
                    needsConfirmation: false,
                    allowedTools: ["memory_query", "sprite_memory_query"],
                    memoryWritePolicy: .none
                ),
                tabManager: tabManager,
                workspaceTabStore: workspaceTabStore,
                workspaceTarget: workspaceTarget
            )
        case .rememberSpriteMemory(let text):
            guard !text.isEmpty else {
                appendSlashUsage(originalText: originalText, usage: "/remember <memory>")
                return
            }
            append(.init(kind: .user, text: originalText))
            handleSubmitIntent(
                .rememberSpriteMemory,
                trimmed: text,
                tabManager: tabManager,
                workspaceTabStore: workspaceTabStore,
                forceApply: false,
                workspaceTarget: workspaceTarget
            )
        case .forgetSpriteMemory(let text):
            guard !text.isEmpty else {
                appendSlashUsage(originalText: originalText, usage: "/forget <memory-id-or-text>")
                return
            }
            append(.init(kind: .user, text: originalText))
            handleSubmitIntent(
                .forgetSpriteMemory,
                trimmed: text,
                tabManager: tabManager,
                workspaceTabStore: workspaceTabStore,
                forceApply: false,
                workspaceTarget: workspaceTarget
            )
        case .rememberFreeSortMemory(let text):
            guard !text.isEmpty else {
                appendSlashUsage(originalText: originalText, usage: "/remember-sort <sorting preference>")
                return
            }
            append(.init(kind: .user, text: originalText))
            handleSubmitIntent(
                .rememberPreference,
                trimmed: text,
                tabManager: tabManager,
                workspaceTabStore: workspaceTabStore,
                forceApply: false,
                workspaceTarget: workspaceTarget
            )
        case .forgetFreeSortMemory(let text):
            guard !text.isEmpty else {
                appendSlashUsage(originalText: originalText, usage: "/forget-sort <memory-id-or-text>")
                return
            }
            append(.init(kind: .user, text: originalText))
            handleSubmitIntent(
                .forgetPreference,
                trimmed: text,
                tabManager: tabManager,
                workspaceTabStore: workspaceTabStore,
                forceApply: false,
                workspaceTarget: workspaceTarget
            )
        case .setPinned(let pinned):
            append(.init(kind: .user, text: originalText))
            guard command.argument.isEmpty || workspaceTarget != nil else {
                appendWorkspaceCommandTargetError()
                return
            }
            guard let target = workspaceTarget ?? Self.selectedWorkspaceTarget(tabManager: tabManager),
                  socketSetPinned(itemId: target.id, pinned: pinned) != nil else {
                appendWorkspaceCommandUnavailable()
                return
            }
            let message = pinned
                ? String(
                    format: String(localized: "sortAssistant.slash.pin.done", defaultValue: "Pinned %@."),
                    target.title
                )
                : String(
                    format: String(localized: "sortAssistant.slash.unpin.done", defaultValue: "Unpinned %@."),
                    target.title
                )
            append(.init(
                kind: .assistant,
                text: message
            ))
        case .setLocked(let locked):
            append(.init(kind: .user, text: originalText))
            guard command.argument.isEmpty || workspaceTarget != nil else {
                appendWorkspaceCommandTargetError()
                return
            }
            guard let target = workspaceTarget ?? Self.selectedWorkspaceTarget(tabManager: tabManager) else {
                appendWorkspaceCommandUnavailable()
                return
            }
            _ = socketSetLocked(itemId: target.id, locked: locked)
            let message = locked
                ? String(
                    format: String(localized: "sortAssistant.slash.lock.done", defaultValue: "Locked %@ for sorting."),
                    target.title
                )
                : String(
                    format: String(localized: "sortAssistant.slash.unlock.done", defaultValue: "Unlocked %@ for sorting."),
                    target.title
                )
            append(.init(
                kind: .assistant,
                text: message
            ))
        case .selectWorkspace:
            append(.init(kind: .user, text: originalText))
            guard let target = workspaceTarget,
                  let workspace = tabManager.tabs.first(where: { $0.id == target.id }) else {
                append(.init(
                    kind: .error,
                    text: String(localized: "sortAssistant.slash.select.usage", defaultValue: "Usage: /select @workspace")
                ))
                return
            }
            tabManager.selectWorkspace(workspace)
            append(.init(
                kind: .assistant,
                text: String(
                    format: String(
                        localized: "sortAssistant.slash.select.done",
                        defaultValue: "Selected %@."
                    ),
                    target.title
                )
            ))
        }
    }

    private func appendSlashUsage(originalText: String, usage: String) {
        append(.init(kind: .user, text: originalText))
        append(.init(
            kind: .error,
            text: String(localized: "sortAssistant.slash.usage", defaultValue: "Usage: \(usage)")
        ))
    }

    private func appendWorkspaceCommandTargetError() {
        append(.init(
            kind: .error,
            text: String(
                localized: "sortAssistant.slash.workspaceTargetRequired",
                defaultValue: "Use @workspace to target a workspace, or omit the argument to use the current workspace."
            )
        ))
    }

    private func appendWorkspaceCommandUnavailable() {
        append(.init(
            kind: .error,
            text: String(
                localized: "sortAssistant.slash.workspaceUnavailable",
                defaultValue: "No matching workspace is available."
            )
        ))
    }

    private static func slashHelpText() -> String {
        let commandLines = SortAssistantSlashCommand.descriptors.map { descriptor in
            "- \(descriptor.displayText): \(descriptor.summary)"
        }
        let workspaceLine = String(
            localized: "sortAssistant.slash.workspaceMention.help",
            defaultValue: "Use @workspace with commands or questions to target a specific workspace."
        )
        return ([workspaceLine] + commandLines).joined(separator: "\n")
    }

    private static func fixedSortCommand(argument: String) -> WorkspaceSidebarSummaryPrioritySort? {
        let normalized = argument
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
        switch normalized {
        case "recent", "recentactivity", "recentuse", "recentlyused", "lastused", "mru", "最近", "最近使用", "最近使用顺序":
            return .recent
        case "native", "nativeorder", "manual", "manualorder", "current", "currentorder", "default", "原始", "当前", "手动":
            return .native
        default:
            return nil
        }
    }

    private func runFixedSortCommand(
        _ sort: WorkspaceSidebarSummaryPrioritySort,
        goal: String,
        mode: SortAssistantRunMode,
        tabManager: TabManager,
        workspaceTabStore: WorkspaceTabStore
    ) {
        guard !isSorting else {
            append(.init(
                kind: .assistant,
                text: String(localized: "sortAssistant.sort.busy", defaultValue: "A workspace sort is already running.")
            ))
            return
        }

        rememberStores(tabManager: tabManager, workspaceTabStore: workspaceTabStore)
        let orderedIds = Self.fixedSortWorkspaceOrder(
            sort,
            tabManager: tabManager,
            workspaceTabStore: workspaceTabStore
        )
        guard !orderedIds.isEmpty else {
            append(.init(
                kind: .error,
                text: String(localized: "sortAssistant.sort.noOrder", defaultValue: "Digest returned no applicable workspace order.")
            ))
            return
        }

        let label = Self.dimensionLabel(sort)
        let patch = sortOperator.makeBatchPatch(
            orderedIds: orderedIds,
            tabs: tabManager.tabs,
            rationale: Self.fixedSortRationale(sort),
            confidence: nil,
            requiresConfirmation: mode == .preview
        )
        let itemSignals = contextProvider.itemSignals(tabManager: tabManager, workspaceTabStore: workspaceTabStore)

        do {
            switch mode {
            case .preview:
                let preview = try sortOperator.preview(
                    patch: patch,
                    tabs: tabManager.tabs,
                    itemSignals: itemSignals
                )
                pendingPreviewPatch = patch
                pendingPreviewSort = sort
                let result = SortAssistantSortResult(
                    title: String(localized: "sortAssistant.preview.title", defaultValue: "Preview sorted by \(label)"),
                    goal: goal,
                    dimensionLabel: label,
                    changes: preview.changes,
                    rationale: preview.rationale,
                    patchId: patch.id,
                    mode: .preview,
                    canUndo: false,
                    canApply: true,
                    canApplyPartially: true,
                    canIgnore: true,
                    actions: Self.allowedResultActions(for: .preview)
                )
                let anchorMessageId = append(.init(
                    kind: .assistant,
                    text: String(localized: "sortAssistant.preview.ready", defaultValue: "I prepared a sort preview.")
                ))
                setLatestResult(result, anchorMessageId: anchorMessageId)
            case .apply:
                let applied = try sortOperator.apply(
                    patch: patch,
                    tabManager: tabManager,
                    itemSignals: itemSignals,
                    actor: "sort_assistant_fixed_sort"
                )
                pendingPreviewPatch = nil
                pendingPreviewSort = nil
                workspaceTabStore.setSort(sort)
                let result = SortAssistantSortResult(
                    title: String(localized: "sortAssistant.result.title", defaultValue: "Sorted by \(label)"),
                    goal: goal,
                    dimensionLabel: label,
                    changes: applied.preview.changes,
                    rationale: applied.preview.rationale,
                    patchId: patch.id,
                    mode: .applied,
                    canUndo: true,
                    canApply: false,
                    canApplyPartially: false,
                    canIgnore: false,
                    actions: Self.allowedResultActions(for: .apply)
                )
                let anchorMessageId = append(.init(
                    kind: .assistant,
                    text: String(localized: "sortAssistant.sort.done", defaultValue: "Applied the workspace sort.")
                ))
                setLatestResult(result, anchorMessageId: anchorMessageId)
            }
        } catch {
            pendingPreviewPatch = nil
            pendingPreviewSort = nil
            append(.init(
                kind: .error,
                text: String(localized: "sortAssistant.sort.failed", defaultValue: "Sort failed: ") + Self.displayMessage(for: error)
            ))
        }
    }

    private static func fixedSortWorkspaceOrder(
        _ sort: WorkspaceSidebarSummaryPrioritySort,
        tabManager: TabManager,
        workspaceTabStore: WorkspaceTabStore
    ) -> [UUID] {
        let currentIds = tabManager.tabs.map(\.id)
        if sort.isRecent {
            return recentWorkspaceOrder(
                currentWorkspaceIds: currentIds,
                recentWorkspaceIds: workspaceTabStore.recentWorkspaceIds
            )
        }
        return currentIds
    }

    private static func recentWorkspaceOrder(
        currentWorkspaceIds: [UUID],
        recentWorkspaceIds: [UUID]
    ) -> [UUID] {
        let nativeOrderById = Dictionary(uniqueKeysWithValues: currentWorkspaceIds.enumerated().map { index, id in
            (id, index)
        })
        var recentOrderById: [UUID: Int] = [:]
        for (index, id) in recentWorkspaceIds.enumerated() where recentOrderById[id] == nil {
            recentOrderById[id] = index
        }
        return currentWorkspaceIds.sorted { lhs, rhs in
            switch (recentOrderById[lhs], recentOrderById[rhs]) {
            case let (lhsOrder?, rhsOrder?):
                return lhsOrder < rhsOrder
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return (nativeOrderById[lhs] ?? 0) < (nativeOrderById[rhs] ?? 0)
            }
        }
    }

    private static func fixedSortRationale(_ sort: WorkspaceSidebarSummaryPrioritySort) -> String {
        if sort.isRecent {
            return String(
                localized: "sortAssistant.sort.recentRationale",
                defaultValue: "Sort workspaces by most recent selection."
            )
        }
        return String(
            localized: "sortAssistant.sort.nativeRationale",
            defaultValue: "Keep the current native workspace order."
        )
    }

    private func handleSubmitIntent(
        _ intent: SortAssistantIntent,
        trimmed: String,
        tabManager: TabManager,
        workspaceTabStore: WorkspaceTabStore,
        forceApply: Bool,
        workspaceTarget: SortAssistantWorkspaceTarget? = nil
    ) {
        if intent == .clearSession {
            clearCurrentSession()
            entryFocusSequence += 1
            return
        }

        var route = actionRouter.route(for: intent)
        if forceApply, intent == .applySort {
            route = SortAssistantActionRoute(
                mode: .applyAllowed,
                needsConfirmation: false,
                allowedTools: route.allowedTools,
                memoryWritePolicy: route.memoryWritePolicy
            )
        }

        startMCPAssistant(
            goal: trimmed,
            intent: intent,
            route: route,
            tabManager: tabManager,
            workspaceTabStore: workspaceTabStore,
            workspaceTarget: workspaceTarget
        )
    }

    private func startMCPAssistant(
        goal: String,
        intent: SortAssistantIntent,
        route: SortAssistantActionRoute,
        tabManager: TabManager,
        workspaceTabStore: WorkspaceTabStore,
        workspaceTarget: SortAssistantWorkspaceTarget? = nil
    ) {
        guard !isSorting else {
            append(.init(
                kind: .assistant,
                text: String(localized: "sortAssistant.sort.busy", defaultValue: "A workspace sort is already running.")
            ))
            return
        }

        rememberStores(tabManager: tabManager, workspaceTabStore: workspaceTabStore)
        choicePrompt = nil
        isSorting = true
        let conversationContext = semanticConversationContext(workspaceTarget: workspaceTarget)
        append(.init(
            kind: .progress,
            text: String(localized: "sortAssistant.mcp.running", defaultValue: "Calling sprite MCP tools...")
        ))

        let request = SortAssistantMCPRequest(
            goal: goal,
            intent: intent,
            route: route,
            conversationContext: conversationContext,
            workspaceId: workspaceTarget?.id.uuidString ?? tabManager.selectedTabId?.uuidString,
            workspaceDirectory: workspaceTarget?.directory ?? Self.workspaceDirectoryForMCP(tabManager: tabManager),
            socketPath: SocketControlSettings.socketPath(),
            cmuxCLIPath: Self.cmuxCLIPathForMCP()
        )
        let generation = sessionGeneration
        Task { [weak self, weak tabManager, weak workspaceTabStore] in
            guard let self else { return }
            do {
                let result = try await self.mcpClient.run(request)
                guard self.sessionGeneration == generation else { return }
                self.isSorting = false
                guard let tabManager, let workspaceTabStore else { return }
                self.handleMCPRunResult(
                    result,
                    goal: goal,
                    intent: intent,
                    route: route,
                    tabManager: tabManager,
                    workspaceTabStore: workspaceTabStore,
                    workspaceTarget: workspaceTarget
                )
            } catch {
                guard self.sessionGeneration == generation else { return }
                self.isSorting = false
                self.append(.init(
                    kind: .error,
                    text: String(localized: "sortAssistant.mcp.failed", defaultValue: "Sprite MCP request failed: ") + Self.displayMessage(for: error)
                ))
            }
        }
    }

    private func handleMCPRunResult(
        _ result: SortAssistantMCPRunResult,
        goal: String,
        intent: SortAssistantIntent,
        route: SortAssistantActionRoute,
        tabManager: TabManager,
        workspaceTabStore: WorkspaceTabStore,
        workspaceTarget: SortAssistantWorkspaceTarget?
    ) {
        let result = localFallbackResult(
            replacingUnavailableToolMessageIfNeeded: result,
            goal: goal,
            intent: intent,
            tabManager: tabManager,
            workspaceTabStore: workspaceTabStore
        )
        let inferredChoicePrompt = result.choicePrompt ?? Self.inferredChoicePrompt(
            from: result.message,
            goal: goal,
            intent: intent
        )
        let message = result.choicePrompt == nil && inferredChoicePrompt != nil ? "" : result.message
        let anchorMessageId: UUID?
        if !message.isEmpty {
            anchorMessageId = append(.init(kind: .assistant, text: message))
        } else if memoryCandidate != nil {
            anchorMessageId = append(.init(
                kind: .assistant,
                text: String(localized: "sortAssistant.memory.reviewPrompt", defaultValue: "Review this memory before saving it.")
            ))
        } else {
            anchorMessageId = messages.last?.id
        }

        if let inferredChoicePrompt {
            latestResult = nil
            pendingPreviewPatch = nil
            pendingPreviewSort = nil
            choicePrompt = inferredChoicePrompt.preparedForFollowUp(
                intent: intent,
                forceApply: route.mode == .applyAllowed && !route.needsConfirmation,
                workspaceTarget: workspaceTarget
            )
            return
        }

        guard let card = result.card else { return }
        choicePrompt = nil
        let dimensionLabel = card.dimensionLabel ?? Self.dimensionLabel(workspaceTabStore.selectedSort)
        setLatestResult(SortAssistantSortResult(
            title: card.title,
            goal: goal,
            dimensionLabel: dimensionLabel,
            changes: card.changes,
            rationale: card.rationale,
            patchId: card.patchId,
            mode: card.mode,
            canUndo: card.mode == .applied,
            canApply: card.mode == .preview,
            canApplyPartially: card.mode == .preview,
            canIgnore: card.mode == .preview,
            actions: Self.availableResultActions(card.actions, resultMode: card.mode)
        ), anchorMessageId: anchorMessageId)

    }

    private struct LocalFallbackWorkspaceRow {
        let title: String
        let detail: String?
    }

    private func localFallbackResult(
        replacingUnavailableToolMessageIfNeeded result: SortAssistantMCPRunResult,
        goal: String,
        intent: SortAssistantIntent,
        tabManager: TabManager,
        workspaceTabStore: WorkspaceTabStore
    ) -> SortAssistantMCPRunResult {
        guard result.card == nil,
              Self.isUnavailableToolMessage(result.message) else {
            return result
        }
        return SortAssistantMCPRunResult(
            message: localFallbackMessage(
                goal: goal,
                intent: intent,
                tabManager: tabManager,
                workspaceTabStore: workspaceTabStore
            ),
            card: nil
        )
    }

    private static func isUnavailableToolMessage(_ message: String) -> Bool {
        let lowercased = message.lowercased()
        guard lowercased.contains("tool")
            || lowercased.contains("mcp")
            || lowercased.contains("sort context") else {
            return false
        }
        return lowercased.contains("not currently available")
            || lowercased.contains("aren't currently available")
            || lowercased.contains("need the sort context tools")
            || lowercased.contains("cannot access")
    }

    private static func inferredChoicePrompt(
        from message: String,
        goal: String,
        intent: SortAssistantIntent
    ) -> SortAssistantChoicePrompt? {
        guard intent == .proposeSort || intent == .applySort else { return nil }
        let lowercasedMessage = message.lowercased()
        let lowercasedGoal = goal.lowercased()
        guard lowercasedMessage.contains("unfinished work"),
              lowercasedMessage.contains("pr activity"),
              lowercasedMessage.contains("clarify"),
              lowercasedMessage.contains("urgent") || lowercasedGoal.contains("urgent") || lowercasedGoal.contains("urgency") else {
            return nil
        }
        return SortAssistantChoicePrompt(
            title: String(localized: "sortAssistant.choice.urgent.title", defaultValue: "Choose urgent signal"),
            message: String(
                localized: "sortAssistant.choice.urgent.message",
                defaultValue: "Pick the signal to use for this sort."
            ),
            options: [
                SortAssistantChoicePrompt.Option(
                    id: "unfinished_work",
                    title: String(localized: "sortAssistant.choice.urgent.unfinished.title", defaultValue: "Unfinished work"),
                    subtitle: String(
                        localized: "sortAssistant.choice.urgent.unfinished.subtitle",
                        defaultValue: "Prioritize local changes, active tasks, blockers, or other in-progress work."
                    ),
                    goal: String(
                        localized: "sortAssistant.choice.urgent.unfinished.goal",
                        defaultValue: "Sort by unfinished work: prioritize workspaces with uncommitted local changes, in-progress tasks, blockers, or other active work."
                    )
                ),
                SortAssistantChoicePrompt.Option(
                    id: "pr_activity",
                    title: String(localized: "sortAssistant.choice.urgent.pr.title", defaultValue: "PR activity"),
                    subtitle: String(
                        localized: "sortAssistant.choice.urgent.pr.subtitle",
                        defaultValue: "Prioritize linked PRs awaiting review, CI, or recent review activity."
                    ),
                    goal: String(
                        localized: "sortAssistant.choice.urgent.pr.goal",
                        defaultValue: "Sort by PR activity: prioritize workspaces with linked PRs awaiting review, failing or running CI, or recent review activity."
                    )
                ),
                SortAssistantChoicePrompt.Option(
                    id: "current_urgency",
                    title: String(localized: "sortAssistant.choice.urgent.current.title", defaultValue: "Current urgency signals"),
                    subtitle: String(
                        localized: "sortAssistant.choice.urgent.current.subtitle",
                        defaultValue: "Use digest, GitHub context, and saved sorting memory."
                    ),
                    goal: String(
                        localized: "sortAssistant.choice.urgent.current.goal",
                        defaultValue: "Sort by current urgency signals: use workspace digest status, GitHub context, and saved free-sort memories to rank urgency."
                    )
                ),
            ]
        )
    }

    private func localFallbackMessage(
        goal: String,
        intent: SortAssistantIntent,
        tabManager: TabManager,
        workspaceTabStore: WorkspaceTabStore
    ) -> String {
        let rows = localFallbackWorkspaceRows(
            tabManager: tabManager,
            workspaceTabStore: workspaceTabStore,
            limit: 5
        )
        guard !rows.isEmpty else {
            return String(
                localized: "sortAssistant.localFallback.empty",
                defaultValue: "I can read the local sidebar cache, but there are no workspace rows available yet."
            )
        }

        var lines: [String]
        switch intent {
        case .askContext, .explainCurrentOrder:
            lines = [
                String(
                    format: String(
                        localized: "sortAssistant.localFallback.contextIntro",
                        defaultValue: "Current sidebar has %d workspaces."
                    ),
                    tabManager.tabs.count
                ),
                "",
                String(
                    localized: "sortAssistant.localFallback.contextHeading",
                    defaultValue: "Top local sidebar signals:"
                ),
            ]
        default:
            let normalizedGoal = Self.nonEmpty(goal)
            lines = [
                normalizedGoal.map {
                    String(
                        format: String(
                            localized: "sortAssistant.localFallback.goalIntro",
                            defaultValue: "Using the local sidebar cache for: %@"
                        ),
                        $0
                    )
                } ?? String(
                    localized: "sortAssistant.localFallback.intro",
                    defaultValue: "I can use the local sidebar cache directly."
                ),
                "",
                String(
                    localized: "sortAssistant.localFallback.recommendationHeading",
                    defaultValue: "Suggested next focus:"
                ),
            ]
        }

        for (index, row) in rows.enumerated() {
            let detail = row.detail.map { " — \($0)" } ?? ""
            lines.append("\(index + 1). \(row.title)\(detail)")
        }
        return lines.joined(separator: "\n")
    }

    private func localFallbackWorkspaceRows(
        tabManager: TabManager,
        workspaceTabStore: WorkspaceTabStore,
        limit: Int
    ) -> [LocalFallbackWorkspaceRow] {
        let tabsById = Dictionary(uniqueKeysWithValues: tabManager.tabs.map { ($0.id, $0) })
        let summaryItemsById: [UUID: WorkspaceSidebarSummaryPriorityItem] = (workspaceTabStore.summaryPriority?.items ?? [])
            .reduce(into: [:]) { partial, item in
                guard let id = UUID(uuidString: item.workspaceId), partial[id] == nil else { return }
                partial[id] = item
            }
        let signalsById = contextProvider.itemSignals(
            tabManager: tabManager,
            workspaceTabStore: workspaceTabStore
        )

        return localFallbackWorkspaceIds(
            tabManager: tabManager,
            workspaceTabStore: workspaceTabStore
        )
        .prefix(limit)
        .compactMap { workspaceId in
            guard let workspace = tabsById[workspaceId] else { return nil }
            let item = summaryItemsById[workspaceId]
            let context = workspaceTabStore.contextSummary(for: workspaceId)
            let signal = signalsById[workspaceId]
            let fallbackIndex = tabManager.tabs.firstIndex { $0.id == workspaceId }.map { $0 + 1 } ?? 1
            let title = Self.nonPlaceholder(item?.title)
                ?? Self.nonPlaceholder(context?.title)
                ?? Self.nonPlaceholder(signal?.title)
                ?? Self.nonPlaceholder(workspace.title)
                ?? String(
                    format: String(
                        localized: "sortAssistant.localFallback.workspaceTitle",
                        defaultValue: "Workspace %d"
                    ),
                    fallbackIndex
                )
            return LocalFallbackWorkspaceRow(
                title: title,
                detail: Self.localFallbackDetail(
                    item: item,
                    context: context,
                    signal: signal,
                    sort: workspaceTabStore.selectedSort
                )
            )
        }
    }

    private func localFallbackWorkspaceIds(
        tabManager: TabManager,
        workspaceTabStore: WorkspaceTabStore
    ) -> [UUID] {
        var orderedIds: [UUID] = []
        if let summary = workspaceTabStore.summaryPriority {
            let sortedIds = WorkspaceTabStore.orderedWorkspaceIds(
                from: summary,
                tabs: tabManager.tabs,
                sort: workspaceTabStore.selectedSort,
                recentWorkspaceIds: workspaceTabStore.recentWorkspaceIds
            )
            if sortedIds.isEmpty {
                orderedIds.append(contentsOf: summary.items.compactMap { UUID(uuidString: $0.workspaceId) })
            } else {
                orderedIds.append(contentsOf: sortedIds)
            }
        }
        orderedIds.append(contentsOf: tabManager.tabs.map(\.id))

        let currentIds = Set(tabManager.tabs.map(\.id))
        var seen = Set<UUID>()
        return orderedIds.filter { id in
            currentIds.contains(id) && seen.insert(id).inserted
        }
    }

    private static func localFallbackDetail(
        item: WorkspaceSidebarSummaryPriorityItem?,
        context: WorkspaceTabContextSummary?,
        signal: SortAssistantSortContext.ItemSignals?,
        sort: WorkspaceSidebarSummaryPrioritySort
    ) -> String? {
        var parts: [String] = []
        if let priority = nonPlaceholder(signal?.priority) {
            parts.append(priority)
        } else if let score = localFallbackScore(item: item, sort: sort) {
            parts.append(
                String(
                    format: String(
                        localized: "sortAssistant.localFallback.score",
                        defaultValue: "score %d"
                    ),
                    Int(score.rounded())
                )
            )
        }
        if let status = nonPlaceholder(item?.presentStatus)
            ?? nonPlaceholder(item?.status)
            ?? nonPlaceholder(context?.status)
            ?? nonPlaceholder(signal?.status) {
            parts.append(status)
        }
        if let next = nonPlaceholder(item?.nextAction?.label)
            ?? nonPlaceholder(context?.next) {
            parts.append(
                String(localized: "sortAssistant.localFallback.nextPrefix", defaultValue: "next: ") + next
            )
        }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    private static func localFallbackScore(
        item: WorkspaceSidebarSummaryPriorityItem?,
        sort: WorkspaceSidebarSummaryPrioritySort
    ) -> Double? {
        guard let item else { return nil }
        if sort.isDimension, let dimensionId = sort.dimensionId {
            return item.scores.dimensions[dimensionId]?.rawScore
        }
        return item.scores.dimensions["urgency"]?.rawScore
            ?? item.scores.dimensions.values.map(\.rawScore).max()
    }

    private static func nonPlaceholder(_ text: String?) -> String? {
        guard let value = nonEmpty(text) else { return nil }
        return value == "—" ? nil : value
    }

    private static func cmuxCLIPathForMCP() -> String {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["CMUX_DIGEST_CMUX"],
           FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        if let resources = Bundle.main.resourceURL {
            let bundled = resources.appendingPathComponent("bin/cmux").path
            if FileManager.default.isExecutableFile(atPath: bundled) {
                return bundled
            }
        }
        if FileManager.default.isExecutableFile(atPath: "/tmp/cmux-cli") {
            return "/tmp/cmux-cli"
        }
        return "cmux"
    }

    private static func workspaceDirectoryForMCP(tabManager: TabManager) -> String? {
        guard let workspace = tabManager.selectedWorkspace else { return nil }
        return workspaceDirectoryForMCP(workspace: workspace)
    }

    private static func workspaceDirectoryForMCP(workspace: Workspace) -> String? {
        if let focusedPanelId = workspace.focusedPanelId,
           let directory = normalizedDirectoryForMCP(workspace.panelDirectories[focusedPanelId]) {
            return directory
        }
        if let directory = normalizedDirectoryForMCP(workspace.surfaceTabBarDirectory) {
            return directory
        }
        return workspace.panelDirectories.values.lazy.compactMap(normalizedDirectoryForMCP).first
    }

    private static func normalizedDirectoryForMCP(_ directory: String?) -> String? {
        guard let directory else { return nil }
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func answerDimensionQuestion(
        dimensionId: String,
        goal: String,
        tabManager: TabManager,
        workspaceTabStore: WorkspaceTabStore
    ) {
        let mode = dimensionQuestion?.mode ?? .apply
        dimensionQuestion = nil
        rememberStores(tabManager: tabManager, workspaceTabStore: workspaceTabStore)
        workspaceTabStore.setSort(.dimension(id: dimensionId))
        let intent: SortAssistantIntent = mode == .apply ? .applySort : .proposeSort
        startMCPAssistant(
            goal: goal,
            intent: intent,
            route: actionRouter.route(for: intent),
            tabManager: tabManager,
            workspaceTabStore: workspaceTabStore
        )
    }

    func answerChoicePrompt(
        _ option: SortAssistantChoicePrompt.Option,
        tabManager: TabManager,
        workspaceTabStore: WorkspaceTabStore
    ) {
        guard let prompt = choicePrompt else { return }
        choicePrompt = nil
        append(.init(kind: .user, text: option.title))
        let intent = prompt.followUpIntent ?? .proposeSort
        handleSubmitIntent(
            intent,
            trimmed: option.goal,
            tabManager: tabManager,
            workspaceTabStore: workspaceTabStore,
            forceApply: prompt.forceApply,
            workspaceTarget: prompt.workspaceTarget
        )
    }

    func dismissChoicePrompt() {
        choicePrompt = nil
    }

    func undo(tabManager: TabManager) {
        do {
            guard try sortOperator.undo(tabManager: tabManager) != nil else {
                append(.init(
                    kind: .assistant,
                    text: String(localized: "sortAssistant.undo.none", defaultValue: "There is no assistant sort to undo.")
                ))
                return
            }
            pendingPreviewPatch = nil
            pendingPreviewSort = nil
            latestResult?.canUndo = false
            latestResult?.canApply = false
            latestResult?.canApplyPartially = false
            latestResult?.canIgnore = false
            append(.init(
                kind: .assistant,
                text: String(localized: "sortAssistant.undo.done", defaultValue: "Restored the previous workspace order.")
            ))
        } catch {
            append(.init(
                kind: .error,
                text: String(localized: "sortAssistant.undo.failed", defaultValue: "Undo failed: ") + Self.displayMessage(for: error)
            ))
        }
    }

    func createMemoryCandidateFromResult() {
        guard let latestResult else { return }
        let text = String(
            localized: "sortAssistant.memory.fromResult",
            defaultValue: "When sorting workspaces, consider: \(latestResult.goal)"
        )
        memoryCandidate = SortAssistantMemoryCandidate(
            text: text,
            sourceSummary: latestResult.rationale
        )
    }

    func updateMemoryCandidate(text: String) {
        guard var candidate = memoryCandidate else { return }
        candidate.text = text
        memoryCandidate = candidate
    }

    func confirmMemoryCandidate() {
        guard let candidate = memoryCandidate else { return }
        let text = normalized(candidate.text)
        guard !text.isEmpty else { return }
        let memory = SortAssistantMemory(id: UUID(), text: text, createdAt: Date())
        if candidate.target == .sprite {
            let directory = currentSpriteMemoryDirectory ?? lastTabManager.flatMap(Self.workspaceDirectoryForMCP)
            do {
                if let fileURL = try SpriteWorkspaceMemoryDocument.append(memory, directory: directory) {
                    spriteMemories.insert(memory, at: 0)
                    spriteMemorySources[memory.id] = .workspace(fileURL)
                    currentSpriteMemoryFileURL = fileURL
                    memoryCandidate = nil
                    append(.init(
                        kind: .assistant,
                        text: String(localized: "sortAssistant.spriteMemory.savedToFileReply", defaultValue: "Saved that sprite memory to memory.md.")
                    ))
                    return
                }
                append(.init(
                    kind: .error,
                    text: String(localized: "sortAssistant.spriteMemory.noWorkspaceDirectory", defaultValue: "No workspace directory is available for memory.md.")
                ))
                return
            } catch {
                append(.init(
                    kind: .error,
                    text: String(localized: "sortAssistant.spriteMemory.saveFileFailed", defaultValue: "Could not write memory.md: ") + Self.displayMessage(for: error)
                ))
                return
            }
        }

        memories.insert(memory, at: 0)
        persistCreatedMemory(memory)
        memoryCandidate = nil
        append(.init(
            kind: .assistant,
            text: String(localized: "sortAssistant.memory.savedReply", defaultValue: "Saved that sorting memory.")
        ))
    }

    func discardMemoryCandidate() {
        memoryCandidate = nil
        append(.init(
            kind: .assistant,
            text: String(localized: "sortAssistant.memory.discardedReply", defaultValue: "Discarded the memory candidate.")
        ))
    }

    func deleteMemory(_ memory: SortAssistantMemory) {
        memories.removeAll { $0.id == memory.id }
        Task {
            try? await SortAssistantWorkstreamPersistence.shared.rewriteDroppingToolResults(
                toolName: Self.memoryToolName,
                containing: memory.id.uuidString
            )
        }
    }

    func deleteSpriteMemory(_ memory: SortAssistantMemory) {
        spriteMemories.removeAll { $0.id == memory.id }
        guard case .some(.workspace(let fileURL)) = spriteMemorySources.removeValue(forKey: memory.id) else {
            return
        }
        try? SpriteWorkspaceMemoryDocument.delete(
            memoryId: memory.id,
            containing: nil,
            from: fileURL
        )
    }

    func applyLatestPreview(
        tabManager: TabManager,
        workspaceTabStore: WorkspaceTabStore
    ) {
        applyPendingPreview(
            tabManager: tabManager,
            workspaceTabStore: workspaceTabStore,
            partialLimit: nil
        )
    }

    func applyLatestPreviewPartially(
        tabManager: TabManager,
        workspaceTabStore: WorkspaceTabStore
    ) {
        applyPendingPreview(
            tabManager: tabManager,
            workspaceTabStore: workspaceTabStore,
            partialLimit: 5
        )
    }

    func rejectLatestPreview() {
        guard let patch = pendingPreviewPatch else { return }
        sortOperator.reject(
            patch: patch,
            reason: String(localized: "sortAssistant.preview.rejectedReason", defaultValue: "Rejected from sprite preview")
        )
        pendingPreviewPatch = nil
        pendingPreviewSort = nil
        latestResult?.canApply = false
        latestResult?.canApplyPartially = false
        latestResult?.canIgnore = false
        append(.init(
            kind: .assistant,
            text: String(localized: "sortAssistant.preview.ignored", defaultValue: "Ignored that sort proposal.")
        ))
    }

    func explainLatestPreview() {
        if let rationale = latestResult?.rationale, !rationale.isEmpty {
            append(.init(kind: .assistant, text: rationale))
            return
        }
        if let changes = latestResult?.changes, !changes.isEmpty {
            append(.init(
                kind: .assistant,
                text: changes.joined(separator: "\n")
            ))
            return
        }
        append(.init(
            kind: .assistant,
            text: String(localized: "sortAssistant.preview.noExplanation", defaultValue: "This proposal follows the selected priority dimension, saved memories, pinned workspace rules, and locked workspace rules.")
        ))
    }

    func recordUserDragMove(
        itemId: UUID,
        fromIndex: Int,
        toIndex: Int,
        revision: Int,
        reason: String? = nil
    ) {
        sortOperator.recordUserDragMove(
            itemId: itemId,
            fromIndex: fromIndex,
            toIndex: toIndex,
            revision: revision,
            reason: reason
        )
    }

    @discardableResult
    func applySummaryPriorityWorkspaceOrder(
        _ summaryPriority: WorkspaceSidebarSummaryPriorityState,
        tabManager: TabManager,
        workspaceTabStore: WorkspaceTabStore
    ) -> Bool {
        rememberStores(tabManager: tabManager, workspaceTabStore: workspaceTabStore)
        guard !workspaceTabStore.selectedSort.isNative else { return false }
        let orderedWorkspaceIds = WorkspaceTabStore.orderedWorkspaceIds(
            from: summaryPriority,
            tabs: tabManager.tabs,
            sort: workspaceTabStore.selectedSort,
            recentWorkspaceIds: workspaceTabStore.recentWorkspaceIds
        )
        guard !orderedWorkspaceIds.isEmpty else { return false }
        let patch = sortOperator.makeBatchPatch(
            orderedIds: orderedWorkspaceIds,
            tabs: tabManager.tabs,
            rationale: String(localized: "sortAssistant.summaryPriority.rationale", defaultValue: "Apply summary priority order."),
            confidence: nil,
            requiresConfirmation: false
        )
        do {
            let signals = contextProvider.itemSignals(tabManager: tabManager, workspaceTabStore: workspaceTabStore)
            _ = try sortOperator.apply(
                patch: patch,
                tabManager: tabManager,
                itemSignals: signals,
                actor: "summary_priority_sidebar"
            )
            return true
        } catch {
#if DEBUG
            cmuxDebugLog("summaryPriority.sidebar.reorder.failed \(Self.displayMessage(for: error))")
#endif
            return false
        }
    }

    private func startSort(
        goal: String,
        mode: SortAssistantRunMode,
        tabManager: TabManager,
        workspaceTabStore: WorkspaceTabStore
    ) {
        guard !isSorting else {
            append(.init(
                kind: .assistant,
                text: String(localized: "sortAssistant.sort.busy", defaultValue: "A workspace sort is already running.")
            ))
            return
        }

        let selectedSort = workspaceTabStore.selectedSort
        guard selectedSort.isDimension else {
            dimensionQuestion = SortAssistantDimensionQuestion(goal: goal, mode: mode)
            append(.init(
                kind: .assistant,
                text: String(localized: "sortAssistant.dimension.needChoice", defaultValue: "The current sort is not a priority dimension, so I need one choice first.")
            ))
            return
        }

        pendingPreviewPatch = nil
        pendingPreviewSort = nil
        latestResult = nil
        isSorting = true
        append(.init(
            kind: .progress,
            text: String(localized: "sortAssistant.sort.running", defaultValue: "Scoring workspaces with the current priority dimension...")
        ))

        let assistantContext = WorkspaceSidebarAssistantContext(
            requestId: UUID().uuidString,
            goal: goal,
            memorySnippets: memories.prefix(8).map(\.text),
            resultMode: mode.assistantContextValue,
            allowedResultActions: Self.allowedResultActions(for: mode).map(\.rawValue)
        )
        workspaceTabStore.refreshSummaryPriority(
            force: true,
            sort: selectedSort,
            assistantContext: assistantContext
        ) { [weak self, weak tabManager, weak workspaceTabStore] result in
            guard let self else { return }
            self.isSorting = false
            guard let tabManager, let workspaceTabStore else { return }
            switch result {
            case .failure(let error):
                self.latestResult = nil
                self.append(.init(
                    kind: .error,
                    text: String(localized: "sortAssistant.sort.failed", defaultValue: "Sort failed: ") + Self.displayMessage(for: error)
                ))
            case .success(let state):
                self.handleSortState(
                    state,
                    sort: selectedSort,
                    goal: goal,
                    mode: mode,
                    tabManager: tabManager,
                    workspaceTabStore: workspaceTabStore
                )
            }
        }
    }

    private func handleSortState(
        _ state: WorkspaceSidebarSummaryPriorityState,
        sort: WorkspaceSidebarSummaryPrioritySort,
        goal: String,
        mode: SortAssistantRunMode,
        tabManager: TabManager,
        workspaceTabStore: WorkspaceTabStore
    ) {
        let ordered = WorkspaceTabStore.orderedWorkspaceIds(
            from: state,
            tabs: tabManager.tabs,
            sort: sort,
            recentWorkspaceIds: workspaceTabStore.recentWorkspaceIds
        )
        guard !ordered.isEmpty else {
            latestResult = nil
            append(.init(
                kind: .error,
                text: String(localized: "sortAssistant.sort.noOrder", defaultValue: "Digest returned no applicable workspace order.")
            ))
            return
        }
        let presentation = Self.topPresentation(from: state, sort: sort)
        let patch = sortOperator.makeBatchPatch(
            orderedIds: ordered,
            tabs: tabManager.tabs,
            rationale: presentation.markdown,
            confidence: nil,
            requiresConfirmation: mode == .preview
        )
        let dimensionLabel = Self.dimensionLabel(sort)
        do {
            let preview = try sortOperator.preview(patch: patch, tabs: tabManager.tabs)
            switch mode {
            case .preview:
                pendingPreviewPatch = patch
                pendingPreviewSort = sort
                let sortResult = SortAssistantSortResult(
                    title: String(localized: "sortAssistant.preview.title", defaultValue: "Preview sorted by \(dimensionLabel)"),
                    goal: goal,
                    dimensionLabel: dimensionLabel,
                    changes: preview.changes,
                    rationale: preview.rationale,
                    patchId: patch.id,
                    mode: .preview,
                    canUndo: false,
                    canApply: true,
                    canApplyPartially: true,
                    canIgnore: true,
                    actions: Self.availableResultActions(presentation.actions, resultMode: .preview)
                )
                let anchorMessageId = append(.init(
                    kind: .assistant,
                    text: String(localized: "sortAssistant.preview.ready", defaultValue: "I prepared a sort preview.")
                ))
                setLatestResult(sortResult, anchorMessageId: anchorMessageId)
            case .apply:
                let result = try sortOperator.apply(
                    patch: patch,
                    tabManager: tabManager,
                    actor: "sort_assistant"
                )
                pendingPreviewPatch = nil
                pendingPreviewSort = nil
                let sortResult = SortAssistantSortResult(
                    title: String(localized: "sortAssistant.result.title", defaultValue: "Sorted by \(dimensionLabel)"),
                    goal: goal,
                    dimensionLabel: dimensionLabel,
                    changes: result.preview.changes,
                    rationale: result.preview.rationale,
                    patchId: patch.id,
                    mode: .applied,
                    canUndo: true,
                    canApply: false,
                    canApplyPartially: false,
                    canIgnore: false,
                    actions: Self.availableResultActions(presentation.actions, resultMode: .applied)
                )
                let anchorMessageId = append(.init(
                    kind: .assistant,
                    text: String(localized: "sortAssistant.sort.done", defaultValue: "Applied the workspace sort.")
                ))
                setLatestResult(sortResult, anchorMessageId: anchorMessageId)
            }
        } catch {
            latestResult = nil
            pendingPreviewPatch = nil
            pendingPreviewSort = nil
            append(.init(
                kind: .error,
                text: String(localized: "sortAssistant.sort.failed", defaultValue: "Sort failed: ") + Self.displayMessage(for: error)
            ))
        }
    }

    private func explainCurrentOrder(workspaceTabStore: WorkspaceTabStore) {
        guard let summary = workspaceTabStore.summaryPriority,
              let first = summary.items.first else {
            append(.init(
                kind: .assistant,
                text: String(localized: "sortAssistant.explain.empty", defaultValue: "Refresh summary priority first so I can explain the current order.")
            ))
            return
        }
        append(.init(
            kind: .assistant,
            text: first.scores.rankReason.isEmpty
                ? String(localized: "sortAssistant.explain.noReason", defaultValue: "The current order follows the selected priority dimension and pinned workspace rules.")
                : first.scores.rankReason
        ))
    }

    private func persistCreatedMemory(_ memory: SortAssistantMemory) {
        let event = SortAssistantMemoryEvent(
            schemaVersion: Self.memorySchemaVersion,
            eventType: .created,
            memoryId: memory.id.uuidString,
            text: memory.text,
            createdAt: Self.iso8601Formatter.string(from: memory.createdAt)
        )
        guard let data = try? JSONEncoder().encode(event),
              let resultJSON = String(data: data, encoding: .utf8) else {
            return
        }
        let item = WorkstreamItem(
            workstreamId: Self.workstreamId,
            source: .cmux,
            kind: .toolResult,
            title: String(localized: "sortAssistant.memory.eventTitle", defaultValue: "Sort memory"),
            payload: .toolResult(
                toolName: Self.memoryToolName,
                resultJSON: resultJSON,
                isError: false
            )
        )
        Task {
            try? await SortAssistantWorkstreamPersistence.shared.append(item)
        }
    }

    private func applyPendingPreview(
        tabManager: TabManager,
        workspaceTabStore: WorkspaceTabStore,
        partialLimit: Int?
    ) {
        rememberStores(tabManager: tabManager, workspaceTabStore: workspaceTabStore)
        guard let patch = pendingPreviewPatch else { return }
        do {
            let sortToSelect = pendingPreviewSort
            let itemSignals = contextProvider.itemSignals(
                tabManager: tabManager,
                workspaceTabStore: workspaceTabStore
            )
            let patchToApply: SortPatch
            if let partialLimit {
                let preview = try sortOperator.preview(
                    patch: patch,
                    tabs: tabManager.tabs,
                    itemSignals: itemSignals
                )
                let selectedIds = Array(preview.affectedItemIds.prefix(partialLimit))
                patchToApply = sortOperator.makeBatchPatch(
                    orderedIds: selectedIds,
                    tabs: tabManager.tabs,
                    rationale: String(localized: "sortAssistant.preview.partialRationale", defaultValue: "Apply the highest-impact moves from the assistant proposal."),
                    confidence: patch.confidence,
                    requiresConfirmation: false
                )
            } else {
                patchToApply = SortPatch(
                    id: patch.id,
                    listId: patch.listId,
                    baseRevision: SortEngine.revision(for: tabManager.tabs),
                    operations: patch.operations,
                    rationale: patch.rationale,
                    confidence: patch.confidence,
                    requiresConfirmation: false
                )
            }
            let result = try sortOperator.apply(
                patch: patchToApply,
                tabManager: tabManager,
                itemSignals: itemSignals,
                actor: partialLimit == nil ? "sort_assistant_preview_apply" : "sort_assistant_preview_partial_apply"
            )
            let previousResult = latestResult
            pendingPreviewPatch = nil
            pendingPreviewSort = nil
            if let sortToSelect {
                workspaceTabStore.setSort(sortToSelect)
            }
            let sortResult = SortAssistantSortResult(
                title: String(localized: "sortAssistant.result.title", defaultValue: "Sorted by \(previousResult?.dimensionLabel ?? Self.dimensionLabel(workspaceTabStore.selectedSort))"),
                goal: previousResult?.goal ?? patch.rationale ?? "",
                dimensionLabel: previousResult?.dimensionLabel ?? Self.dimensionLabel(workspaceTabStore.selectedSort),
                changes: result.preview.changes,
                rationale: result.preview.rationale,
                patchId: patchToApply.id,
                mode: .applied,
                canUndo: true,
                canApply: false,
                canApplyPartially: false,
                canIgnore: false,
                actions: Self.availableResultActions(previousResult?.actions ?? [], resultMode: .applied)
            )
            let anchorMessageId = append(.init(
                kind: .assistant,
                text: partialLimit == nil
                    ? String(localized: "sortAssistant.preview.applied", defaultValue: "Applied the sort proposal.")
                    : String(localized: "sortAssistant.preview.partialApplied", defaultValue: "Applied the highest-impact moves from the proposal.")
            ))
            setLatestResult(sortResult, anchorMessageId: anchorMessageId)
        } catch {
            append(.init(
                kind: .error,
                text: String(localized: "sortAssistant.preview.applyFailed", defaultValue: "Could not apply the preview: ") + Self.displayMessage(for: error)
            ))
        }
    }

    private func setLatestResult(
        _ result: SortAssistantSortResult,
        anchorMessageId: UUID? = nil
    ) {
        choicePrompt = nil
        latestResultAnchorMessageId = anchorMessageId ?? messages.last?.id
        latestResult = result
    }

    private func semanticConversationContext(
        limit: Int = 10,
        workspaceTarget: SortAssistantWorkspaceTarget? = nil
    ) -> [String] {
        var context = messages.suffix(limit).map { message in
            "\(Self.semanticRole(for: message.kind)): \(message.text)"
        }
        if let workspaceTarget {
            let directory = workspaceTarget.directory ?? "unknown"
            context.append("target_workspace: \(workspaceTarget.title) id=\(workspaceTarget.id.uuidString) directory=\(directory)")
        }
        return context
    }

    private static func semanticRole(for kind: SortAssistantMessage.Kind) -> String {
        switch kind {
        case .user:
            return "user"
        case .assistant:
            return "assistant"
        case .progress:
            return "assistant_status"
        case .error:
            return "assistant_error"
        }
    }

    @discardableResult
    private func append(_ message: SortAssistantMessage) -> UUID {
        messages.append(message)
        if messages.count > 40 {
            messages.removeFirst(messages.count - 40)
            if let anchorId = latestResultAnchorMessageId,
               !messages.contains(where: { $0.id == anchorId }) {
                latestResultAnchorMessageId = messages.first?.id
            }
        }
        return message.id
    }

    private func reloadFreeSortMemories() {
        memories = Self.loadLegacyMemories(from: memoryFileURL)
    }

    private func reloadSpriteMemories(directory: String?) {
        currentSpriteMemoryDirectory = directory
        currentSpriteMemoryFileURL = SpriteWorkspaceMemoryDocument.fileURL(directory: directory)
        let loaded = SpriteWorkspaceMemoryDocument.load(directory: directory)
        spriteMemories = loaded.memories
        spriteMemorySources = loaded.sources
    }

    private static func loadLegacyMemories(from fileURL: URL) -> [SortAssistantMemory] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let itemDecoder = JSONDecoder()
        itemDecoder.dateDecodingStrategy = .iso8601
        let eventDecoder = JSONDecoder()
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        var memoriesById: [UUID: SortAssistantMemory] = [:]
        for line in lines {
            let lineData = Data(line)
            guard let item = try? itemDecoder.decode(WorkstreamItem.self, from: lineData),
                  case .toolResult(let toolName, let resultJSON, false) = item.payload,
                  toolName == memoryToolName,
                  let eventData = resultJSON.data(using: .utf8),
                  let event = try? eventDecoder.decode(SortAssistantMemoryEvent.self, from: eventData),
                  event.schemaVersion == memorySchemaVersion,
                  let memoryId = UUID(uuidString: event.memoryId) else {
                continue
            }
            switch event.eventType {
            case .created:
                let createdAt = iso8601Formatter.date(from: event.createdAt) ?? item.createdAt
                memoriesById[memoryId] = SortAssistantMemory(
                    id: memoryId,
                    text: event.text,
                    createdAt: createdAt
                )
            }
        }
        return memoriesById.values.sorted { $0.createdAt > $1.createdAt }
    }

    private static func topChanges(
        before: [UUID],
        after: [UUID],
        titleById: [UUID: String]
    ) -> [String] {
        SortEngine.topChanges(before: before, after: after, titleById: titleById)
    }

    private static func topRationale(
        from state: WorkspaceSidebarSummaryPriorityState,
        sort: WorkspaceSidebarSummaryPrioritySort
    ) -> String? {
        let dimensionId = sort.dimensionId ?? "urgency"
        return nonEmpty(state.items.first?.scores.dimensions[dimensionId]?.reason)
            ?? nonEmpty(state.items.first?.scores.rankReason)
    }

    private static func topPresentation(
        from state: WorkspaceSidebarSummaryPriorityState,
        sort: WorkspaceSidebarSummaryPrioritySort
    ) -> SortAssistantResultPresentation {
        SortAssistantResultPresentation.parse(topRationale(from: state, sort: sort))
    }

    private static func allowedResultActions(for mode: SortAssistantRunMode) -> [SortAssistantResultAction] {
        switch mode {
        case .preview:
            return [.apply, .partialApply, .ignore, .explain]
        case .apply:
            return [.undo, .remember, .explain]
        }
    }

    private static func availableResultActions(
        _ actions: [SortAssistantResultAction],
        resultMode: SortAssistantResultMode
    ) -> [SortAssistantResultAction] {
        let allowed: Set<SortAssistantResultAction>
        switch resultMode {
        case .preview:
            allowed = [.apply, .partialApply, .ignore, .explain]
        case .applied:
            allowed = [.undo, .remember, .explain]
        }
        return actions.filter { allowed.contains($0) }
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func dimensionLabel(_ sort: WorkspaceSidebarSummaryPrioritySort) -> String {
        if sort.isRecent {
            return String(localized: "sortAssistant.dimension.recent", defaultValue: "Recent")
        }
        if sort.isNative {
            return String(localized: "sortAssistant.dimension.native", defaultValue: "Native")
        }
        switch sort.dimensionId ?? "urgency" {
        case "importance":
            return String(localized: "sortAssistant.dimension.importance", defaultValue: "Importance")
        case "progress":
            return String(localized: "sortAssistant.dimension.progress", defaultValue: "Progress")
        default:
            return String(localized: "sortAssistant.dimension.urgency", defaultValue: "Urgency")
        }
    }

    private static func displayMessage(for error: Error) -> String {
        if let socketError = error as? CmuxSocketError {
            return socketError.message
        }
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }
        return String(describing: error)
    }

    private func memoryText(from text: String) -> String {
        var output = text
        for marker in ["remember", "Remember", "from now on", "以后都", "以后", "记住", "下次"] {
            output = output.replacingOccurrences(of: marker, with: "")
        }
        return normalized(output).isEmpty ? text : normalized(output)
    }

    private func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func rememberStores(
        tabManager: TabManager,
        workspaceTabStore: WorkspaceTabStore
    ) {
        lastTabManager = tabManager
        lastWorkspaceTabStore = workspaceTabStore
        let directory = Self.workspaceDirectoryForMCP(tabManager: tabManager)
        if directory != currentSpriteMemoryDirectory {
            reloadSpriteMemories(directory: directory)
        }
    }

    func socketMemoryQuery() -> [String: Any] {
        reloadFreeSortMemories()
        return [
            "domain": "free_sort",
            "memories": SortAssistantPayload.array(memories),
        ]
    }

    func socketWriteMemoryCandidate(text: String, sourceSummary: String?) -> [String: Any] {
        let trimmed = normalized(text)
        guard !trimmed.isEmpty else { return ["created": false] }
        memoryCandidate = SortAssistantMemoryCandidate(text: trimmed, sourceSummary: sourceSummary, target: .freeSort)
        return [
            "domain": "free_sort",
            "created": true,
            "text": trimmed,
        ]
    }

    func socketForgetMemory(id: String?, text: String?) -> [String: Any] {
        reloadFreeSortMemories()
        let before = memories.count
        if let id, let uuid = UUID(uuidString: id), let memory = memories.first(where: { $0.id == uuid }) {
            deleteMemory(memory)
        } else if let text {
            let targets = memories.filter { $0.text.localizedCaseInsensitiveContains(text) }
            for memory in targets {
                deleteMemory(memory)
            }
        }
        return [
            "domain": "free_sort",
            "deleted": before - memories.count,
        ]
    }

    func socketSpriteMemoryQuery(directory: String?) -> [String: Any] {
        reloadSpriteMemories(directory: directory ?? currentSpriteMemoryDirectory)
        var payload: [String: Any] = [
            "domain": "sprite",
            "memories": SortAssistantPayload.array(spriteMemories),
            "memoryFile": currentSpriteMemoryFileURL.map { $0.path as Any } ?? NSNull(),
        ]
        if let fileURL = currentSpriteMemoryFileURL {
            payload["memoryFileExists"] = FileManager.default.fileExists(atPath: fileURL.path)
        }
        return payload
    }

    func socketWriteSpriteMemory(text: String, sourceSummary: String?, directory: String?) -> [String: Any] {
        if let directory {
            reloadSpriteMemories(directory: directory)
        } else if currentSpriteMemoryDirectory == nil, let lastTabManager {
            reloadSpriteMemories(directory: Self.workspaceDirectoryForMCP(tabManager: lastTabManager))
        }
        let trimmed = normalized(text)
        guard !trimmed.isEmpty else {
            return [
                "domain": "sprite",
                "created": false,
                "memoryFile": currentSpriteMemoryFileURL.map { $0.path as Any } ?? NSNull(),
            ]
        }

        let targetDirectory = directory
            ?? currentSpriteMemoryDirectory
            ?? lastTabManager.flatMap(Self.workspaceDirectoryForMCP)
        let memory = SortAssistantMemory(id: UUID(), text: trimmed, createdAt: Date())
        do {
            guard let fileURL = try SpriteWorkspaceMemoryDocument.append(memory, directory: targetDirectory) else {
                return [
                    "domain": "sprite",
                    "created": false,
                    "error": String(localized: "sortAssistant.spriteMemory.noWorkspaceDirectory", defaultValue: "No workspace directory is available for memory.md."),
                    "memoryFile": NSNull(),
                ]
            }
            currentSpriteMemoryDirectory = targetDirectory
            currentSpriteMemoryFileURL = fileURL
            spriteMemories.insert(memory, at: 0)
            spriteMemorySources[memory.id] = .workspace(fileURL)
            var payload: [String: Any] = [
                "domain": "sprite",
                "created": true,
                "memory": SortAssistantPayload.dictionary(memory),
                "text": trimmed,
                "memoryFile": fileURL.path,
            ]
            if let sourceSummary = sourceSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
               !sourceSummary.isEmpty {
                payload["sourceSummary"] = sourceSummary
            }
            return payload
        } catch {
            return [
                "domain": "sprite",
                "created": false,
                "error": Self.displayMessage(for: error),
                "memoryFile": currentSpriteMemoryFileURL.map { $0.path as Any } ?? NSNull(),
            ]
        }
    }

    func socketWriteSpriteMemoryCandidate(text: String, sourceSummary: String?, directory: String?) -> [String: Any] {
        socketWriteSpriteMemory(text: text, sourceSummary: sourceSummary, directory: directory)
    }

    func socketForgetSpriteMemory(id: String?, text: String?, directory: String?) -> [String: Any] {
        if let directory {
            reloadSpriteMemories(directory: directory)
        }
        let before = spriteMemories.count
        if let id, let uuid = UUID(uuidString: id), let memory = spriteMemories.first(where: { $0.id == uuid }) {
            deleteSpriteMemory(memory)
        } else if let text {
            let targets = spriteMemories.filter { $0.text.localizedCaseInsensitiveContains(text) }
            for memory in targets {
                deleteSpriteMemory(memory)
            }
        }
        return [
            "domain": "sprite",
            "deleted": before - spriteMemories.count,
            "memoryFile": currentSpriteMemoryFileURL.map { $0.path as Any } ?? NSNull(),
        ]
    }

    func socketListState() -> [String: Any]? {
        guard let tabManager = lastTabManager else { return nil }
        return [
            "listId": SortEngine.workspaceListId,
            "revision": SortEngine.revision(for: tabManager.tabs),
            "items": tabManager.tabs.map { tab in
                [
                    "id": tab.id.uuidString,
                    "title": tab.title,
                    "pinned": tab.isPinned,
                    "locked": sortEngine.lockedItemIds().contains(tab.id),
                ] as [String: Any]
            },
        ]
    }

    func socketGitHubContext(workspaceId: String?, includeAllWorkspaces: Bool) -> [String: Any]? {
        guard let tabManager = lastTabManager else { return nil }
        let selectedWorkspaceId = tabManager.selectedTabId
        let requestedWorkspaceId = workspaceId.flatMap(UUID.init(uuidString:))
        let workspaces: [Workspace]

        if includeAllWorkspaces {
            workspaces = tabManager.tabs
        } else if let requestedWorkspaceId,
                  let workspace = tabManager.tabs.first(where: { $0.id == requestedWorkspaceId }) {
            workspaces = [workspace]
        } else if let selectedWorkspace = tabManager.selectedWorkspace {
            workspaces = [selectedWorkspace]
        } else {
            workspaces = []
        }

        return [
            "selectedWorkspaceId": selectedWorkspaceId.map { $0.uuidString as Any } ?? NSNull(),
            "workspaceCount": tabManager.tabs.count,
            "workspaces": workspaces.map { workspace in
                Self.githubContextPayload(
                    for: workspace,
                    selectedWorkspaceId: selectedWorkspaceId
                )
            },
        ]
    }

    func socketSortContext(goal: String) -> [String: Any]? {
        guard let tabManager = lastTabManager,
              let workspaceTabStore = lastWorkspaceTabStore else {
            return nil
        }
        reloadFreeSortMemories()
        let context = contextProvider.context(
            userIntent: goal,
            tabManager: tabManager,
            workspaceTabStore: workspaceTabStore,
            memories: memories,
            lastAssistantProposal: pendingPreviewPatch?.operations.flatMap(\.itemIds)
        )
        return SortAssistantPayload.dictionary(context)
    }

    private static func githubContextPayload(
        for workspace: Workspace,
        selectedWorkspaceId: UUID?
    ) -> [String: Any] {
        let panelIds = Set(workspace.panelGitBranches.keys)
            .union(workspace.panelPullRequests.keys)
            .union(workspace.panelDirectories.keys)
        let panels = panelIds
            .sorted { $0.uuidString < $1.uuidString }
            .map { panelId -> [String: Any] in
                var payload: [String: Any] = [
                    "panelId": panelId.uuidString,
                ]
                if let directory = workspace.panelDirectories[panelId] {
                    payload["directory"] = directory
                }
                if let branch = workspace.panelGitBranches[panelId] {
                    payload["branch"] = branch.branch
                    payload["dirty"] = branch.isDirty
                }
                if let pullRequest = workspace.panelPullRequests[panelId] {
                    payload["pullRequest"] = pullRequestPayload(pullRequest)
                }
                return payload
            }

        return [
            "workspaceId": workspace.id.uuidString,
            "title": workspace.title,
            "selected": workspace.id == selectedWorkspaceId,
            "surfaceDirectory": workspace.surfaceTabBarDirectory.map { $0 as Any } ?? NSNull(),
            "panels": panels,
            "pullRequests": workspace.sidebarPullRequestsInDisplayOrder().map(pullRequestPayload),
        ]
    }

    private static func pullRequestPayload(_ pullRequest: SidebarPullRequestState) -> [String: Any] {
        [
            "number": pullRequest.number,
            "label": pullRequest.label,
            "url": pullRequest.url.absoluteString,
            "status": pullRequest.status.rawValue,
            "branch": pullRequest.branch.map { $0 as Any } ?? NSNull(),
            "stale": pullRequest.isStale,
        ]
    }

    func socketSortPreview(goal: String, itemIds: [UUID]?) -> [String: Any]? {
        guard let tabManager = lastTabManager,
              let workspaceTabStore = lastWorkspaceTabStore else {
            return nil
        }
        let orderedIds: [UUID]
        if let itemIds, !itemIds.isEmpty {
            orderedIds = itemIds
        } else if let summary = workspaceTabStore.summaryPriority {
            orderedIds = WorkspaceTabStore.orderedWorkspaceIds(
                from: summary,
                tabs: tabManager.tabs,
                sort: workspaceTabStore.selectedSort,
                recentWorkspaceIds: workspaceTabStore.recentWorkspaceIds
            )
        } else {
            orderedIds = tabManager.tabs.map(\.id)
        }
        let patch = sortOperator.makeBatchPatch(
            orderedIds: orderedIds,
            tabs: tabManager.tabs,
            rationale: normalized(goal).isEmpty ? nil : goal,
            requiresConfirmation: true
        )
        guard let preview = try? sortOperator.preview(
            patch: patch,
            tabs: tabManager.tabs,
            itemSignals: contextProvider.itemSignals(tabManager: tabManager, workspaceTabStore: workspaceTabStore)
        ) else {
            return nil
        }
        pendingPreviewPatch = patch
        pendingPreviewSort = workspaceTabStore.selectedSort
        return [
            "patch": SortAssistantPayload.dictionary(patch),
            "preview": Self.previewPayload(preview),
        ]
    }

    func socketSortApply(patchId: UUID?, itemIds: [UUID]?) -> [String: Any]? {
        guard let tabManager = lastTabManager,
              let workspaceTabStore = lastWorkspaceTabStore else {
            return nil
        }
        let patch: SortPatch
        if let pendingPreviewPatch,
           patchId == nil || pendingPreviewPatch.id == patchId {
            patch = SortPatch(
                id: pendingPreviewPatch.id,
                listId: pendingPreviewPatch.listId,
                baseRevision: SortEngine.revision(for: tabManager.tabs),
                operations: pendingPreviewPatch.operations,
                rationale: pendingPreviewPatch.rationale,
                confidence: pendingPreviewPatch.confidence,
                requiresConfirmation: false
            )
        } else if let itemIds, !itemIds.isEmpty {
            patch = sortOperator.makeBatchPatch(
                orderedIds: itemIds,
                tabs: tabManager.tabs,
                rationale: nil,
                requiresConfirmation: false
            )
        } else {
            return nil
        }
        guard let result = try? sortOperator.apply(
            patch: patch,
            tabManager: tabManager,
            itemSignals: contextProvider.itemSignals(tabManager: tabManager, workspaceTabStore: workspaceTabStore),
            actor: "sprite_tool_sort_apply"
        ) else {
            return nil
        }
        pendingPreviewPatch = nil
        pendingPreviewSort = nil
        return [
            "applied": true,
            "patchId": patch.id.uuidString,
            "preview": Self.previewPayload(result.preview),
            "undoPatch": SortAssistantPayload.dictionary(result.undoPatch),
        ]
    }

    func socketSortUndo() -> [String: Any]? {
        guard let tabManager = lastTabManager,
              let result = try? sortOperator.undo(tabManager: tabManager) else {
            return nil
        }
        return [
            "undone": true,
            "preview": Self.previewPayload(result.preview),
            "undoPatch": SortAssistantPayload.dictionary(result.undoPatch),
        ]
    }

    func socketSortExplain() -> [String: Any] {
        [
            "rationale": latestResult?.rationale ?? "",
            "changes": latestResult?.changes ?? [],
        ]
    }

    func socketSetLocked(itemId: UUID, locked: Bool) -> [String: Any] {
        sortEngine.setLocked(locked, itemId: itemId)
        return [
            "itemId": itemId.uuidString,
            "locked": locked,
        ]
    }

    func socketSetPinned(itemId: UUID, pinned: Bool) -> [String: Any]? {
        guard let tabManager = lastTabManager,
              let workspace = tabManager.tabs.first(where: { $0.id == itemId }) else {
            return nil
        }
        tabManager.setPinned(workspace, pinned: pinned)
        return [
            "itemId": itemId.uuidString,
            "pinned": pinned,
            "revision": SortEngine.revision(for: tabManager.tabs),
        ]
    }

    private static func previewPayload(_ preview: SortEnginePreview) -> [String: Any] {
        [
            "orderBefore": preview.orderBefore.map(\.uuidString),
            "orderAfter": preview.orderAfter.map(\.uuidString),
            "changes": preview.changes,
            "affectedItemIds": preview.affectedItemIds.map(\.uuidString),
            "rationale": preview.rationale ?? NSNull(),
            "requiresConfirmation": preview.requiresConfirmation,
        ]
    }
}
