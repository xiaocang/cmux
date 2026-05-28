#if DEBUG
import AppKit
import CMUXActions
import SwiftUI

struct ContextAgentInspectorSnapshot: Equatable, Sendable {
    var capturedAt: Date
    var workingContext: AssistantWorkingContext
    var agentDiagnostics: ContextAgentDiagnosticsSnapshot?
    var auditEntries: [SemanticActionAuditEntry]
}

final class ContextAgentInspectorWindowController: NSWindowController, NSWindowDelegate {
    static let shared = ContextAgentInspectorWindowController()

    private init() {
        let model = ContextAgentInspectorModel()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(
            localized: "debug.contextAgentInspector.windowTitle",
            defaultValue: "Context Agent Inspector"
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.contextAgentInspector")
        window.center()
        window.contentView = NSHostingView(rootView: ContextAgentInspectorView(model: model))
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

@MainActor
private final class ContextAgentInspectorModel: ObservableObject {
    @Published var snapshot: ContextAgentInspectorSnapshot?

    func refresh() {
        Task { @MainActor in
            snapshot = await SortAssistantCoordinator.shared.debugContextAgentInspectorSnapshot()
        }
    }
}

private struct ContextAgentInspectorView: View {
    @ObservedObject var model: ContextAgentInspectorModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let snapshot = model.snapshot {
                    summary(snapshot)
                    snapshotTable(snapshot.workingContext.snapshots)
                    providerFreshnessTable(snapshot.workingContext.snapshots)
                    runtimeDiagnostics(
                        snapshot.agentDiagnostics,
                        snapshots: snapshot.workingContext.snapshots
                    )
                    suggestionAndRanking(snapshot.workingContext)
                    auditTable(snapshot.auditEntries)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "waveform.path.ecg")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary)
                        Text(String(localized: "debug.contextAgentInspector.emptyTitle", defaultValue: "No context snapshot loaded"))
                            .font(.system(size: 14, weight: .semibold))
                        Text(String(localized: "debug.contextAgentInspector.emptyDescription", defaultValue: "Refresh to read the assistant context store."))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 360)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 760, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("ContextAgentInspector")
        .onAppear { model.refresh() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "debug.contextAgentInspector.title", defaultValue: "Context Agent Inspector"))
                    .font(.system(size: 18, weight: .semibold))
                Text(String(
                    localized: "debug.contextAgentInspector.subtitle",
                    defaultValue: "Runtime view of assistant snapshots, provider freshness, suggestions, ranking, and action review."
                ))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button(String(localized: "debug.contextAgentInspector.refresh", defaultValue: "Refresh")) {
                model.refresh()
            }
        }
    }

    private func summary(_ snapshot: ContextAgentInspectorSnapshot) -> some View {
        let context = snapshot.workingContext
        return HStack(spacing: 10) {
            metricCard(
                String(localized: "debug.contextAgentInspector.snapshots", defaultValue: "Snapshots"),
                "\(context.snapshots.count)"
            )
            metricCard(
                String(localized: "debug.contextAgentInspector.suggestions", defaultValue: "Suggestions"),
                "\(context.activeSuggestions.count)"
            )
            metricCard(
                String(localized: "debug.contextAgentInspector.ranking", defaultValue: "Ranking"),
                context.latestRanking == nil
                    ? String(localized: "debug.contextAgentInspector.none", defaultValue: "None")
                    : "\(context.latestRanking?.items.count ?? 0)"
            )
            metricCard(
                String(localized: "debug.contextAgentInspector.confidence", defaultValue: "Confidence"),
                String(format: "%.0f%%", context.freshness.overallConfidence * 100)
            )
            metricCard(
                String(localized: "debug.contextAgentInspector.audit", defaultValue: "Audit"),
                "\(snapshot.auditEntries.count)"
            )
            if let diagnostics = snapshot.agentDiagnostics {
                metricCard(
                    String(localized: "debug.contextAgentInspector.pending", defaultValue: "Pending"),
                    "\(diagnostics.scheduler.pendingJobs.count)"
                )
                metricCard(
                    String(localized: "debug.contextAgentInspector.providerRuns", defaultValue: "Provider Runs"),
                    "\(diagnostics.providerRuns.count)"
                )
            }
        }
    }

    private func metricCard(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 20, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }

    private func snapshotTable(_ snapshots: [WorkspaceSnapshot]) -> some View {
        section(String(localized: "debug.contextAgentInspector.snapshotVersions", defaultValue: "Snapshot Versions")) {
            rows(
                columns: [
                    String(localized: "debug.contextAgentInspector.workspace", defaultValue: "Workspace"),
                    String(localized: "debug.contextAgentInspector.status", defaultValue: "Status"),
                    String(localized: "debug.contextAgentInspector.version", defaultValue: "Version"),
                    String(localized: "debug.contextAgentInspector.updated", defaultValue: "Updated"),
                ],
                values: snapshots.map { snapshot in
                    [
                        snapshot.context.title,
                        snapshot.derived.status,
                        "\(snapshot.version)",
                        Self.shortTime(snapshot.updatedAt),
                    ]
                }
            )
        }
    }

    private func runtimeDiagnostics(
        _ diagnostics: ContextAgentDiagnosticsSnapshot?,
        snapshots: [WorkspaceSnapshot]
    ) -> some View {
        section(String(localized: "debug.contextAgentInspector.runtimeDiagnostics", defaultValue: "Runtime Diagnostics")) {
            if let diagnostics {
                VStack(alignment: .leading, spacing: 14) {
                    providerIdsTable(diagnostics.providerIds)
                    leaseTable(diagnostics.scheduler.workspaceLeases, snapshots: snapshots)
                    pendingJobsTable(diagnostics.scheduler.pendingJobs, snapshots: snapshots)
                    providerCollectionsTable(diagnostics.scheduler.providerCollections, snapshots: snapshots)
                    providerRunsTable(diagnostics.providerRuns, snapshots: snapshots)
                }
            } else {
                Text(String(
                    localized: "debug.contextAgentInspector.noRuntimeDiagnostics",
                    defaultValue: "No live ContextAgent diagnostics are attached."
                ))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                .padding(.horizontal, 10)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func providerIdsTable(_ providerIds: [String]) -> some View {
        rows(
            columns: [
                String(localized: "debug.contextAgentInspector.provider", defaultValue: "Provider"),
            ],
            values: providerIds.map { [$0] }
        )
    }

    private func leaseTable(
        _ leases: [ContextWorkspaceLeaseDiagnostic],
        snapshots: [WorkspaceSnapshot]
    ) -> some View {
        rows(
            columns: [
                String(localized: "debug.contextAgentInspector.workspace", defaultValue: "Workspace"),
                String(localized: "debug.contextAgentInspector.lease", defaultValue: "Lease"),
            ],
            values: leases.map { lease in
                [
                    workspaceTitle(lease.workspaceId, snapshots: snapshots),
                    leaseLabel(lease.lease),
                ]
            }
        )
    }

    private func pendingJobsTable(
        _ jobs: [ContextRefreshJob],
        snapshots: [WorkspaceSnapshot]
    ) -> some View {
        rows(
            columns: [
                String(localized: "debug.contextAgentInspector.workspace", defaultValue: "Workspace"),
                String(localized: "debug.contextAgentInspector.provider", defaultValue: "Provider"),
                String(localized: "debug.contextAgentInspector.priority", defaultValue: "Priority"),
                String(localized: "debug.contextAgentInspector.reason", defaultValue: "Reason"),
                String(localized: "debug.contextAgentInspector.enqueued", defaultValue: "Enqueued"),
            ],
            values: jobs.map { job in
                [
                    workspaceTitle(job.workspaceId, snapshots: snapshots),
                    job.providerId ?? String(localized: "debug.contextAgentInspector.allProviders", defaultValue: "All providers"),
                    priorityLabel(job.priority),
                    job.reason,
                    Self.shortTime(job.enqueuedAt),
                ]
            }
        )
    }

    private func providerCollectionsTable(
        _ collections: [ContextProviderCollectionDiagnostic],
        snapshots: [WorkspaceSnapshot]
    ) -> some View {
        rows(
            columns: [
                String(localized: "debug.contextAgentInspector.workspace", defaultValue: "Workspace"),
                String(localized: "debug.contextAgentInspector.provider", defaultValue: "Provider"),
                String(localized: "debug.contextAgentInspector.collected", defaultValue: "Collected"),
                String(localized: "debug.contextAgentInspector.signaled", defaultValue: "Signaled"),
            ],
            values: collections.map { collection in
                [
                    workspaceTitle(collection.workspaceId, snapshots: snapshots),
                    collection.providerId,
                    Self.shortTime(collection.lastCollectedAt),
                    Self.shortTime(collection.lastSignaledAt),
                ]
            }
        )
    }

    private func providerRunsTable(
        _ records: [ProviderRunRecord],
        snapshots: [WorkspaceSnapshot]
    ) -> some View {
        rows(
            columns: [
                String(localized: "debug.contextAgentInspector.workspace", defaultValue: "Workspace"),
                String(localized: "debug.contextAgentInspector.provider", defaultValue: "Provider"),
                String(localized: "debug.contextAgentInspector.state", defaultValue: "State"),
                String(localized: "debug.contextAgentInspector.version", defaultValue: "Version"),
                String(localized: "debug.contextAgentInspector.finished", defaultValue: "Finished"),
                String(localized: "debug.contextAgentInspector.error", defaultValue: "Error"),
            ],
            values: records.suffix(12).reversed().map { record in
                [
                    workspaceTitle(record.workspaceId, snapshots: snapshots),
                    record.providerId,
                    record.success
                        ? String(localized: "debug.contextAgentInspector.ok", defaultValue: "OK")
                        : String(localized: "debug.contextAgentInspector.failed", defaultValue: "Failed"),
                    record.snapshotVersion.map(String.init)
                        ?? String(localized: "debug.contextAgentInspector.none", defaultValue: "None"),
                    Self.shortTime(record.finishedAt),
                    record.errorMessage ?? String(localized: "debug.contextAgentInspector.noError", defaultValue: "No error"),
                ]
            }
        )
    }

    private func providerFreshnessTable(_ snapshots: [WorkspaceSnapshot]) -> some View {
        let values = snapshots.flatMap { snapshot in
            snapshot.freshness.providers.map { provider in
                [
                    snapshot.context.title,
                    provider.providerId,
                    provider.stale
                        ? String(localized: "debug.contextAgentInspector.stale", defaultValue: "Stale")
                        : String(localized: "debug.contextAgentInspector.fresh", defaultValue: "Fresh"),
                    provider.error ?? String(localized: "debug.contextAgentInspector.noError", defaultValue: "No error"),
                ]
            }
        }
        return section(String(localized: "debug.contextAgentInspector.providerFreshness", defaultValue: "Provider Freshness")) {
            rows(
                columns: [
                    String(localized: "debug.contextAgentInspector.workspace", defaultValue: "Workspace"),
                    String(localized: "debug.contextAgentInspector.provider", defaultValue: "Provider"),
                    String(localized: "debug.contextAgentInspector.state", defaultValue: "State"),
                    String(localized: "debug.contextAgentInspector.error", defaultValue: "Error"),
                ],
                values: values
            )
        }
    }

    private func suggestionAndRanking(_ context: AssistantWorkingContext) -> some View {
        HStack(alignment: .top, spacing: 14) {
            section(String(localized: "debug.contextAgentInspector.activeSuggestions", defaultValue: "Active Suggestions")) {
                rows(
                    columns: [
                        String(localized: "debug.contextAgentInspector.type", defaultValue: "Type"),
                        String(localized: "debug.contextAgentInspector.workspace", defaultValue: "Workspace"),
                        String(localized: "debug.contextAgentInspector.confidence", defaultValue: "Confidence"),
                    ],
                    values: context.activeSuggestions.map { suggestion in
                        [
                            suggestion.type,
                            workspaceTitle(suggestion.workspaceId, snapshots: context.snapshots),
                            String(format: "%.0f%%", suggestion.confidence * 100),
                        ]
                    }
                )
            }
            section(String(localized: "debug.contextAgentInspector.latestRanking", defaultValue: "Latest Ranking")) {
                rows(
                    columns: [
                        String(localized: "debug.contextAgentInspector.rank", defaultValue: "Rank"),
                        String(localized: "debug.contextAgentInspector.workspace", defaultValue: "Workspace"),
                        String(localized: "debug.contextAgentInspector.score", defaultValue: "Score"),
                    ],
                    values: (context.latestRanking?.items ?? []).map { item in
                        [
                            "\(item.rank)",
                            workspaceTitle(item.workspaceId, snapshots: context.snapshots),
                            item.score.map { String(format: "%.0f", $0) }
                                ?? String(localized: "debug.contextAgentInspector.none", defaultValue: "None"),
                        ]
                    }
                )
            }
        }
    }

    private func auditTable(_ entries: [SemanticActionAuditEntry]) -> some View {
        section(String(localized: "debug.contextAgentInspector.actionReview", defaultValue: "Action Review")) {
            rows(
                columns: [
                    String(localized: "debug.contextAgentInspector.action", defaultValue: "Action"),
                    String(localized: "debug.contextAgentInspector.decision", defaultValue: "Decision"),
                    String(localized: "debug.contextAgentInspector.executed", defaultValue: "Executed"),
                    String(localized: "debug.contextAgentInspector.reason", defaultValue: "Reason"),
                ],
                values: entries.suffix(12).reversed().map { entry in
                    [
                        entry.kind.rawValue,
                        entry.decision.rawValue,
                        entry.executed
                            ? String(localized: "debug.contextAgentInspector.yes", defaultValue: "Yes")
                            : String(localized: "debug.contextAgentInspector.no", defaultValue: "No"),
                        entry.reasons.joined(separator: ", "),
                    ]
                }
            )
        }
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            content()
        }
    }

    private func rows(columns: [String], values: [[String]]) -> some View {
        VStack(spacing: 0) {
            ContextAgentInspectorRow(values: columns, isHeader: true)
            if values.isEmpty {
                Text(String(localized: "debug.contextAgentInspector.noRows", defaultValue: "No rows"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .background(Color(nsColor: .controlBackgroundColor))
            } else {
                ForEach(Array(values.enumerated()), id: \.offset) { _, row in
                    ContextAgentInspectorRow(values: row, isHeader: false)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
    }

    private func workspaceTitle(_ id: UUID, snapshots: [WorkspaceSnapshot]) -> String {
        snapshots.first { $0.workspaceId == id }?.context.title
            ?? String(id.uuidString.prefix(8))
    }

    private func priorityLabel(_ priority: ContextRefreshPriority) -> String {
        switch priority {
        case .background:
            return String(localized: "debug.contextAgentInspector.priorityBackground", defaultValue: "Background")
        case .visible:
            return String(localized: "debug.contextAgentInspector.priorityVisible", defaultValue: "Visible")
        case .userInitiated:
            return String(localized: "debug.contextAgentInspector.priorityUserInitiated", defaultValue: "User initiated")
        }
    }

    private func leaseLabel(_ lease: ContextAttentionLease) -> String {
        switch lease {
        case .cold:
            return String(localized: "debug.contextAgentInspector.leaseCold", defaultValue: "Cold")
        case .visible:
            return String(localized: "debug.contextAgentInspector.leaseVisible", defaultValue: "Warm / visible")
        case .hot:
            return String(localized: "debug.contextAgentInspector.leaseHot", defaultValue: "Hot")
        }
    }

    private static func shortTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }

    private static func shortTime(_ date: Date?) -> String {
        guard let date else {
            return String(localized: "debug.contextAgentInspector.never", defaultValue: "Never")
        }
        return shortTime(date)
    }
}

private struct ContextAgentInspectorRow: View {
    var values: [String]
    var isHeader: Bool

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                Text(value.isEmpty ? " " : value)
                    .font(.system(size: 11, weight: isHeader ? .semibold : .regular, design: .monospaced))
                    .foregroundStyle(isHeader ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                    .overlay(alignment: .trailing) {
                        Color(nsColor: .separatorColor)
                            .frame(width: 1)
                    }
            }
        }
        .background(isHeader ? Color(nsColor: .textBackgroundColor) : Color(nsColor: .controlBackgroundColor))
    }
}
#endif
