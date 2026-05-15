import AppKit
import SwiftUI

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
    private var lastResolvedScreenOrigin: CGPoint?
    private var dragSession: DragSession?
    private var hasUserPositioned = false

    private let edgePadding: CGFloat = 12
    private let topPadding: CGFloat = WindowChromeMetrics.appTitlebarHeight + 14
    private let fallbackSize = NSSize(width: 404, height: 280)
    private let topOverlayReserveHeight = SortAssistantFloatingPetContent.topOverlayReserveHeight

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
        lastResolvedScreenOrigin = nil
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

    private func syncChildFrame(preserveExistingOrigin: Bool = true) {
        guard let hostingView else { return }
        let previousFrame = childWindow?.frame
        let preservedScreenOrigin = lastResolvedScreenOrigin ?? previousFrame?.origin
        hostingView.layoutSubtreeIfNeeded()
        var size = hostingView.fittingSize
        if size.width < 50 || size.height < 50 {
            size = fallbackSize
        }
        hostingView.frame = NSRect(origin: .zero, size: size)

        // Content-driven height changes, such as completions appearing above the input,
        // should grow the bubble upward without moving the pet's screen position.
        if preserveExistingOrigin,
           let previousFrame,
           previousFrame.width > 0,
           previousFrame.height > 0,
           let preservedScreenOrigin,
           let parentWindow = window,
           let contentView = parentWindow.contentView,
           let childWindow,
           origin != nil {
            let rectOnScreen = NSRect(origin: preservedScreenOrigin, size: size)
            let rectInWindow = parentWindow.convertFromScreen(rectOnScreen)
            let rectInContent = contentView.convert(rectInWindow, from: nil)
            origin = rectInContent.origin
            lastResolvedScreenOrigin = preservedScreenOrigin
            if childWindow.frame != rectOnScreen {
                childWindow.setFrame(rectOnScreen, display: true)
            }
            DispatchQueue.main.async { [weak self, weak childWindow] in
                guard let self,
                      let childWindow,
                      self.childWindow === childWindow,
                      self.lastResolvedScreenOrigin == preservedScreenOrigin else {
                    return
                }
                let rect = NSRect(origin: preservedScreenOrigin, size: childWindow.frame.size)
                if childWindow.frame.origin != preservedScreenOrigin {
                    childWindow.setFrame(rect, display: true)
                }
            }
            return
        }

        repositionChildWindow(panelSize: size, clampToVisibleArea: !hasUserPositioned)
    }

    private func repositionChildWindow(
        panelSize: NSSize? = nil,
        clampToVisibleArea: Bool = true
    ) {
        guard let parentWindow = window,
              let contentView = parentWindow.contentView,
              let childWindow,
              let hostingView else {
            return
        }
        let size = panelSize ?? (hostingView.frame.size == .zero ? fallbackSize : hostingView.frame.size)
        let containerSize = contentView.bounds.size
        let positioningSize = positioningSize(for: size)
        let preferredOrigin = origin ?? defaultOrigin(panelSize: positioningSize, in: containerSize)
        let resolvedOrigin = clampToVisibleArea
            ? clampedOrigin(preferredOrigin, panelSize: positioningSize, in: containerSize)
            : preferredOrigin
        origin = resolvedOrigin
        let anchorRectInContent = NSRect(origin: resolvedOrigin, size: positioningSize)
        let anchorRectInWindow = contentView.convert(anchorRectInContent, to: nil)
        let anchorRectOnScreen = parentWindow.convertToScreen(anchorRectInWindow)
        let rectOnScreen = NSRect(origin: anchorRectOnScreen.origin, size: size)
        lastResolvedScreenOrigin = rectOnScreen.origin
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

    private func positioningSize(for panelSize: NSSize) -> NSSize {
        NSSize(
            width: panelSize.width,
            height: max(50, panelSize.height - topOverlayReserveHeight)
        )
    }

    private func clampedOrigin(
        _ preferredOrigin: CGPoint,
        panelSize: NSSize,
        in containerSize: NSSize
    ) -> CGPoint {
        let maxX = max(edgePadding, containerSize.width - panelSize.width - edgePadding)
        let maxY = max(edgePadding, containerSize.height - panelSize.height - topPadding)
        return CGPoint(
            x: min(max(preferredOrigin.x, edgePadding), maxX),
            y: min(max(preferredOrigin.y, edgePadding), maxY)
        )
    }

    func beginDrag(screenPoint: CGPoint) {
        guard let parentWindow = window,
              let contentView = parentWindow.contentView,
              let hostingView else { return }
        let size = hostingView.frame.size == .zero ? fallbackSize : hostingView.frame.size
        let positioningSize = positioningSize(for: size)
        hasUserPositioned = true
        dragSession = DragSession(
            startScreenPoint: screenPoint,
            startOrigin: origin ?? defaultOrigin(panelSize: positioningSize, in: contentView.bounds.size)
        )
    }

    func updateDrag(screenPoint: CGPoint) {
        guard let contentView = window?.contentView,
              let session = dragSession else { return }
        let screenDeltaY = screenPoint.y - session.startScreenPoint.y
        let contentDeltaY = contentView.isFlipped ? -screenDeltaY : screenDeltaY
        let size = hostingView?.frame.size ?? fallbackSize
        origin = CGPoint(
            x: session.startOrigin.x + screenPoint.x - session.startScreenPoint.x,
            y: session.startOrigin.y + contentDeltaY
        )
        repositionChildWindow(panelSize: size, clampToVisibleArea: false)
    }

    func endDrag() {
        dragSession = nil
        repositionChildWindow(clampToVisibleArea: false)
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
                    guard let self else { return }
                    self.repositionChildWindow(clampToVisibleArea: !self.hasUserPositioned)
                }
            }
        }
        observers.append(
            center.addObserver(forName: NSWindow.didResizeNotification, object: parentWindow, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.syncChildFrame(preserveExistingOrigin: false)
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
    static let topOverlayReserveHeight =
        SortAssistantThreadView.completionPanelMaxHeight + SortAssistantThreadView.completionPanelSpacing

    @ObservedObject var coordinator: SortAssistantCoordinator
    @ObservedObject var tabManager: TabManager
    @ObservedObject var workspaceTabStore: WorkspaceTabStore

    private let conversationWidth: CGFloat = 360
    private let avatarSize: CGFloat = 56
    private let avatarBottomPadding: CGFloat = 8
    private let connectorSize = CGSize(width: 18, height: 24)
    private let widgetSpacing: CGFloat = 10

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: Self.topOverlayReserveHeight)
                .allowsHitTesting(false)
            HStack(alignment: .bottom, spacing: widgetSpacing) {
                mascot
                conversationBubble
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("SortAssistantFloatingPanel")
    }

    private var mascot: some View {
        SortAssistantMascotAvatar(
            size: avatarSize,
            isActive: coordinator.isSorting,
            state: coordinator.mascotState
        )
        .padding(.bottom, avatarBottomPadding)
    }

    private var conversationBubble: some View {
        SortAssistantThreadView(
            coordinator: coordinator,
            tabManager: tabManager,
            workspaceTabStore: workspaceTabStore,
            showsHeader: false,
            showsAssistantMessageAvatar: false,
            completionLayout: .overlay
        )
        .frame(width: conversationWidth, alignment: .topLeading)
        .background(alignment: .bottomTrailing) {
            conversationShadow
        }
        .background(conversationFill)
        .overlay(conversationOuterBorder)
        .overlay(conversationInnerHighlight)
        .overlay(conversationInnerLowlight)
        .overlay(alignment: .topLeading) {
            GeometryReader { proxy in
                conversationConnector
                    .offset(
                        x: -12,
                        y: connectorTopOffset(forBubbleHeight: proxy.size.height)
                    )
            }
            .allowsHitTesting(false)
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
            .frame(width: connectorSize.width, height: connectorSize.height)
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
            .allowsHitTesting(false)
    }

    private func connectorTopOffset(forBubbleHeight bubbleHeight: CGFloat) -> CGFloat {
        let spriteCenterY = bubbleHeight - avatarBottomPadding - avatarSize * 0.5
        let centeredTop = spriteCenterY - connectorSize.height * 0.5
        let lowerBound = connectorSize.height * 0.5
        let upperBound = max(lowerBound, bubbleHeight - connectorSize.height - connectorSize.height * 0.5)
        return min(max(centeredTop, lowerBound), upperBound)
    }
}

private final class SortAssistantFloatingPanelWindow: NSPanel {
    weak var dragOwner: SortAssistantFloatingPanelHostView?
    private var pendingDragStartPoint: CGPoint?
    private var isDraggingPet = false
    private var isForwardingMouseEventsToParent = false
    private let avatarDragOrigin = CGPoint(x: 4, y: 10)
    private let avatarDragSize = CGSize(width: 48, height: 52)
    private let bubbleHitMinX: CGFloat = 66
    private let dragThresholdSquared: CGFloat = 9

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            guard isInInteractiveHitRegion(event.locationInWindow) else {
                isForwardingMouseEventsToParent = true
                forwardMouseEventToParent(event)
                return
            }
            pendingDragStartPoint = isInAvatarDragHotspot(event.locationInWindow) ? event.locationInWindow : nil
            isDraggingPet = false
            super.sendEvent(event)
        case .leftMouseDragged:
            if isForwardingMouseEventsToParent {
                forwardMouseEventToParent(event)
                return
            }
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
            if isForwardingMouseEventsToParent {
                isForwardingMouseEventsToParent = false
                forwardMouseEventToParent(event)
                return
            }
            if isDraggingPet {
                dragOwner?.endDrag()
                isDraggingPet = false
                pendingDragStartPoint = nil
                return
            }
            pendingDragStartPoint = nil
            super.sendEvent(event)
        case .rightMouseDown, .otherMouseDown:
            guard isInInteractiveHitRegion(event.locationInWindow) else {
                isForwardingMouseEventsToParent = true
                forwardMouseEventToParent(event)
                return
            }
            super.sendEvent(event)
        case .rightMouseDragged, .otherMouseDragged:
            if isForwardingMouseEventsToParent {
                forwardMouseEventToParent(event)
                return
            }
            super.sendEvent(event)
        case .rightMouseUp, .otherMouseUp:
            if isForwardingMouseEventsToParent {
                isForwardingMouseEventsToParent = false
                forwardMouseEventToParent(event)
                return
            }
            super.sendEvent(event)
        default:
            super.sendEvent(event)
        }
    }

    private func isInAvatarDragHotspot(_ point: CGPoint) -> Bool {
        let rect = CGRect(origin: avatarDragOrigin, size: avatarDragSize)
        guard rect.contains(point) else { return false }
        let dx = (point.x - rect.midX) / max(rect.width * 0.5, 1)
        let dy = (point.y - rect.midY) / max(rect.height * 0.5, 1)
        return dx * dx + dy * dy <= 1.05
    }

    private func currentMouseScreenPoint() -> CGPoint {
        NSEvent.mouseLocation
    }

    private func isInInteractiveHitRegion(_ point: CGPoint) -> Bool {
        if isInAvatarDragHotspot(point) {
            return true
        }
        let bounds = contentView?.bounds ?? NSRect(origin: .zero, size: frame.size)
        return point.x >= bubbleHitMinX &&
            point.x <= bounds.maxX &&
            point.y >= bounds.minY &&
            point.y <= bounds.maxY
    }

    private func forwardMouseEventToParent(_ event: NSEvent) {
        guard let parent else { return }
        let screenRect = convertToScreen(NSRect(origin: event.locationInWindow, size: .zero))
        let parentPoint = parent.convertFromScreen(screenRect).origin
        guard let forwarded = NSEvent.mouseEvent(
            with: event.type,
            location: parentPoint,
            modifierFlags: event.modifierFlags,
            timestamp: event.timestamp,
            windowNumber: parent.windowNumber,
            context: nil,
            eventNumber: event.eventNumber,
            clickCount: event.clickCount,
            pressure: event.pressure
        ) else {
            return
        }
        parent.sendEvent(forwarded)
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
