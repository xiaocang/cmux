import SwiftUI

struct ExtensionColumnSortQuickPopover: View {
    private static let lastGoalKey = "sortPanel.lastGoal"

    @ObservedObject var workspaceTabStore: WorkspaceTabStore
    let onClose: () -> Void

    @AppStorage(Self.lastGoalKey)
    private var lastGoal: String = ""
    @State private var goalDraft: String = ""
    @State private var nameDraft: String = ""
    @State private var isSavingMode: Bool = false
    @FocusState private var goalFocused: Bool
    @FocusState private var nameFocused: Bool

    private var defaultGoal: String {
        String(
            localized: "sortPanel.goal.default",
            defaultValue: "Surface what is most worth advancing today"
        )
    }

    private var trimmedGoal: String {
        goalDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedName: String {
        nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
            .lineLimit(4...10)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11))
            .focused($goalFocused)

            chipRow

            actionRow
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .frame(width: 280)
        .onAppear {
            if goalDraft.isEmpty {
                goalDraft = lastGoal.isEmpty ? defaultGoal : lastGoal
            }
            goalFocused = !isSavingMode
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

    @ViewBuilder
    private var actionRow: some View {
        if isSavingMode {
            saveNameRow
        } else {
            saveAndApplyRow
        }
    }

    private var saveAndApplyRow: some View {
        HStack {
            Spacer()
            Button {
                nameDraft = ""
                isSavingMode = true
                nameFocused = true
            } label: {
                Text(String(localized: "extensionColumn.sort.quick.save", defaultValue: "Save…"))
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(trimmedGoal.isEmpty)

            Button(action: applyQuick) {
                Text(String(localized: "sortPanel.apply", defaultValue: "Apply Sort"))
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(trimmedGoal.isEmpty)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var saveNameRow: some View {
        HStack(spacing: 6) {
            TextField(
                String(
                    localized: "extensionColumn.sort.quick.save.namePlaceholder",
                    defaultValue: "Name this sort"
                ),
                text: $nameDraft
            )
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11))
            .focused($nameFocused)
            .onSubmit(confirmSave)

            Button(action: confirmSave) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(trimmedName.isEmpty || trimmedGoal.isEmpty)
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel(String(
                localized: "extensionColumn.sort.quick.save.confirm",
                defaultValue: "Save"
            ))

            Button {
                isSavingMode = false
                nameDraft = ""
                goalFocused = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel(String(
                localized: "extensionColumn.sort.quick.save.cancel",
                defaultValue: "Cancel"
            ))
        }
    }

    private func applyQuick() {
        let goal = trimmedGoal
        guard !goal.isEmpty else { return }
        lastGoal = goal
        workspaceTabStore.setSort(.goalDriven(goal: goal))
        onClose()
    }

    private func confirmSave() {
        let name = trimmedName
        let goal = trimmedGoal
        guard !name.isEmpty, !goal.isEmpty else { return }
        lastGoal = goal
        workspaceTabStore.addSavedSort(name: name, goal: goal)
        workspaceTabStore.setSort(.goalDriven(goal: goal))
        onClose()
    }
}

enum SortPanelChip: String, CaseIterable, Identifiable {
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
