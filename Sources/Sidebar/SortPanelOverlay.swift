import SwiftUI

enum SortPanelSettings {
    static let lastGoalKey = "sortPanel.lastGoal"
    static let lastModeKey = "sortPanel.mode.lastSelected"
    static let inlineExpandedKey = "extensionColumn.sortInline.expanded"
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

struct ExtensionColumnSortInlinePanel: View {
    @ObservedObject var workspaceTabStore: WorkspaceTabStore
    @Binding var isExpanded: Bool

    @AppStorage(SortPanelSettings.lastGoalKey)
    private var lastGoal: String = ""
    @AppStorage(SortPanelSettings.lastModeKey)
    private var lastModeRaw: String = SortPanelMode.quick.rawValue
    @State private var goalDraft: String = ""

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
        VStack(alignment: .leading, spacing: 10) {
            dimensionQuickRow

            Picker("", selection: mode) {
                ForEach(SortPanelMode.allCases) { value in
                    Text(value.label).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)

            switch mode.wrappedValue {
            case .quick:
                quickBody
            case .custom:
                customBody
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        )
        .onAppear {
            if goalDraft.isEmpty {
                goalDraft = lastGoal.isEmpty ? defaultGoal : lastGoal
            }
        }
    }

    // MARK: Quick dimension chips

    private var availableDimensions: [WorkspaceSidebarDimensionDefinition] {
        let dims = workspaceTabStore.summaryPriority?.dimensions
            ?? WorkspaceSidebarDimensionDefinition.builtinDefaults
        let visible = dims.filter { $0.enabled && $0.visible }
        return visible.isEmpty ? WorkspaceSidebarDimensionDefinition.builtinDefaults : visible
    }

    private var activeDimensionId: String? {
        let sort = workspaceTabStore.selectedSort
        return sort.mode == "dimension" ? sort.dimensionId : nil
    }

    private var dimensionQuickRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(
                localized: "sortPanel.dimensions.heading",
                defaultValue: "Sort by dimension"
            ))
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(availableDimensions, id: \.id) { dim in
                        dimensionChip(for: dim)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func dimensionChip(for dim: WorkspaceSidebarDimensionDefinition) -> some View {
        let info = ExtensionColumnDimensions.info(for: dim.id, fallbackLabel: dim.label)
        let isActive = activeDimensionId == dim.id
        Button {
            applyDimension(id: dim.id)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: info.glyph)
                    .font(.system(size: 9, weight: .semibold))
                Text(info.label)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundColor(isActive ? Color.accentColor : .primary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(isActive ? 0.14 : 0.07))
            )
        }
        .buttonStyle(.plain)
    }

    private func applyDimension(id: String) {
        workspaceTabStore.setSort(
            WorkspaceSidebarSummaryPrioritySort(
                mode: "dimension",
                dimensionId: id,
                direction: "desc"
            )
        )
        isExpanded = false
    }

    // MARK: Quick mode

    private var quickBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "sortPanel.goal.heading", defaultValue: "Goal"))
                .font(.system(size: 10, weight: .semibold))
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
            .font(.system(size: 11))

            chipRow

            Text(String(localized: "sortPanel.preview.heading", defaultValue: "Preview"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            previewList

            HStack {
                Spacer()
                Button(action: applyQuick) {
                    Text(String(localized: "sortPanel.apply", defaultValue: "Apply Sort"))
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(trimmedGoal.isEmpty)
            }
        }
    }

    private var chipRow: some View {
        HStack(spacing: 5) {
            ForEach(SortPanelChip.allCases) { chip in
                Button {
                    goalDraft = chip.text
                } label: {
                    Text(chip.label)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.primary.opacity(0.07))
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
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
        isExpanded = false
    }

    @ViewBuilder
    private var previewList: some View {
        let items = previewItems
        if items.isEmpty {
            Text(String(localized: "sortPanel.preview.empty", defaultValue: "No workspaces to rank yet."))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    HStack(spacing: 6) {
                        Text("\(index + 1).")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .frame(width: 14, alignment: .trailing)
                        Text(item.title)
                            .font(.system(size: 11))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(scoreLabel(for: item))
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
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
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "sortPanel.custom.heading", defaultValue: "Sort by dimension"))
                .font(.system(size: 10, weight: .semibold))
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
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
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
