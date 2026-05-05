import SwiftUI

enum SortPanelSettings {
    static let openKey = "sortPanel.open"
    static let lastGoalKey = "sortPanel.lastGoal"
    static let lastModeKey = "sortPanel.mode.lastSelected"

    static let cardWidth: CGFloat = 320
    static let cardMaxHeight: CGFloat = 560
    static let trafficLightInset: CGFloat = 28
}

enum SortPanelMode: String, CaseIterable, Identifiable {
    case quick
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .quick:
            return String(localized: "sortPanel.mode.quick", defaultValue: "Quick")
        case .custom:
            return String(localized: "sortPanel.mode.custom", defaultValue: "Custom")
        }
    }
}

struct SortPanelHostOverlay: View {
    @ObservedObject var workspaceTabStore: WorkspaceTabStore
    let sidebarVisible: Bool
    let sidebarWidth: CGFloat
    let topInset: CGFloat
    @Binding var isOpen: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Click-catcher only over the area to the right of the sidebar.
            // Clicks here close the panel. The rectangle does not cover the
            // sidebar so the user can still interact with sidebar items.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { isOpen = false }
                .padding(.leading, sidebarVisible ? sidebarWidth : 0)

            SortPanelCard(
                workspaceTabStore: workspaceTabStore,
                onClose: { isOpen = false }
            )
            .padding(.leading, sidebarVisible ? sidebarWidth : 0)
            .padding(.top, max(topInset, SortPanelSettings.trafficLightInset))
            .padding(.leading, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .move(edge: .leading)),
            removal: .opacity
        ))
    }
}

private struct SortPanelCard: View {
    @ObservedObject var workspaceTabStore: WorkspaceTabStore
    let onClose: () -> Void

    @AppStorage(SortPanelSettings.lastGoalKey)
    private var lastGoal: String = ""
    @AppStorage(SortPanelSettings.lastModeKey)
    private var lastModeRaw: String = SortPanelMode.quick.rawValue
    @State private var goalDraft: String = ""
    @Environment(\.colorScheme) private var colorScheme

    private var mode: Binding<SortPanelMode> {
        Binding(
            get: { SortPanelMode(rawValue: lastModeRaw) ?? .quick },
            set: { lastModeRaw = $0.rawValue }
        )
    }

    private var defaultGoal: String {
        String(
            localized: "sortPanel.goal.default",
            defaultValue: "Surface what is most worth advancing today"
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Picker("", selection: mode) {
                ForEach(SortPanelMode.allCases) { value in
                    Text(value.label).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Divider().opacity(0.4)

            switch mode.wrappedValue {
            case .quick:
                quickBody
            case .custom:
                customBody
            }
        }
        .padding(14)
        .frame(width: SortPanelSettings.cardWidth, alignment: .leading)
        .frame(maxHeight: SortPanelSettings.cardMaxHeight, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        )
        .shadow(
            color: Color.black.opacity(colorScheme == .dark ? 0.45 : 0.16),
            radius: 18,
            x: 0,
            y: 8
        )
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(String(localized: "sortPanel.title", defaultValue: "Sort"))
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.primary.opacity(0.07))
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help(String(localized: "sortPanel.close", defaultValue: "Close"))
        }
    }

    // MARK: Quick mode

    private var quickBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "sortPanel.goal.heading", defaultValue: "Goal"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField(
                String(
                    localized: "sortPanel.goal.placeholder",
                    defaultValue: "Describe what to prioritize…"
                ),
                text: $goalDraft,
                axis: .vertical
            )
            .lineLimit(1...3)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12))
            .onAppear {
                goalDraft = lastGoal.isEmpty ? defaultGoal : lastGoal
            }

            FlowChips(
                items: SortPanelChip.allCases,
                onTap: { chip in goalDraft = chip.text }
            )

            Text(String(localized: "sortPanel.preview.heading", defaultValue: "Preview"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            previewList

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button(action: applyQuick) {
                    Text(String(localized: "sortPanel.apply", defaultValue: "Apply Sort"))
                        .font(.system(size: 12, weight: .semibold))
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(trimmedGoal.isEmpty)
            }
        }
    }

    private var trimmedGoal: String {
        goalDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func applyQuick() {
        let goal = trimmedGoal
        guard !goal.isEmpty else { return }
        lastGoal = goal
        workspaceTabStore.setSort(.goalDriven(goal: goal))
        onClose()
    }

    @ViewBuilder
    private var previewList: some View {
        let items = previewItems
        if items.isEmpty {
            Text(String(localized: "sortPanel.preview.empty", defaultValue: "No workspaces to rank yet."))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    HStack(spacing: 8) {
                        Text("\(index + 1).")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, alignment: .trailing)
                        Text(item.title)
                            .font(.system(size: 12))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(scoreLabel(for: item))
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var previewItems: [WorkspaceSidebarSummaryPriorityItem] {
        guard let items = workspaceTabStore.summaryPriority?.items else { return [] }
        let ranked = items.sorted { lhs, rhs in
            let l = lhs.scores.dimensions.values.map(\.rawScore).max() ?? 0
            let r = rhs.scores.dimensions.values.map(\.rawScore).max() ?? 0
            if l != r { return l > r }
            return lhs.nativeOrder < rhs.nativeOrder
        }
        return Array(ranked.prefix(3))
    }

    private func scoreLabel(for item: WorkspaceSidebarSummaryPriorityItem) -> String {
        let score = item.scores.dimensions.values.map(\.rawScore).max() ?? 0
        return String(format: "%d", Int((score * 100).rounded()))
    }

    // MARK: Custom mode

    private var customBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "sortPanel.custom.heading", defaultValue: "Sort by dimension"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            SummaryPriorityToolbar(
                sort: workspaceTabStore.selectedSort,
                dimensions: workspaceTabStore.summaryPriority?.dimensions
                    ?? WorkspaceSidebarDimensionDefinition.builtinDefaults,
                isLoading: workspaceTabStore.isLoading,
                onSort: { sort in workspaceTabStore.setSort(sort) },
                onRefresh: {
                    workspaceTabStore.refreshSummaryPriority(
                        force: true,
                        sort: workspaceTabStore.selectedSort
                    )
                }
            )

            Text(String(
                localized: "sortPanel.custom.help",
                defaultValue: "Choose a dimension. Sorting applies live."
            ))
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)

            Spacer(minLength: 0)
        }
    }
}

private enum SortPanelChip: String, CaseIterable, Identifiable {
    case today
    case release
    case blocked

    var id: String { rawValue }

    var text: String {
        switch self {
        case .today:
            return String(
                localized: "sortPanel.goal.suggestion.today",
                defaultValue: "Surface what is most worth advancing today"
            )
        case .release:
            return String(
                localized: "sortPanel.goal.suggestion.release",
                defaultValue: "Prioritize anything blocking the next release"
            )
        case .blocked:
            return String(
                localized: "sortPanel.goal.suggestion.blocked",
                defaultValue: "Surface workspaces that are stuck or blocked"
            )
        }
    }

    var label: String {
        switch self {
        case .today:
            return String(localized: "sortPanel.goal.chip.today", defaultValue: "Today first")
        case .release:
            return String(localized: "sortPanel.goal.chip.release", defaultValue: "Release first")
        case .blocked:
            return String(localized: "sortPanel.goal.chip.blocked", defaultValue: "Blocked first")
        }
    }
}

private struct FlowChips: View {
    let items: [SortPanelChip]
    let onTap: (SortPanelChip) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(items) { chip in
                Button {
                    onTap(chip)
                } label: {
                    Text(chip.label)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(0.07))
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }
}
