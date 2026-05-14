import AppKit
import Bonsplit
import CMUXWorkstream
import SwiftUI

private func rightSidebarDebugResponder(_ responder: NSResponder?) -> String {
    guard let responder else { return "nil" }
    return String(describing: type(of: responder))
}

/// Mode shown in the right sidebar (the panel toggled by ⌘⌥B).
nonisolated enum RightSidebarMode: String, CaseIterable, Codable, Sendable {
    case files
    case find
    case sessions
    case feed
    case dock

    var label: String {
        switch self {
        case .files: return String(localized: "rightSidebar.mode.files", defaultValue: "Files")
        case .find: return String(localized: "rightSidebar.mode.find", defaultValue: "Find")
        case .sessions: return String(localized: "rightSidebar.mode.sessions", defaultValue: "Vault")
        case .feed: return String(localized: "rightSidebar.mode.feed", defaultValue: "Feed")
        case .dock: return String(localized: "rightSidebar.mode.dock", defaultValue: "Dock")
        }
    }

    var symbolName: String {
        switch self {
        case .files: return "folder"
        case .find: return "magnifyingglass"
        case .sessions: return "books.vertical"
        case .feed: return "dot.radiowaves.left.and.right"
        case .dock: return "dock.rectangle"
        }
    }

    var shortcutAction: KeyboardShortcutSettings.Action {
        switch self {
        case .files: return .switchRightSidebarToFiles
        case .find: return .switchRightSidebarToFind
        case .sessions: return .switchRightSidebarToSessions
        case .feed: return .switchRightSidebarToFeed
        case .dock: return .switchRightSidebarToDock
        }
    }
}

extension RightSidebarMode {
    static let paneModes: [RightSidebarMode] = [.files, .find, .sessions]

    var canOpenAsPane: Bool {
        Self.paneModes.contains(self)
    }
}

extension RightSidebarMode {
    static func modeShortcut(for event: NSEvent) -> RightSidebarMode? {
        guard event.type == .keyDown else { return nil }
        if KeyboardShortcutSettings.shortcut(for: .switchRightSidebarToFiles).matches(event: event) {
            return .files
        }
        if KeyboardShortcutSettings.shortcut(for: .switchRightSidebarToFind).matches(event: event) {
            return .find
        }
        if KeyboardShortcutSettings.shortcut(for: .switchRightSidebarToSessions).matches(event: event) {
            return .sessions
        }
        if KeyboardShortcutSettings.shortcut(for: .switchRightSidebarToFeed).matches(event: event),
           RightSidebarMode.feed.isAvailable() {
            return .feed
        }
        if KeyboardShortcutSettings.shortcut(for: .switchRightSidebarToDock).matches(event: event),
           RightSidebarMode.dock.isAvailable() {
            return .dock
        }
        return nil
    }
}

enum RightSidebarKeyboardNavigation {
    enum DisclosureAction {
        case collapse
        case expand
    }

    static func moveDelta(for event: NSEvent) -> Int? {
        guard event.type == .keyDown else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasCommandOrOption = !flags.intersection([.command, .option]).isEmpty
        if flags.contains(.control), !hasCommandOrOption {
            switch event.keyCode {
            case 45: return 1   // Ctrl+N
            case 35: return -1  // Ctrl+P
            default: break
            }
        }

        guard flags.intersection([.command, .control, .option]).isEmpty else {
            return nil
        }
        switch event.keyCode {
        case 38, 125: return 1   // J or Down
        case 40, 126: return -1  // K or Up
        default: return nil
        }
    }

    static func disclosureAction(for event: NSEvent) -> DisclosureAction? {
        guard event.type == .keyDown else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.intersection([.command, .control, .option]).isEmpty else {
            return nil
        }
        switch event.keyCode {
        case 4: return .collapse  // H
        case 37: return .expand   // L
        case 123: return .collapse  // Left
        case 124: return .expand   // Right
        default: return nil
        }
    }

    static func isPlainSlash(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.intersection([.command, .control, .option]).isEmpty else {
            return false
        }
        return event.keyCode == 44
    }

    static func isPlainPrintableText(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.intersection([.command, .control, .option]).isEmpty else {
            return false
        }
        guard let text = event.charactersIgnoringModifiers, !text.isEmpty else {
            return false
        }
        return text.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0)
        }
    }
}

/// Right sidebar root view. Hosts a segmented mode picker plus the active panel.
struct RightSidebarPanelView: View {
    @ObservedObject var fileExplorerStore: FileExplorerStore
    @ObservedObject var fileExplorerState: FileExplorerState
    @ObservedObject var sessionIndexStore: SessionIndexStore
    @ObservedObject var tabManager: TabManager
    @ObservedObject var workspaceTabStore: WorkspaceTabStore
    let titlebarHeight: CGFloat
    let workspaceId: UUID?
    let onResumeSession: ((SessionEntry) -> Void)?
    let onOpenFilePreview: (String) -> Void
    let onOpenAsPane: (RightSidebarMode) -> Void
    let onClose: () -> Void

    @State private var modeShortcutHintMonitor = WindowScopedShortcutHintModifierMonitor(activation: .commandOrControl) { window in
        guard let responder = window.firstResponder else { return false }
        return AppDelegate.shared?.isRightSidebarFocusResponder(responder, in: window) == true
    }
    @State private var focusShortcutHintMonitor = WindowScopedShortcutHintModifierMonitor(activation: .commandOnly)
    @State private var closeShortcutHintMonitor = WindowScopedShortcutHintModifierMonitor(activation: .commandOnly)
    @StateObject private var dockStore = DockControlsStore()
    @ObservedObject private var keyboardShortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared
    private let alwaysShowShortcutHints = ShortcutHintDebugSettings.alwaysShowHints()
    private let closeShortcutHintXOffset = ShortcutHintDebugSettings.defaultRightSidebarCloseHintX
    private let closeShortcutHintYOffset = ShortcutHintDebugSettings.defaultRightSidebarCloseHintY
    private let focusShortcutHintXOffset = ShortcutHintDebugSettings.defaultRightSidebarFocusHintX
    private let focusShortcutHintYOffset = ShortcutHintDebugSettings.defaultRightSidebarFocusHintY
    @AppStorage(RightSidebarBetaFeatureSettings.dockEnabledKey)
    private var dockEnabled = RightSidebarBetaFeatureSettings.defaultDockEnabled

    // Re-reading the observable store inside modeBar causes SwiftUI to
    // track the pending count so the badge updates live when hooks push
    // new items.
    private var feedPendingCount: Int {
        FeedCoordinator.shared.store?.pending.count ?? 0
    }

    private var availableModes: [RightSidebarMode] {
        RightSidebarMode.availableModes(dockEnabled: dockEnabled)
    }

    var body: some View {
        VStack(spacing: 0) {
            modeBar
                .rightSidebarChromeBottomBorder()
            contentForMode
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .shortcutHintVisibilityAnimation(value: focusShortcutHintMonitor.isModifierPressed)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RightSidebarKeyboardFocusBridge()
            .frame(width: 1, height: 1)
        )
        .background(
            WindowAccessor { window in
                modeShortcutHintMonitor.setHostWindow(window)
                focusShortcutHintMonitor.setHostWindow(window)
                closeShortcutHintMonitor.setHostWindow(window)
            }
            .frame(width: 0, height: 0)
        )
        .accessibilityIdentifier("RightSidebar")
        .onAppear {
            modeShortcutHintMonitor.start()
            focusShortcutHintMonitor.start()
            closeShortcutHintMonitor.start()
            fileExplorerState.refreshModeAvailability()
        }
        .onDisappear {
            modeShortcutHintMonitor.stop()
            focusShortcutHintMonitor.stop()
            closeShortcutHintMonitor.stop()
        }
        .onChange(of: fileExplorerState.mode) { _, mode in
            if mode != .dock { dockStore.deactivate() }
        }
        .onChange(of: fileExplorerState.isVisible) { _, visible in if !visible { dockStore.deactivate() } }
        .onChange(of: dockEnabled) { _, _ in refreshModeAvailabilityAndFocusIfNeeded() }
    }

    private var modeBar: some View {
        let _ = keyboardShortcutSettingsObserver.revision
        let showsModeShortcutHints = alwaysShowShortcutHints || modeShortcutHintMonitor.isModifierPressed
        return ZStack {
            WindowDragHandleView()

            HStack(spacing: 4) {
                ForEach(availableModes, id: \.rawValue) { mode in
                    ModeBarButton(
                        mode: mode,
                        isSelected: fileExplorerState.mode == mode,
                        badgeCount: mode == .feed ? feedPendingCount : 0,
                        shortcutHint: KeyboardShortcutSettings.shortcut(for: mode.shortcutAction),
                        showsShortcutHint: showsModeShortcutHints
                    ) {
                        if AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
                            mode: mode,
                            focusFirstItem: true,
                            preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow
                        ) != true {
                            selectMode(mode)
                        }
                    }
                }
                Spacer(minLength: 0)
                if fileExplorerState.mode.canOpenAsPane {
                    openAsPaneButton(mode: fileExplorerState.mode)
                }
                closeButton
            }
        }
        .rightSidebarChromeBar(leadingPadding: 4, trailingPadding: 6, height: titlebarHeight)
        .overlay(alignment: .topLeading) {
            focusShortcutHintOverlay
        }
        .background(TitlebarDoubleClickMonitorView())
        .background(MinimalModeTitlebarControlHitRegionView())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("RightSidebarModeBar")
        .reportRightSidebarChromeGeometryForBonsplitUITest(
            isVisible: true,
            titlebarHeight: titlebarHeight
        )
    }

    private func openAsPaneButton(mode: RightSidebarMode) -> some View {
        Button {
            onOpenAsPane(mode)
        } label: {
            Image(systemName: "rectangle.split.2x1")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: RightSidebarChromeMetrics.controlHeight, height: RightSidebarChromeMetrics.controlHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
        .safeHelp(String(localized: "rightSidebar.openAsPane.tooltip", defaultValue: "Open as pane"))
        .accessibilityLabel(
            String.localizedStringWithFormat(
                String(localized: "rightSidebar.openAsPane.accessibilityLabel", defaultValue: "Open %@ as Pane"),
                mode.label
            )
        )
        .accessibilityIdentifier("RightSidebar.openAsPaneButton")
    }

    private var closeButton: some View {
        let _ = keyboardShortcutSettingsObserver.revision
        let shortcut = KeyboardShortcutSettings.shortcut(for: .toggleRightSidebar)
        let showsShortcutHint = titlebarShortcutHintShouldShow(
            shortcut: shortcut,
            alwaysShowShortcutHints: alwaysShowShortcutHints,
            modifierPressed: closeShortcutHintMonitor.isModifierPressed
        )
        return ZStack {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: RightSidebarChromeMetrics.controlHeight, height: RightSidebarChromeMetrics.controlHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .safeHelp(
                KeyboardShortcutSettings.Action.toggleRightSidebar.tooltip(
                    String(localized: "rightSidebar.toggle.tooltip", defaultValue: "Toggle right sidebar")
                )
            )
            .accessibilityLabel(String(localized: "rightSidebar.close.accessibilityLabel", defaultValue: "Close Right Sidebar"))
            .accessibilityIdentifier("RightSidebar.closeButton")
        }
        .frame(width: RightSidebarChromeMetrics.controlHeight, height: RightSidebarChromeMetrics.controlHeight)
        .overlay(alignment: .top) {
            if showsShortcutHint {
                ShortcutHintPill(shortcut: shortcut, fontSize: 9, emphasis: 1.05)
                    .fixedSize(horizontal: true, vertical: false)
                    .offset(
                        x: CGFloat(ShortcutHintDebugSettings.clamped(closeShortcutHintXOffset)),
                        y: CGFloat(ShortcutHintDebugSettings.clamped(closeShortcutHintYOffset))
                    )
                    .shortcutHintTransition()
                    .accessibilityIdentifier("rightSidebarCloseShortcutHint")
                    .allowsHitTesting(false)
                    .zIndex(10)
            }
        }
        .shortcutHintVisibilityAnimation(value: showsShortcutHint)
    }

    @ViewBuilder
    private var focusShortcutHintOverlay: some View {
        let _ = keyboardShortcutSettingsObserver.revision
        let shortcut = KeyboardShortcutSettings.shortcut(for: .focusRightSidebar)
        let showsFocusShortcutHint = titlebarShortcutHintShouldShow(
            shortcut: shortcut,
            alwaysShowShortcutHints: alwaysShowShortcutHints,
            modifierPressed: focusShortcutHintMonitor.isModifierPressed
        )
        if showsFocusShortcutHint {
            ShortcutHintPill(
                shortcut: shortcut,
                fontSize: 9,
                emphasis: 1.05
            )
                .padding(.leading, 6)
                .padding(.top, 5)
                .offset(
                    x: CGFloat(ShortcutHintDebugSettings.clamped(focusShortcutHintXOffset)),
                    y: CGFloat(ShortcutHintDebugSettings.clamped(focusShortcutHintYOffset))
                )
                .shortcutHintTransition()
                .accessibilityIdentifier("rightSidebarFocusShortcutHint")
                .allowsHitTesting(false)
                .zIndex(10)
        }
    }

    @ViewBuilder
    private var contentForMode: some View {
        switch fileExplorerState.mode {
        case .files:
            FileExplorerPanelView(
                store: fileExplorerStore,
                state: fileExplorerState,
                onOpenFilePreview: onOpenFilePreview,
                presentation: .files
            )
        case .find:
            FileExplorerPanelView(
                store: fileExplorerStore,
                state: fileExplorerState,
                onOpenFilePreview: onOpenFilePreview,
                presentation: .find
            )
        case .sessions:
            SessionIndexView(store: sessionIndexStore, onResume: onResumeSession)
                .onAppear {
                    sessionIndexStore.setCurrentDirectoryIfChanged(sessionIndexDirectory)
                }
        case .feed:
            FeedPanelView(
                tabManager: tabManager,
                workspaceTabStore: workspaceTabStore
            )
        case .dock:
            DockPanelView(rootDirectory: sessionIndexDirectory, workspaceId: workspaceId, store: dockStore)
        }
    }

    private var sessionIndexDirectory: String? {
        fileExplorerStore.rootPath.isEmpty ? nil : fileExplorerStore.rootPath
    }

    private func selectMode(_ mode: RightSidebarMode) {
        fileExplorerState.mode = mode
        if fileExplorerState.mode == .sessions {
            sessionIndexStore.setCurrentDirectoryIfChanged(sessionIndexDirectory)
            if sessionIndexStore.entries.isEmpty {
                sessionIndexStore.reload()
            }
        }
    }

    private func refreshModeAvailabilityAndFocusIfNeeded() {
        let previousMode = fileExplorerState.mode
        fileExplorerState.refreshModeAvailability()
        guard previousMode != fileExplorerState.mode,
              fileExplorerState.isVisible,
              let window = NSApp.keyWindow ?? NSApp.mainWindow
        else { return }
        _ = AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
            mode: fileExplorerState.mode,
            focusFirstItem: false,
            preferredWindow: window
        )
    }
}

private struct RightSidebarKeyboardFocusBridge: NSViewRepresentable {
    func makeNSView(context: Context) -> RightSidebarKeyboardFocusView {
        let view = RightSidebarKeyboardFocusView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        return view
    }

    func updateNSView(_ nsView: RightSidebarKeyboardFocusView, context: Context) {
        nsView.registerWithKeyboardFocusCoordinatorIfNeeded()
    }
}

struct SortAssistantFloatingHost: View {
    @ObservedObject private var coordinator = SortAssistantCoordinator.shared
    @ObservedObject var tabManager: TabManager
    @ObservedObject var workspaceTabStore: WorkspaceTabStore

    @State private var isPresented = false

    var body: some View {
        SortAssistantFloatingPanelBridge(
            isPresented: $isPresented,
            coordinator: coordinator,
            tabManager: tabManager,
            workspaceTabStore: workspaceTabStore
        )
        .frame(width: 1, height: 1)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
        .onChange(of: coordinator.presentationSequence) { _, _ in
            isPresented = true
        }
        .onChange(of: coordinator.presentationToggleSequence) { _, _ in
            isPresented.toggle()
        }
    }
}

private struct SortAssistantFloatingPanelBridge: NSViewRepresentable {
    @Binding var isPresented: Bool
    let coordinator: SortAssistantCoordinator
    let tabManager: TabManager
    let workspaceTabStore: WorkspaceTabStore

    func makeNSView(context: Context) -> SortAssistantFloatingPanelHostView {
        SortAssistantFloatingPanelHostView()
    }

    func updateNSView(_ nsView: SortAssistantFloatingPanelHostView, context: Context) {
        nsView.update(
            isPresented: isPresented,
            coordinator: coordinator,
            tabManager: tabManager,
            workspaceTabStore: workspaceTabStore
        )
    }

    static func dismantleNSView(_ nsView: SortAssistantFloatingPanelHostView, coordinator: ()) {
        nsView.tearDown()
    }
}

@MainActor
private final class SortAssistantFloatingPanelHostView: NSView {
    private struct DragSession {
        var startScreenPoint: CGPoint
        var startOrigin: CGPoint
    }

    private var childWindow: SortAssistantFloatingPanelWindow?
    private var hostingView: NSHostingView<SortAssistantFloatingPetContent>?
    private var observers: [NSObjectProtocol] = []
    private weak var observedParentWindow: NSWindow?
    private var isPresented = false
    private var origin: CGPoint?
    private var dragSession: DragSession?

    private let edgePadding: CGFloat = 12
    private let topPadding: CGFloat = WindowChromeMetrics.appTitlebarHeight + 14
    private let fallbackSize = NSSize(width: 404, height: 280)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncVisibility()
    }

    func update(
        isPresented: Bool,
        coordinator: SortAssistantCoordinator,
        tabManager: TabManager,
        workspaceTabStore: WorkspaceTabStore
    ) {
        self.isPresented = isPresented
        updateContent(
            coordinator: coordinator,
            tabManager: tabManager,
            workspaceTabStore: workspaceTabStore
        )
        syncVisibility()
    }

    func tearDown() {
        removeParentWindowObservers()
        if let childWindow {
            childWindow.parent?.removeChildWindow(childWindow)
            childWindow.orderOut(nil)
        }
        childWindow = nil
        hostingView = nil
        dragSession = nil
    }

    private func updateContent(
        coordinator: SortAssistantCoordinator,
        tabManager: TabManager,
        workspaceTabStore: WorkspaceTabStore
    ) {
        let content = SortAssistantFloatingPetContent(
            coordinator: coordinator,
            tabManager: tabManager,
            workspaceTabStore: workspaceTabStore
        )
        if let hostingView {
            hostingView.rootView = content
            return
        }
        let hostingView = NSHostingView(rootView: content)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.isOpaque = false
        self.hostingView = hostingView
        childWindow?.contentView = hostingView
    }

    private func syncVisibility() {
        guard isPresented else {
            childWindow?.orderOut(nil)
            dragSession = nil
            return
        }
        guard let parentWindow = window else {
            tearDown()
            return
        }
        let child = childWindow ?? makeChildWindow(parentWindow: parentWindow)
        if child.parent !== parentWindow {
            child.parent?.removeChildWindow(child)
            parentWindow.addChildWindow(child, ordered: .above)
            installParentWindowObservers(parentWindow)
        }
        child.orderFront(nil)
        syncChildFrame()
    }

    private func makeChildWindow(parentWindow: NSWindow) -> SortAssistantFloatingPanelWindow {
        let panel = SortAssistantFloatingPanelWindow(
            contentRect: NSRect(origin: .zero, size: fallbackSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.dragOwner = self
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.identifier = NSUserInterfaceItemIdentifier("cmux.sortAssistantFloatingPet")
        if let hostingView {
            panel.contentView = hostingView
        }
        parentWindow.addChildWindow(panel, ordered: .above)
        childWindow = panel
        installParentWindowObservers(parentWindow)
        return panel
    }

    private func syncChildFrame() {
        guard let hostingView else { return }
        hostingView.layoutSubtreeIfNeeded()
        var size = hostingView.fittingSize
        if size.width < 50 || size.height < 50 {
            size = fallbackSize
        }
        hostingView.frame = NSRect(origin: .zero, size: size)
        repositionChildWindow(panelSize: size)
    }

    private func repositionChildWindow(panelSize: NSSize? = nil) {
        guard let parentWindow = window,
              let contentView = parentWindow.contentView,
              let childWindow,
              let hostingView else {
            return
        }
        let size = panelSize ?? (hostingView.frame.size == .zero ? fallbackSize : hostingView.frame.size)
        let containerSize = contentView.bounds.size
        let clampedOrigin = clamp(
            origin ?? defaultOrigin(panelSize: size, in: containerSize),
            panelSize: size,
            in: containerSize
        )
        origin = clampedOrigin
        let rectInContent = NSRect(origin: clampedOrigin, size: size)
        let rectInWindow = contentView.convert(rectInContent, to: nil)
        let rectOnScreen = parentWindow.convertToScreen(rectInWindow)
        if childWindow.frame != rectOnScreen {
            childWindow.setFrame(rectOnScreen, display: true)
        }
    }

    private func defaultOrigin(panelSize: NSSize, in containerSize: NSSize) -> CGPoint {
        CGPoint(
            x: max(edgePadding, containerSize.width - panelSize.width - 96),
            y: max(edgePadding, containerSize.height - panelSize.height - topPadding)
        )
    }

    private func clamp(_ proposed: CGPoint, panelSize: NSSize, in containerSize: NSSize) -> CGPoint {
        let maxX = max(edgePadding, containerSize.width - panelSize.width - edgePadding)
        let maxY = max(edgePadding, containerSize.height - panelSize.height - edgePadding)
        return CGPoint(
            x: min(max(edgePadding, proposed.x), maxX),
            y: min(max(edgePadding, proposed.y), maxY)
        )
    }

    func beginDrag(screenPoint: CGPoint) {
        guard let parentWindow = window,
              let contentView = parentWindow.contentView,
              let hostingView else { return }
        let size = hostingView.frame.size == .zero ? fallbackSize : hostingView.frame.size
        dragSession = DragSession(
            startScreenPoint: screenPoint,
            startOrigin: origin ?? defaultOrigin(panelSize: size, in: contentView.bounds.size)
        )
    }

    func updateDrag(screenPoint: CGPoint) {
        guard let contentView = window?.contentView,
              let session = dragSession else { return }
        let screenDeltaY = screenPoint.y - session.startScreenPoint.y
        let contentDeltaY = contentView.isFlipped ? -screenDeltaY : screenDeltaY
        let size = hostingView?.frame.size ?? fallbackSize
        origin = clamp(
            CGPoint(
                x: session.startOrigin.x + screenPoint.x - session.startScreenPoint.x,
                y: session.startOrigin.y + contentDeltaY
            ),
            panelSize: size,
            in: contentView.bounds.size
        )
        repositionChildWindow(panelSize: size)
    }

    func endDrag() {
        dragSession = nil
        repositionChildWindow()
    }

    private func installParentWindowObservers(_ parentWindow: NSWindow) {
        guard observedParentWindow !== parentWindow || observers.isEmpty else { return }
        removeParentWindowObservers()

        let center = NotificationCenter.default
        let repositionNames: [Notification.Name] = [
            NSWindow.didMoveNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didBecomeKeyNotification,
        ]
        observers = repositionNames.map { name in
            center.addObserver(forName: name, object: parentWindow, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.repositionChildWindow()
                }
            }
        }
        observers.append(
            center.addObserver(forName: NSWindow.didResizeNotification, object: parentWindow, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.syncChildFrame()
                }
            }
        )
        observers.append(
            center.addObserver(forName: NSWindow.willCloseNotification, object: parentWindow, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.tearDown()
                }
            }
        )
        observedParentWindow = parentWindow
    }

    private func removeParentWindowObservers() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        observedParentWindow = nil
    }
}

private struct SortAssistantFloatingPetContent: View {
    @ObservedObject var coordinator: SortAssistantCoordinator
    @ObservedObject var tabManager: TabManager
    @ObservedObject var workspaceTabStore: WorkspaceTabStore

    private let conversationWidth: CGFloat = 360
    private let avatarSize: CGFloat = 56
    private let widgetSpacing: CGFloat = 10

    var body: some View {
        HStack(alignment: .bottom, spacing: widgetSpacing) {
            mascot
            conversationBubble
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("SortAssistantFloatingPanel")
    }

    private var mascot: some View {
        SortAssistantMascotAvatar(
            size: avatarSize,
            isActive: coordinator.isSorting
        )
        .padding(.bottom, 8)
    }

    private var conversationBubble: some View {
        SortAssistantThreadView(
            coordinator: coordinator,
            tabManager: tabManager,
            workspaceTabStore: workspaceTabStore,
            showsHeader: false,
            showsAssistantMessageAvatar: false
        )
        .frame(width: conversationWidth, alignment: .topLeading)
        .background(alignment: .bottomTrailing) {
            conversationShadow
        }
        .background(conversationFill)
        .overlay(conversationOuterBorder)
        .overlay(conversationInnerHighlight)
        .overlay(conversationInnerLowlight)
        .overlay(alignment: .leading) {
            conversationConnector
        }
    }

    private var conversationShadow: some View {
        SortAssistantPixelPanelShape(cornerLength: 8)
            .fill(Color.black.opacity(0.22))
            .offset(x: 4, y: 4)
            .allowsHitTesting(false)
    }

    private var conversationFill: some View {
        SortAssistantPixelPanelShape(cornerLength: 8)
            .fill(Color(nsColor: .controlBackgroundColor))
    }

    private var conversationOuterBorder: some View {
        SortAssistantPixelPanelShape(cornerLength: 8)
            .stroke(Color.primary.opacity(0.72), lineWidth: 2)
    }

    private var conversationInnerHighlight: some View {
        SortAssistantPixelPanelShape(cornerLength: 5)
            .stroke(Color.white.opacity(0.38), lineWidth: 1)
            .padding(4)
    }

    private var conversationInnerLowlight: some View {
        SortAssistantPixelPanelShape(cornerLength: 5)
            .stroke(Color.black.opacity(0.10), lineWidth: 1)
            .padding(.leading, 4)
            .padding(.trailing, 4)
            .padding(.top, 4)
            .padding(.bottom, 6)
            .offset(y: 1)
    }

    private var conversationConnector: some View {
        SortAssistantPetBubbleTail()
            .fill(Color(nsColor: .controlBackgroundColor))
            .frame(width: 18, height: 24)
            .background {
                SortAssistantPetBubbleTail()
                    .fill(Color.black.opacity(0.22))
                    .offset(x: 4, y: 4)
            }
            .overlay(
                SortAssistantPetBubbleTail()
                    .stroke(Color.primary.opacity(0.72), lineWidth: 2)
            )
            .overlay(
                SortAssistantPetBubbleTail()
                    .stroke(Color.white.opacity(0.32), lineWidth: 1)
                    .padding(3)
            )
            .offset(x: -12, y: 18)
            .allowsHitTesting(false)
    }
}

private final class SortAssistantFloatingPanelWindow: NSPanel {
    weak var dragOwner: SortAssistantFloatingPanelHostView?
    private var pendingDragStartPoint: CGPoint?
    private var isDraggingPet = false
    private let avatarDragWidth: CGFloat = 68
    private let avatarDragHeight: CGFloat = 88
    private let dragThresholdSquared: CGFloat = 9

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            pendingDragStartPoint = isInAvatarDragHotspot(event.locationInWindow) ? event.locationInWindow : nil
            isDraggingPet = false
            super.sendEvent(event)
        case .leftMouseDragged:
            if !isDraggingPet {
                guard let start = pendingDragStartPoint else {
                    super.sendEvent(event)
                    return
                }
                let current = event.locationInWindow
                let dx = current.x - start.x
                let dy = current.y - start.y
                guard dx * dx + dy * dy >= dragThresholdSquared else {
                    super.sendEvent(event)
                    return
                }
                isDraggingPet = true
                dragOwner?.beginDrag(screenPoint: currentMouseScreenPoint())
            }
            dragOwner?.updateDrag(screenPoint: currentMouseScreenPoint())
        case .leftMouseUp:
            if isDraggingPet {
                dragOwner?.endDrag()
                isDraggingPet = false
                pendingDragStartPoint = nil
                return
            }
            pendingDragStartPoint = nil
            super.sendEvent(event)
        default:
            super.sendEvent(event)
        }
    }

    private func isInAvatarDragHotspot(_ point: CGPoint) -> Bool {
        point.x >= 0 &&
            point.x <= avatarDragWidth &&
            point.y >= 0 &&
            point.y <= avatarDragHeight
    }

    private func currentMouseScreenPoint() -> CGPoint {
        NSEvent.mouseLocation
    }
}

private struct SortAssistantPetBubbleTail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let notch = rect.width * 0.38
        let tab = rect.width * 0.68
        let upper = rect.height * 0.28
        let lower = rect.height * 0.72

        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: tab, y: rect.minY))
        path.addLine(to: CGPoint(x: tab, y: upper))
        path.addLine(to: CGPoint(x: notch, y: upper))
        path.addLine(to: CGPoint(x: notch, y: rect.height * 0.42))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.height * 0.42))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.height * 0.58))
        path.addLine(to: CGPoint(x: notch, y: rect.height * 0.58))
        path.addLine(to: CGPoint(x: notch, y: lower))
        path.addLine(to: CGPoint(x: tab, y: lower))
        path.addLine(to: CGPoint(x: tab, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

final class RightSidebarKeyboardFocusView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        AppDelegate.shared?.keyboardFocusCoordinator(for: window)?.registerRightSidebarHost(self)
#if DEBUG
        cmuxDebugLog(
            "rs.focus.host.attach win=\(window.windowNumber) canAccept=\(cmuxCanAcceptRightSidebarKeyboardFocus ? 1 : 0) " +
            "fr=\(rightSidebarDebugResponder(window.firstResponder))"
        )
#endif
    }

    func registerWithKeyboardFocusCoordinatorIfNeeded() {
        guard let window else { return }
        AppDelegate.shared?.keyboardFocusCoordinator(for: window)?.registerRightSidebarHost(self)
    }

    override func layout() {
        super.layout()
        registerWithKeyboardFocusCoordinatorIfNeeded()
    }

    override func keyDown(with event: NSEvent) {
        if let mode = RightSidebarMode.modeShortcut(for: event) {
            _ = AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
                mode: mode,
                focusFirstItem: true,
                preferredWindow: window
            )
            return
        }
        if event.keyCode == 53 {
            if let window,
               AppDelegate.shared?.keyboardFocusCoordinator(for: window)?.focusTerminal() == true {
                return
            }
            window?.makeFirstResponder(nil)
            return
        }
        if let characters = event.charactersIgnoringModifiers, !characters.isEmpty {
            return
        }
        super.keyDown(with: event)
    }

    func focusHostFromCoordinator() -> Bool {
        guard let window else {
#if DEBUG
            cmuxDebugLog("rs.focus.host.focus result=0 reason=noWindow")
#endif
            return false
        }
        let result = window.makeFirstResponder(self)
#if DEBUG
        cmuxDebugLog(
            "rs.focus.host.focus result=\(result ? 1 : 0) win=\(window.windowNumber) " +
            "fr=\(rightSidebarDebugResponder(window.firstResponder))"
        )
#endif
        return result
    }
}

extension NSView {
    var cmuxCanAcceptRightSidebarKeyboardFocus: Bool {
        guard window != nil, !isHiddenOrHasHiddenAncestor else { return false }
        var view: NSView? = self
        while let current = view {
            if current.bounds.width <= 0.5 || current.bounds.height <= 0.5 {
                return false
            }
            view = current.superview
        }
        return true
    }
}

private struct ModeBarButton: View {
    let mode: RightSidebarMode
    let isSelected: Bool
    var badgeCount: Int = 0
    let shortcutHint: StoredShortcut
    let showsShortcutHint: Bool
    let action: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: mode.symbolName)
                    .font(.system(size: 11, weight: .medium))
                Text(mode.label)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if badgeCount > 0 {
                    pendingChip
                }
            }
            .rightSidebarChromePill(
                isSelected: isSelected,
                isHovered: isHovered,
                geometryKeyPrefix: "rightSidebarModeControl_\(mode.rawValue)"
            )
            .overlay(alignment: .trailing) {
                if showsShortcutHint {
                    ShortcutHintPill(shortcut: shortcutHint, fontSize: 9, emphasis: isSelected ? 1.15 : 0.95)
                        .offset(x: 5)
                        .shortcutHintTransition()
                        .accessibilityIdentifier("rightSidebarModeShortcutHint.\(mode.rawValue)")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(helpText)
        .accessibilityIdentifier("RightSidebarModeButton.\(mode.rawValue)")
        .shortcutHintVisibilityAnimation(value: showsShortcutHint)
    }

    private var helpText: String {
        if badgeCount > 0 {
            return String(
                localized: "rightSidebar.mode.pendingHelp",
                defaultValue: "\(mode.label) · \(badgeCount) pending"
            )
        }
        return mode.label
    }

    /// Subtle inline count chip that sits after the label instead of
    /// floating a red capsule over the icon. Tinted orange (the "needs
    /// attention" color used elsewhere in the Feed) and sized to match
    /// the label's typography.
    private var pendingChip: some View {
        let countText = badgeCount > 9 ? "9+" : String(badgeCount)
        return Text(countText)
            .font(.system(size: 10, weight: .bold).monospacedDigit())
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: true)
            .foregroundColor(.orange)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.orange.opacity(0.20))
            )
            .fixedSize(horizontal: true, vertical: true)
            .layoutPriority(2)
    }
}
