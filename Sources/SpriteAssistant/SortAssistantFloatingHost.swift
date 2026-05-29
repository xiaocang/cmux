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
            layoutRevision: coordinator.floatingLayoutRevision,
            focusRevision: coordinator.entryFocusSequence,
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
            isPresented = true
        }
        .onChange(of: coordinator.isFloatingSpriteVisible) { _, visible in
            isPresented = visible
        }
        .onAppear {
            isPresented = coordinator.isFloatingSpriteVisible
        }
    }
}

enum SortAssistantFloatingConversationBubbleSide: String {
    case right
    case left
}

private struct SortAssistantFloatingPanelBridge: NSViewRepresentable {
    @Binding var isPresented: Bool
    let layoutRevision: Int
    let focusRevision: Int
    let coordinator: SortAssistantCoordinator
    let tabManager: TabManager
    let workspaceTabStore: WorkspaceTabStore

    func makeNSView(context: Context) -> SortAssistantFloatingPanelHostView {
        SortAssistantFloatingPanelHostView()
    }

    func updateNSView(_ nsView: SortAssistantFloatingPanelHostView, context: Context) {
        nsView.update(
            isPresented: isPresented,
            layoutRevision: layoutRevision,
            focusRevision: focusRevision,
            coordinator: coordinator,
            tabManager: tabManager,
            workspaceTabStore: workspaceTabStore
        )
    }

    static func dismantleNSView(_ nsView: SortAssistantFloatingPanelHostView, coordinator: ()) {
        nsView.tearDown()
    }
}

enum SortAssistantFloatingPanelScreenClamp {
    enum Mode {
        case constrained
        case manualDrag(hotspot: NSRect, minimumVisibleSize: NSSize)
        case unrestricted
    }

    static func resolvedRect(
        _ rect: NSRect,
        visibleFrame: NSRect?,
        edgePadding: CGFloat,
        mode: Mode
    ) -> NSRect {
        guard let visibleFrame else {
            return rect
        }
        switch mode {
        case .constrained:
            return constrainedRect(rect, visibleFrame: visibleFrame, edgePadding: edgePadding)
        case let .manualDrag(hotspot, minimumVisibleSize):
            return rectKeepingHotspotVisible(
                rect,
                visibleFrame: visibleFrame,
                hotspot: hotspot,
                minimumVisibleSize: minimumVisibleSize
            )
        case .unrestricted:
            return rect
        }
    }

    static func hotspotRect(in rect: NSRect, hotspot: NSRect) -> NSRect {
        NSRect(
            x: rect.minX + hotspot.minX,
            y: rect.minY + hotspot.minY,
            width: hotspot.width,
            height: hotspot.height
        )
    }

    private static func constrainedRect(
        _ rect: NSRect,
        visibleFrame: NSRect,
        edgePadding: CGFloat
    ) -> NSRect {
        let horizontalPadding = min(edgePadding, max(0, visibleFrame.width * 0.5))
        let verticalPadding = min(edgePadding, max(0, visibleFrame.height * 0.5))
        let bounds = visibleFrame.insetBy(dx: horizontalPadding, dy: verticalPadding)
        let width = min(rect.width, bounds.width)
        let height = min(rect.height, bounds.height)
        let maxX = max(bounds.minX, bounds.maxX - width)
        let maxY = max(bounds.minY, bounds.maxY - height)
        return NSRect(
            x: min(max(rect.origin.x, bounds.minX), maxX),
            y: min(max(rect.origin.y, bounds.minY), maxY),
            width: width,
            height: height
        )
    }

    private static func rectKeepingHotspotVisible(
        _ rect: NSRect,
        visibleFrame: NSRect,
        hotspot: NSRect,
        minimumVisibleSize: NSSize
    ) -> NSRect {
        let requiredWidth = min(max(0, minimumVisibleSize.width), hotspot.width, visibleFrame.width)
        let requiredHeight = min(max(0, minimumVisibleSize.height), hotspot.height, visibleFrame.height)
        guard requiredWidth > 0, requiredHeight > 0 else {
            return rect
        }

        let minOriginX = visibleFrame.minX + requiredWidth - hotspot.maxX
        let maxOriginX = visibleFrame.maxX - requiredWidth - hotspot.minX
        let minOriginY = visibleFrame.minY + requiredHeight - hotspot.maxY
        let maxOriginY = visibleFrame.maxY - requiredHeight - hotspot.minY

        return NSRect(
            x: min(max(rect.origin.x, minOriginX), maxOriginX),
            y: min(max(rect.origin.y, minOriginY), maxOriginY),
            width: rect.width,
            height: rect.height
        )
    }
}

enum SortAssistantVisibleScreenRange {
    static func currentVisibleFrames() -> [NSRect] {
        validFrames(NSScreen.screens.map(\.visibleFrame))
    }

    static func isVisible(_ point: CGPoint) -> Bool {
        isVisible(point, visibleFrames: currentVisibleFrames())
    }

    static func isVisible(_ point: CGPoint, visibleFrames: [NSRect]) -> Bool {
        validFrames(visibleFrames).contains { $0.contains(point) }
    }

    static func isFullyVisible(_ rect: NSRect, tolerance: CGFloat = 0) -> Bool {
        isFullyVisible(
            rect,
            visibleFrames: currentVisibleFrames(),
            tolerance: tolerance
        )
    }

    static func isFullyVisible(
        _ rect: NSRect,
        visibleFrames: [NSRect],
        tolerance: CGFloat = 0
    ) -> Bool {
        guard isValid(rect) else { return false }
        let pixelTolerance = max(0, tolerance)
        let coverageFrames = validFrames(visibleFrames).map {
            $0.insetBy(dx: -pixelTolerance, dy: -pixelTolerance)
        }
        guard !coverageFrames.isEmpty else { return false }

        var uncovered = [rect]
        for visibleFrame in coverageFrames {
            uncovered = uncovered.flatMap { remainingRects(of: $0, subtracting: visibleFrame) }
            if uncovered.isEmpty {
                return true
            }
        }
        return false
    }

    static func selectedVisibleFrame(
        for rect: NSRect,
        preferredScreenPoint: CGPoint?,
        visibleFrames: [NSRect]
    ) -> NSRect? {
        let frames = validFrames(visibleFrames)
        guard !frames.isEmpty else { return nil }

        if let preferredScreenPoint {
            if let containing = frames.first(where: { $0.contains(preferredScreenPoint) }) {
                return containing
            }
            return frames.min {
                distanceSquared(from: preferredScreenPoint, to: $0) <
                    distanceSquared(from: preferredScreenPoint, to: $1)
            }
        }

        if let intersecting = frames.max(by: {
            intersectionArea($0, rect) < intersectionArea($1, rect)
        }),
           intersectionArea(intersecting, rect) > 0 {
            return intersecting
        }

        return frames.min {
            distanceSquared(from: center(of: rect), to: $0) <
                distanceSquared(from: center(of: rect), to: $1)
        }
    }

    static func debugDescription(for visibleFrames: [NSRect]) -> String {
        "[" + validFrames(visibleFrames).map { String(describing: $0) }.joined(separator: ", ") + "]"
    }

    private static func validFrames(_ frames: [NSRect]) -> [NSRect] {
        frames.filter(isValid)
    }

    private static func isValid(_ rect: NSRect) -> Bool {
        !rect.isNull &&
            rect.minX.isFinite &&
            rect.minY.isFinite &&
            rect.width.isFinite &&
            rect.height.isFinite &&
            rect.width > 0 &&
            rect.height > 0
    }

    private static func remainingRects(of rect: NSRect, subtracting covered: NSRect) -> [NSRect] {
        let intersection = rect.intersection(covered)
        guard isValid(intersection) else {
            return [rect]
        }

        var remaining: [NSRect] = []
        if rect.minY < intersection.minY {
            remaining.append(NSRect(
                x: rect.minX,
                y: rect.minY,
                width: rect.width,
                height: intersection.minY - rect.minY
            ))
        }
        if intersection.maxY < rect.maxY {
            remaining.append(NSRect(
                x: rect.minX,
                y: intersection.maxY,
                width: rect.width,
                height: rect.maxY - intersection.maxY
            ))
        }
        if rect.minX < intersection.minX {
            remaining.append(NSRect(
                x: rect.minX,
                y: intersection.minY,
                width: intersection.minX - rect.minX,
                height: intersection.height
            ))
        }
        if intersection.maxX < rect.maxX {
            remaining.append(NSRect(
                x: intersection.maxX,
                y: intersection.minY,
                width: rect.maxX - intersection.maxX,
                height: intersection.height
            ))
        }
        return validFrames(remaining)
    }

    private static func intersectionArea(_ lhs: NSRect, _ rhs: NSRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard isValid(intersection) else { return 0 }
        return intersection.width * intersection.height
    }

    private static func distanceSquared(from point: CGPoint, to rect: NSRect) -> CGFloat {
        let dx: CGFloat
        if point.x < rect.minX {
            dx = rect.minX - point.x
        } else if point.x > rect.maxX {
            dx = point.x - rect.maxX
        } else {
            dx = 0
        }
        let dy: CGFloat
        if point.y < rect.minY {
            dy = rect.minY - point.y
        } else if point.y > rect.maxY {
            dy = point.y - rect.maxY
        } else {
            dy = 0
        }
        return dx * dx + dy * dy
    }

    private static func center(of rect: NSRect) -> CGPoint {
        CGPoint(x: rect.midX, y: rect.midY)
    }
}

enum SortAssistantFloatingPanelMetrics {
    static let avatarSize: CGFloat = 56
    static let avatarBottomPadding: CGFloat = 8
    static let conversationWidth: CGFloat = 360
    static let widgetSpacing: CGFloat = 10
    static let connectorSize = CGSize(width: 18, height: 24)
    static let avatarVisualFrame = avatarVisualFrame(side: .right)
    static let avatarDragHotspot = avatarDragHotspot(side: .right)
    static let spriteEdgeRecoveryOverflowThreshold: CGFloat = 0.5
    static let recoveryMiniSpriteDiameter: CGFloat = 28
    static var conversationHorizontalExtent: CGFloat {
        conversationWidth + widgetSpacing
    }

    static func avatarVisualFrame(side: SortAssistantFloatingConversationBubbleSide) -> NSRect {
        NSRect(
            x: avatarSlotMinX(side: side),
            y: avatarBottomPadding,
            width: avatarSize,
            height: avatarSize
        )
    }

    static func avatarDragHotspot(side: SortAssistantFloatingConversationBubbleSide) -> NSRect {
        let base = NSRect(x: 4, y: 10, width: 48, height: 52)
        return base.offsetBy(dx: avatarSlotMinX(side: side), dy: 0)
    }

    static var minimumVisibleDragHotspotSize: NSSize {
        NSSize(width: recoveryMiniSpriteDiameter, height: recoveryMiniSpriteDiameter)
    }

    static var avatarDragRecoveryHotspot: NSRect {
        avatarDragRecoveryHotspot(side: .right)
    }

    static func avatarDragRecoveryHotspot(side: SortAssistantFloatingConversationBubbleSide) -> NSRect {
        let hotspot = avatarDragHotspot(side: side)
        let size = minimumVisibleDragHotspotSize
        return NSRect(
            x: hotspot.midX - size.width * 0.5,
            y: hotspot.midY - size.height * 0.5,
            width: size.width,
            height: size.height
        )
    }

    static func conversationBubbleHitFrame(
        side: SortAssistantFloatingConversationBubbleSide,
        in bounds: NSRect
    ) -> NSRect {
        switch side {
        case .right:
            return NSRect(
                x: avatarSize + widgetSpacing,
                y: bounds.minY,
                width: max(0, bounds.maxX - avatarSize - widgetSpacing),
                height: bounds.height
            )
        case .left:
            return NSRect(
                x: bounds.minX,
                y: bounds.minY,
                width: min(conversationWidth, bounds.width),
                height: bounds.height
            )
        }
    }

    private static func avatarSlotMinX(side: SortAssistantFloatingConversationBubbleSide) -> CGFloat {
        switch side {
        case .right:
            return 0
        case .left:
            return conversationHorizontalExtent
        }
    }

    /// Decides which side of the avatar the conversation bubble should open on.
    ///
    /// - When `sticky` is false (a fresh appearance), pick the best-fitting side,
    ///   preferring the default rightward bubble whenever the right has room.
    /// - When `sticky` is true (an ongoing layout while the bubble stays open),
    ///   keep `currentSide` as long as it still fits on screen, and only flip to
    ///   the opposite side once the current side can no longer hold the bubble.
    ///   This stops the bubble from snapping back to the right the instant the
    ///   sprite drifts away from the right screen edge.
    static func resolvedConversationBubbleSide(
        currentSide: SortAssistantFloatingConversationBubbleSide,
        avatarOnScreen: NSRect,
        visibleFrame: NSRect,
        edgePadding: CGFloat,
        sticky: Bool
    ) -> SortAssistantFloatingConversationBubbleSide {
        let requiredSpace = conversationHorizontalExtent
        let rightAvailable = visibleFrame.maxX - edgePadding - avatarOnScreen.maxX
        let leftAvailable = avatarOnScreen.minX - visibleFrame.minX - edgePadding
        guard sticky else {
            guard rightAvailable < requiredSpace else { return .right }
            return leftAvailable > rightAvailable ? .left : .right
        }
        switch currentSide {
        case .right:
            guard rightAvailable < requiredSpace else { return .right }
            return leftAvailable > rightAvailable ? .left : .right
        case .left:
            guard leftAvailable < requiredSpace else { return .left }
            return rightAvailable > leftAvailable ? .right : .left
        }
    }
}

private struct SortAssistantFloatingEdgeOverflow: CustomStringConvertible {
    var left: CGFloat
    var right: CGFloat
    var bottom: CGFloat
    var top: CGFloat

    var amount: CGFloat {
        max(max(left, right), max(bottom, top))
    }

    var description: String {
        "left=\(left) right=\(right) bottom=\(bottom) top=\(top) max=\(amount)"
    }
}

@MainActor
final class SortAssistantFloatingPanelHostView: NSView {
    private struct DragSession {
        var startScreenPoint: CGPoint
        var startOrigin: CGPoint
    }

    private var childWindow: SortAssistantFloatingPanelWindow?
    private var hostingView: NSHostingView<SortAssistantFloatingPetContent>?
    private var observers: [NSObjectProtocol] = []
    private weak var observedParentWindow: NSWindow?
    private weak var attachedCoordinator: SortAssistantCoordinator?
    private var isPresented = false
    private var origin: CGPoint?
    private var lastResolvedScreenOrigin: CGPoint?
    // The effective bubble side used by the last applied frame. Tracked so the
    // panel origin can be re-anchored on the avatar slot when the effective side
    // changes (e.g. collapsing the bubble flips the effective side .left → .right
    // and shrinks the panel) without teleporting the sprite sideways.
    private var lastResolvedEffectiveSide: SortAssistantFloatingConversationBubbleSide?
    // Whether the conversation bubble was visible on the previous resolve pass.
    // A hidden → visible transition is treated as a fresh appearance, which
    // re-picks the best-fitting side; while the bubble stays open the side is
    // kept sticky.
    private var wasFloatingBubbleVisible = false
    private var dragSession: DragSession?
    private var hasUserPositioned = false
    private var lastLayoutRevision = -1
    private var lastFocusRevision = 0
    private var pendingFrameSync = false
    private var pendingFrameSyncPreserveExistingOrigin = true

    private let edgePadding: CGFloat = 12
    private let topPadding: CGFloat = WindowChromeMetrics.appTitlebarHeight + 14
    private let fallbackSize = NSSize(width: 404, height: 280)
    private let topOverlayReserveHeight = SortAssistantFloatingPetContent.topOverlayReserveHeight
    fileprivate var isPanelEdgeRecoveryActive: Bool {
        attachedCoordinator?.isPanelEdgeRecovery ?? false
    }
    fileprivate var isConversationBubbleVisibleForHitTesting: Bool {
        attachedCoordinator?.isFloatingConversationBubbleVisible ?? false
    }
    fileprivate var effectiveConversationBubbleSide: SortAssistantFloatingConversationBubbleSide {
        attachedCoordinator?.effectiveConversationBubbleSide ?? .right
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncVisibility(syncFrame: true)
    }

    func update(
        isPresented: Bool,
        layoutRevision: Int,
        focusRevision: Int,
        coordinator: SortAssistantCoordinator,
        tabManager: TabManager,
        workspaceTabStore: WorkspaceTabStore
    ) {
        let wasPresented = self.isPresented
        self.isPresented = isPresented
        attachedCoordinator = coordinator
        let layoutChanged = layoutRevision != lastLayoutRevision
        lastLayoutRevision = layoutRevision
        let shouldFocusInput = isPresented && focusRevision > 0 && focusRevision != lastFocusRevision
        if shouldFocusInput {
            lastFocusRevision = focusRevision
        }
#if DEBUG
        if layoutChanged {
            cmuxDebugLog("sprite.host layoutRevision=\(layoutRevision) isPresented=\(isPresented) userPositioned=\(hasUserPositioned) activeDrag=\(dragSession != nil)")
        }
#endif
        updateContent(
            coordinator: coordinator,
            tabManager: tabManager,
            workspaceTabStore: workspaceTabStore
        )
        syncVisibility(syncFrame: isPresented && !wasPresented)
        if layoutChanged {
            scheduleSyncChildFrame()
        }
        if shouldFocusInput {
            requestInputFocus(source: "focusRevision")
        }
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
        lastResolvedEffectiveSide = nil
        wasFloatingBubbleVisible = false
        dragSession = nil
        lastLayoutRevision = -1
        lastFocusRevision = 0
        pendingFrameSync = false
        pendingFrameSyncPreserveExistingOrigin = true
        attachedCoordinator?.setPanelEdgeRecovery(false)
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

    private func syncVisibility(syncFrame: Bool) {
        guard isPresented else {
            childWindow?.orderOut(nil)
            dragSession = nil
            return
        }
        guard let parentWindow = window else {
            tearDown()
            return
        }
        let didCreateChild = childWindow == nil
        let child = childWindow ?? makeChildWindow(parentWindow: parentWindow)
        let didAttachToParent = child.parent !== parentWindow
        if didAttachToParent {
            child.parent?.removeChildWindow(child)
            parentWindow.addChildWindow(child, ordered: .above)
            installParentWindowObservers(parentWindow)
        }
        child.orderFront(nil)
        if syncFrame || didCreateChild || didAttachToParent {
            scheduleSyncChildFrame()
        }
    }

    private func requestInputFocus(source: String) {
        focusInput(source: source, attempt: 0)
        DispatchQueue.main.async { [weak self] in
            self?.focusInput(source: source, attempt: 1)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.focusInput(source: source, attempt: 2)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.focusInput(source: source, attempt: 3)
        }
    }

    private func focusInput(source: String, attempt: Int) {
        guard isPresented,
              let childWindow,
              let contentView = childWindow.contentView,
              let input = findInputField(in: contentView) else {
#if DEBUG
            cmuxDebugLog("sprite.focus miss source=\(source) attempt=\(attempt) hasWindow=\(childWindow != nil)")
#endif
            return
        }

        childWindow.makeKeyAndOrderFront(nil)
        childWindow.orderFrontRegardless()
        let didFocus = childWindow.makeFirstResponder(input)
#if DEBUG
        let keyWindow = NSApp.keyWindow?.windowNumber ?? -1
        let firstResponder = childWindow.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        cmuxDebugLog("sprite.focus source=\(source) attempt=\(attempt) didFocus=\(didFocus ? 1 : 0) keyWindow=\(keyWindow) panel=\(childWindow.windowNumber) firstResponder=\(firstResponder)")
#endif
    }

    private func findInputField(in root: NSView) -> NSTextField? {
        if let field = root as? NSTextField,
           field.accessibilityIdentifier() == SortAssistantAccessibility.inputField {
            return field
        }
        for subview in root.subviews {
            if let field = findInputField(in: subview) {
                return field
            }
        }
        return nil
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
        panel.setAccessibilityIdentifier(SortAssistantAccessibility.floatingPanel)
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.identifier = NSUserInterfaceItemIdentifier("cmux.sortAssistantFloatingPet")
        if let hostingView {
            hostingView.setAccessibilityIdentifier(SortAssistantAccessibility.floatingPanel)
            panel.contentView = hostingView
        }
        parentWindow.addChildWindow(panel, ordered: .above)
        childWindow = panel
        installParentWindowObservers(parentWindow)
        return panel
    }

    private func scheduleSyncChildFrame(preserveExistingOrigin: Bool = true) {
        if pendingFrameSync {
            pendingFrameSyncPreserveExistingOrigin =
                pendingFrameSyncPreserveExistingOrigin && preserveExistingOrigin
            return
        }

        pendingFrameSync = true
        pendingFrameSyncPreserveExistingOrigin = preserveExistingOrigin
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let preserveExistingOrigin = self.pendingFrameSyncPreserveExistingOrigin
                self.pendingFrameSync = false
                self.pendingFrameSyncPreserveExistingOrigin = true
                self.syncChildFrame(preserveExistingOrigin: preserveExistingOrigin)
            }
        }
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
#if DEBUG
        if let previousFrame {
            cmuxDebugLog(
                "sprite.contentLayout measured preserve=\(preserveExistingOrigin) previous=\(previousFrame) fittingSize=\(size) sizeDelta=(\(size.width - previousFrame.width), \(size.height - previousFrame.height)) origin=\(String(describing: origin)) lastScreenOrigin=\(String(describing: lastResolvedScreenOrigin)) userPositioned=\(hasUserPositioned) activeDrag=\(dragSession != nil)"
            )
        } else {
            cmuxDebugLog(
                "sprite.contentLayout measured preserve=\(preserveExistingOrigin) previous=nil fittingSize=\(size) origin=\(String(describing: origin)) lastScreenOrigin=\(String(describing: lastResolvedScreenOrigin)) userPositioned=\(hasUserPositioned) activeDrag=\(dragSession != nil)"
            )
        }
#endif

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
            // Preserve the avatar's on-screen position across effective-side
            // changes. Collapsing the bubble flips the effective side
            // (.left → .right) and shrinks the panel, while expanding does the
            // reverse; the avatar slot's X offset changes with the side, so the
            // preserved panel origin must shift by that delta or the sprite
            // jumps sideways by the bubble width.
            let previousSide = lastResolvedEffectiveSide ?? effectiveConversationBubbleSide
            let newSide = effectiveConversationBubbleSide
            let avatarSlotShift =
                SortAssistantFloatingPanelMetrics.avatarVisualFrame(side: previousSide).minX
                - SortAssistantFloatingPanelMetrics.avatarVisualFrame(side: newSide).minX
            let anchoredScreenOrigin = CGPoint(
                x: preservedScreenOrigin.x + avatarSlotShift,
                y: preservedScreenOrigin.y
            )
            let desiredRectOnScreen = NSRect(origin: anchoredScreenOrigin, size: size)
            // Active drag must remain cursor-tracking. Other layout updates use
            // the recovery clamp so content growth can keep the panel's natural
            // size while the mini-sprite drag hotspot remains visible at the
            // recoverable screen edge.
            let rectOnScreen = resolveConversationBubbleSide(
                for: clampToCurrentLayoutMode(desiredRectOnScreen, relativeTo: parentWindow),
                relativeTo: parentWindow,
                source: "syncChildFrame.preserve"
            )
#if DEBUG
            let visibleFrame = automaticPanelVisibleFrame(for: rectOnScreen, parentWindow: parentWindow)
            cmuxDebugLog(
                "sprite.contentLayout resolved source=syncChildFrame.preserve previous=\(previousFrame) desired=\(desiredRectOnScreen) resolved=\(rectOnScreen) frameDelta=(\(rectOnScreen.minX - previousFrame.minX), \(rectOnScreen.minY - previousFrame.minY)) sizeDelta=(\(rectOnScreen.width - previousFrame.width), \(rectOnScreen.height - previousFrame.height)) visible=\(String(describing: visibleFrame)) userPositioned=\(hasUserPositioned) activeDrag=\(dragSession != nil)"
            )
#endif
            origin = originInContent(
                fromScreenRect: rectOnScreen,
                parentWindow: parentWindow,
                contentView: contentView
            )
            lastResolvedScreenOrigin = rectOnScreen.origin
            applyFrame(rectOnScreen, to: childWindow, hostingView: hostingView, source: "syncChildFrame.preserve")
            DispatchQueue.main.async { [weak self, weak childWindow] in
                guard let self,
                      let childWindow,
                      self.childWindow === childWindow,
                      self.lastResolvedScreenOrigin == rectOnScreen.origin else {
                    return
                }
                let desiredRect = NSRect(origin: rectOnScreen.origin, size: childWindow.frame.size)
                let rect = self.resolveConversationBubbleSide(
                    for: self.clampToCurrentLayoutMode(desiredRect, relativeTo: parentWindow),
                    relativeTo: parentWindow,
                    source: "syncChildFrame.async"
                )
#if DEBUG
                let visibleFrame = self.automaticPanelVisibleFrame(for: rect, parentWindow: parentWindow)
                cmuxDebugLog(
                    "sprite.contentLayout resolved source=syncChildFrame.async previous=\(childWindow.frame) desired=\(desiredRect) resolved=\(rect) frameDelta=(\(rect.minX - childWindow.frame.minX), \(rect.minY - childWindow.frame.minY)) sizeDelta=(\(rect.width - childWindow.frame.width), \(rect.height - childWindow.frame.height)) visible=\(String(describing: visibleFrame)) userPositioned=\(self.hasUserPositioned) activeDrag=\(self.dragSession != nil)"
                )
#endif
                self.applyFrame(rect, to: childWindow, hostingView: hostingView, source: "syncChildFrame.async")
            }
            return
        }

        repositionChildWindow(
            panelSize: size,
            clampToParentArea: !hasUserPositioned,
            clampToScreenArea: false,
            keepDragHotspotVisible: true,
            source: "syncChildFrame.reposition"
        )
    }

    private func repositionChildWindow(
        panelSize: NSSize? = nil,
        clampToParentArea: Bool = true,
        clampToScreenArea: Bool = true,
        keepDragHotspotVisible: Bool = false,
        preferredScreenPoint: CGPoint? = nil,
        source: String = "repositionChildWindow"
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
        var resolvedOrigin = clampToParentArea
            ? clampedOrigin(preferredOrigin, panelSize: positioningSize, in: containerSize)
            : preferredOrigin
        origin = resolvedOrigin
        var rectOnScreen = screenRect(
            originInContent: resolvedOrigin,
            positioningSize: positioningSize,
            panelSize: size,
            parentWindow: parentWindow,
            contentView: contentView
        )
        if clampToScreenArea {
            rectOnScreen = clampedScreenRect(
                rectOnScreen,
                relativeTo: parentWindow,
                preferredScreenPoint: preferredScreenPoint
            )
            resolvedOrigin = originInContent(
                fromScreenRect: rectOnScreen,
                parentWindow: parentWindow,
                contentView: contentView
            )
            origin = resolvedOrigin
        } else if keepDragHotspotVisible {
            rectOnScreen = manualDragScreenRect(
                rectOnScreen,
                relativeTo: parentWindow,
                preferredScreenPoint: preferredScreenPoint
            )
            resolvedOrigin = originInContent(
                fromScreenRect: rectOnScreen,
                parentWindow: parentWindow,
                contentView: contentView
            )
            origin = resolvedOrigin
        }
        rectOnScreen = resolveConversationBubbleSide(
            for: rectOnScreen,
            relativeTo: parentWindow,
            preferredScreenPoint: preferredScreenPoint,
            source: source
        )
        resolvedOrigin = originInContent(
            fromScreenRect: rectOnScreen,
            parentWindow: parentWindow,
            contentView: contentView
        )
        origin = resolvedOrigin
#if DEBUG
        let visibleFrame = automaticPanelVisibleFrame(for: rectOnScreen, parentWindow: parentWindow)
        cmuxDebugLog(
            "sprite.frameResolve source=\(source) preferredOrigin=\(preferredOrigin) resolvedOrigin=\(resolvedOrigin) panelSize=\(size) rect=\(rectOnScreen) visible=\(String(describing: visibleFrame)) bubbleSide=\(effectiveConversationBubbleSide.rawValue) clampParent=\(clampToParentArea) clampScreen=\(clampToScreenArea) keepHotspot=\(keepDragHotspotVisible) userPositioned=\(hasUserPositioned) activeDrag=\(dragSession != nil)"
        )
#endif
        lastResolvedScreenOrigin = rectOnScreen.origin
        applyFrame(rectOnScreen, to: childWindow, hostingView: hostingView, source: source)
    }

    private func applyFrame(
        _ rectOnScreen: NSRect,
        to childWindow: SortAssistantFloatingPanelWindow,
        hostingView: NSHostingView<SortAssistantFloatingPetContent>,
        source: String
    ) {
        let previousWindowFrame = childWindow.frame
        let previousHostingFrame = hostingView.frame
        let contentFrame = NSRect(origin: .zero, size: rectOnScreen.size)
        if hostingView.frame != contentFrame {
            hostingView.frame = contentFrame
        }
        if childWindow.frame != rectOnScreen {
            childWindow.setFrame(rectOnScreen, display: true)
        }
        lastResolvedEffectiveSide = effectiveConversationBubbleSide
#if DEBUG
        if previousWindowFrame != rectOnScreen || previousHostingFrame != contentFrame {
            cmuxDebugLog(
                "sprite.applyFrame source=\(source) previousWindow=\(previousWindowFrame) newWindow=\(rectOnScreen) previousHost=\(previousHostingFrame) newHost=\(contentFrame) windowDelta=(\(rectOnScreen.minX - previousWindowFrame.minX), \(rectOnScreen.minY - previousWindowFrame.minY), \(rectOnScreen.width - previousWindowFrame.width), \(rectOnScreen.height - previousWindowFrame.height)) userPositioned=\(hasUserPositioned) activeDrag=\(dragSession != nil)"
            )
        }
#endif
        updatePanelEdgeRecoveryState(for: rectOnScreen, source: source)
    }

    // Drive the coordinator's `isPanelEdgeRecovery` flag so the SwiftUI content
    // can swap the full avatar for the edge mini-sprite. User drags are still
    // free to move the panel outside the parent window. Panel-only overflow is
    // logged for diagnosis but must not trigger mini mode. The cmux parent
    // window/content viewport is also not a boundary; only the physical display
    // visible frame can trigger edge recovery.
    private func updatePanelEdgeRecoveryState(for rectOnScreen: NSRect, source: String) {
        let bubbleSide = effectiveConversationBubbleSide
        let avatarSpriteOnScreen = SortAssistantFloatingPanelScreenClamp.hotspotRect(
            in: rectOnScreen,
            hotspot: SortAssistantFloatingPanelMetrics.avatarVisualFrame(side: bubbleSide)
        )
        let avatarHotspotOnScreen = SortAssistantFloatingPanelScreenClamp.hotspotRect(
            in: rectOnScreen,
            hotspot: SortAssistantFloatingPanelMetrics.avatarDragHotspot(side: bubbleSide)
        )
        guard let parentWindow = window else {
#if DEBUG
            cmuxDebugLog("sprite.edgeRecovery source=\(source) rect=\(rectOnScreen) avatarHotspot=\(avatarHotspotOnScreen) visibleFrame=nil → false")
#endif
            attachedCoordinator?.setPanelEdgeRecovery(false)
            return
        }
        let visibleFrames = SortAssistantVisibleScreenRange.currentVisibleFrames()
        guard let referenceFrame = edgeRecoveryReferenceFrame(
            for: avatarSpriteOnScreen,
            parentWindow: parentWindow,
            visibleFrames: visibleFrames
        ) else {
#if DEBUG
            cmuxDebugLog("sprite.edgeRecovery source=\(source) rect=\(rectOnScreen) avatarHotspot=\(avatarHotspotOnScreen) visibleFrames=[] → false")
#endif
            attachedCoordinator?.setPanelEdgeRecovery(false)
            return
        }
        let recoveryHotspotOnScreen = SortAssistantFloatingPanelScreenClamp.hotspotRect(
            in: rectOnScreen,
            hotspot: SortAssistantFloatingPanelMetrics.avatarDragRecoveryHotspot(side: bubbleSide)
        )
        let panelEdges = overflowEdges(of: rectOnScreen, outside: referenceFrame)
        let spriteEdges = overflowEdges(of: avatarSpriteOnScreen, outside: referenceFrame)
        let hotspotEdges = overflowEdges(of: avatarHotspotOnScreen, outside: referenceFrame)
        let recoveryEdges = overflowEdges(of: recoveryHotspotOnScreen, outside: referenceFrame)
        let parentFrame = parentContentReferenceFrame(parentWindow: parentWindow)
        let parentPanelEdges = parentFrame.map {
            overflowEdges(of: rectOnScreen, outside: $0)
        }
        let parentSpriteEdges = parentFrame.map {
            overflowEdges(of: avatarSpriteOnScreen, outside: $0)
        }
        let parentHotspotEdges = parentFrame.map {
            overflowEdges(of: avatarHotspotOnScreen, outside: $0)
        }
        let parentRecoveryEdges = parentFrame.map {
            overflowEdges(of: recoveryHotspotOnScreen, outside: $0)
        }
        let overflowThreshold = SortAssistantFloatingPanelMetrics.spriteEdgeRecoveryOverflowThreshold
        let isSpriteVisibleOnAnyScreen = SortAssistantVisibleScreenRange.isFullyVisible(
            avatarSpriteOnScreen,
            visibleFrames: visibleFrames,
            tolerance: overflowThreshold
        )
        let shouldRecover = !isSpriteVisibleOnAnyScreen
        let decisionReason: String
        if shouldRecover {
            decisionReason = "screenSpriteOverflow"
        } else {
            decisionReason = "none"
        }
#if DEBUG
        attachedCoordinator?.recordSpriteGeometryDebugSnapshot(
            source: source,
            frame: rectOnScreen,
            avatarSprite: avatarSpriteOnScreen,
            avatarHotspot: avatarHotspotOnScreen,
            recoveryHotspot: recoveryHotspotOnScreen,
            visibleFrames: visibleFrames,
            isAvatarSpriteVisibleOnScreen: isSpriteVisibleOnAnyScreen,
            edgeRecovery: shouldRecover
        )
        cmuxDebugLog("sprite.edgeRecovery source=\(source) rect=\(rectOnScreen) avatarSprite=\(avatarSpriteOnScreen) avatarHotspot=\(avatarHotspotOnScreen) recoveryHotspot=\(recoveryHotspotOnScreen) reference=\(referenceFrame) visibleFrames=\(SortAssistantVisibleScreenRange.debugDescription(for: visibleFrames)) parentReference=\(String(describing: parentFrame)) panelEdges={\(panelEdges)} spriteEdges={\(spriteEdges)} hotspotEdges={\(hotspotEdges)} recoveryEdges={\(recoveryEdges)} parentPanelEdges={\(String(describing: parentPanelEdges))} parentSpriteEdges={\(String(describing: parentSpriteEdges))} parentHotspotEdges={\(String(describing: parentHotspotEdges))} parentRecoveryEdges={\(String(describing: parentRecoveryEdges))} spriteVisibleOnScreen=\(isSpriteVisibleOnAnyScreen) spriteThreshold=\(overflowThreshold) decision=\(decisionReason) → \(shouldRecover)")
#endif
        attachedCoordinator?.setPanelEdgeRecovery(shouldRecover)
    }

    private func edgeRecoveryReferenceFrame(
        for rect: NSRect,
        parentWindow: NSWindow,
        visibleFrames: [NSRect]
    ) -> NSRect? {
        automaticPanelVisibleFrame(
            for: rect,
            parentWindow: parentWindow,
            visibleFrames: visibleFrames
        )
    }

    private func parentContentReferenceFrame(parentWindow: NSWindow) -> NSRect? {
        guard let contentView = parentWindow.contentView else { return nil }
        let contentRectInWindow = contentView.convert(contentView.bounds, to: nil)
        let contentRectOnScreen = parentWindow.convertToScreen(contentRectInWindow)
        guard !contentRectOnScreen.isNull,
              contentRectOnScreen.width > 0,
              contentRectOnScreen.height > 0 else {
            return nil
        }
        return contentRectOnScreen
    }

    private func overflowEdges(of rect: NSRect, outside frame: NSRect) -> SortAssistantFloatingEdgeOverflow {
        SortAssistantFloatingEdgeOverflow(
            left: max(0, frame.minX - rect.minX),
            right: max(0, rect.maxX - frame.maxX),
            bottom: max(0, frame.minY - rect.minY),
            top: max(0, rect.maxY - frame.maxY)
        )
    }

    private func resolveConversationBubbleSide(
        for rect: NSRect,
        relativeTo parentWindow: NSWindow,
        preferredScreenPoint: CGPoint? = nil,
        source: String
    ) -> NSRect {
        guard let coordinator = attachedCoordinator else {
            wasFloatingBubbleVisible = false
            return rect
        }
        let bubbleVisible = coordinator.isFloatingConversationBubbleVisible
        guard bubbleVisible, dragSession == nil else {
            // A live drag keeps the bubble visible, so only a genuine hide should
            // arm the next fresh-appearance re-pick. Dragging must not be treated
            // as a disappearance.
            if !bubbleVisible {
                wasFloatingBubbleVisible = false
            }
            return rect
        }
        // First resolve after the bubble (re-)appears: pick the best-fitting side
        // fresh ("下次精灵出来"). While the bubble stays open, keep the side sticky.
        let isFreshAppearance = !wasFloatingBubbleVisible
        wasFloatingBubbleVisible = true

        let currentSide = coordinator.effectiveConversationBubbleSide
        let currentAvatarFrame = SortAssistantFloatingPanelMetrics.avatarVisualFrame(side: currentSide)
        let avatarOnScreen = SortAssistantFloatingPanelScreenClamp.hotspotRect(
            in: rect,
            hotspot: currentAvatarFrame
        )
        guard let visibleFrame = automaticPanelVisibleFrame(
            for: avatarOnScreen,
            parentWindow: parentWindow,
            preferredScreenPoint: preferredScreenPoint
        ) else {
            return rect
        }

        let preferredSide = preferredConversationBubbleSide(
            currentSide: currentSide,
            avatarOnScreen: avatarOnScreen,
            visibleFrame: visibleFrame,
            sticky: !isFreshAppearance
        )
        guard preferredSide != coordinator.conversationBubbleSide else {
            return rect
        }

        let preferredAvatarFrame = SortAssistantFloatingPanelMetrics.avatarVisualFrame(side: preferredSide)
        var resolved = rect
        resolved.origin.x += currentAvatarFrame.minX - preferredAvatarFrame.minX
        coordinator.setConversationBubbleSide(preferredSide, reason: source)
        resolved = manualDragScreenRect(
            resolved,
            relativeTo: parentWindow,
            preferredScreenPoint: preferredScreenPoint
        )
#if DEBUG
        cmuxDebugLog(
            "sprite.bubbleSide source=\(source) fresh=\(isFreshAppearance ? 1 : 0) current=\(currentSide.rawValue) preferred=\(preferredSide.rawValue) avatar=\(avatarOnScreen) visible=\(visibleFrame) before=\(rect) after=\(resolved)"
        )
#endif
        return resolved
    }

    private func preferredConversationBubbleSide(
        currentSide: SortAssistantFloatingConversationBubbleSide,
        avatarOnScreen: NSRect,
        visibleFrame: NSRect,
        sticky: Bool
    ) -> SortAssistantFloatingConversationBubbleSide {
        SortAssistantFloatingPanelMetrics.resolvedConversationBubbleSide(
            currentSide: currentSide,
            avatarOnScreen: avatarOnScreen,
            visibleFrame: visibleFrame,
            edgePadding: edgePadding,
            sticky: sticky
        )
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

    private func screenRect(
        originInContent: CGPoint,
        positioningSize: NSSize,
        panelSize: NSSize,
        parentWindow: NSWindow,
        contentView: NSView
    ) -> NSRect {
        let anchorRectInContent = NSRect(origin: originInContent, size: positioningSize)
        let anchorRectInWindow = contentView.convert(anchorRectInContent, to: nil)
        let anchorRectOnScreen = parentWindow.convertToScreen(anchorRectInWindow)
        return NSRect(origin: anchorRectOnScreen.origin, size: panelSize)
    }

    // Inverse of screenRect for the panel's anchor origin. The forward function
    // anchors a positioning-sized rect (visible content, height = panelH - topReserve)
    // at originInContent and returns a rect with the FULL panelSize. When the
    // parent window's contentView is flipped (cmux's main window uses
    // NSHostingView, which is flipped), reversing the full-panelSize rect via
    // contentView.convert(_:from:) loses topReserve pixels of Y because the flip
    // is anchored to the rect's height. The correct inverse must reverse the
    // same positioning-sized anchor, not the full panel.
    private func originInContent(
        fromScreenRect rectOnScreen: NSRect,
        parentWindow: NSWindow,
        contentView: NSView
    ) -> CGPoint {
        let anchorOnScreen = NSRect(
            origin: rectOnScreen.origin,
            size: positioningSize(for: rectOnScreen.size)
        )
        let anchorInWindow = parentWindow.convertFromScreen(anchorOnScreen)
        let anchorInContent = contentView.convert(anchorInWindow, from: nil)
        return anchorInContent.origin
    }

    private func clampedScreenRect(
        _ rect: NSRect,
        relativeTo parentWindow: NSWindow,
        preferredScreenPoint: CGPoint? = nil
    ) -> NSRect {
        guard let visibleFrame = automaticPanelVisibleFrame(
            for: rect,
            parentWindow: parentWindow,
            preferredScreenPoint: preferredScreenPoint
        ) else {
            return rect
        }
        return SortAssistantFloatingPanelScreenClamp.resolvedRect(
            rect,
            visibleFrame: visibleFrame,
            edgePadding: edgePadding,
            mode: .constrained
        )
    }

    // Resolves the on-screen clamp for `rect`. During a live drag, leave the
    // rect unchanged. Otherwise, use the recovery-hotspot clamp so the panel
    // keeps its natural size and is allowed to extend off-screen, with only
    // the configured avatar hotspot pinned to the visible screen frame as a
    // draggable handle. This applies to both user-positioned and auto-positioned
    // panels: when the conversation auto-grows and would push the sprite past a
    // screen edge, we'd rather let the bubble extend out (the 窗边小精灵
    // mini-sprite stays on the recoverable edge) than shrink the bubble to fit.
    private func clampToCurrentLayoutMode(
        _ rect: NSRect,
        relativeTo parentWindow: NSWindow
    ) -> NSRect {
        if dragSession != nil {
#if DEBUG
            cmuxDebugLog("sprite.clamp.skip reason=activeDrag rect=\(rect) edgeRecovery=\(isPanelEdgeRecoveryActive)")
#endif
            return rect
        }
        return manualDragScreenRect(rect, relativeTo: parentWindow)
    }

    private func manualDragScreenRect(
        _ rect: NSRect,
        relativeTo parentWindow: NSWindow,
        preferredScreenPoint: CGPoint? = nil
    ) -> NSRect {
        let hotspotRect = SortAssistantFloatingPanelScreenClamp.hotspotRect(
            in: rect,
            hotspot: SortAssistantFloatingPanelMetrics.avatarDragRecoveryHotspot(side: effectiveConversationBubbleSide)
        )
        guard let visibleFrame = automaticPanelVisibleFrame(
            for: hotspotRect,
            parentWindow: parentWindow,
            preferredScreenPoint: preferredScreenPoint
        ) else {
#if DEBUG
            cmuxDebugLog("sprite.clamp.manual visibleFrame=nil requested=\(rect) recoveryHotspot=\(hotspotRect) preferredScreenPoint=\(String(describing: preferredScreenPoint))")
#endif
            return rect
        }
        let resolved = SortAssistantFloatingPanelScreenClamp.resolvedRect(
            rect,
            visibleFrame: visibleFrame,
            edgePadding: edgePadding,
            mode: .manualDrag(
                hotspot: SortAssistantFloatingPanelMetrics.avatarDragRecoveryHotspot(side: effectiveConversationBubbleSide),
                minimumVisibleSize: SortAssistantFloatingPanelMetrics.minimumVisibleDragHotspotSize
            )
        )
#if DEBUG
        let resolvedHotspot = SortAssistantFloatingPanelScreenClamp.hotspotRect(
            in: resolved,
            hotspot: SortAssistantFloatingPanelMetrics.avatarDragRecoveryHotspot(side: effectiveConversationBubbleSide)
        )
        cmuxDebugLog(
            "sprite.clamp.manual requested=\(rect) visible=\(visibleFrame) recoveryHotspotBefore=\(hotspotRect) visibleBefore=\(hotspotRect.intersection(visibleFrame)) resolved=\(resolved) recoveryHotspotAfter=\(resolvedHotspot) visibleAfter=\(resolvedHotspot.intersection(visibleFrame)) minVisible=\(SortAssistantFloatingPanelMetrics.minimumVisibleDragHotspotSize) preferredScreenPoint=\(String(describing: preferredScreenPoint))"
        )
#endif
        return resolved
    }

    private func automaticPanelVisibleFrame(
        for rect: NSRect,
        parentWindow: NSWindow,
        preferredScreenPoint: CGPoint? = nil,
        visibleFrames: [NSRect] = SortAssistantVisibleScreenRange.currentVisibleFrames()
    ) -> NSRect? {
        if let selected = SortAssistantVisibleScreenRange.selectedVisibleFrame(
            for: rect,
            preferredScreenPoint: preferredScreenPoint,
            visibleFrames: visibleFrames
        ) {
            return selected
        }
        return parentWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
    }

    func beginDrag(screenPoint: CGPoint) {
        guard let parentWindow = window,
              let contentView = parentWindow.contentView,
              let hostingView else { return }
        let size = hostingView.frame.size == .zero ? fallbackSize : hostingView.frame.size
        let positioningSize = positioningSize(for: size)
        let startOrigin: CGPoint
        if let childWindow {
            startOrigin = originInContent(
                fromScreenRect: childWindow.frame,
                parentWindow: parentWindow,
                contentView: contentView
            )
            origin = startOrigin
            lastResolvedScreenOrigin = childWindow.frame.origin
        } else {
            startOrigin = origin ?? defaultOrigin(panelSize: positioningSize, in: contentView.bounds.size)
        }
        hasUserPositioned = true
        dragSession = DragSession(
            startScreenPoint: screenPoint,
            startOrigin: startOrigin
        )
#if DEBUG
        cmuxDebugLog(
            "sprite.drag begin screenPoint=\(screenPoint) startOrigin=\(startOrigin) frame=\(String(describing: childWindow?.frame)) size=\(size)"
        )
#endif
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
        repositionChildWindow(
            panelSize: size,
            clampToParentArea: false,
            clampToScreenArea: false,
            source: "drag.update"
        )
    }

    func endDrag() {
        let finalFrame = childWindow?.frame
#if DEBUG
        cmuxDebugLog(
            "sprite.drag end frame=\(String(describing: finalFrame)) origin=\(String(describing: origin)) lastScreenOrigin=\(String(describing: lastResolvedScreenOrigin))"
        )
#endif
        dragSession = nil
        if childWindow != nil,
           let size = childWindow?.frame.size {
            repositionChildWindow(
                panelSize: size,
                clampToParentArea: false,
                clampToScreenArea: false,
                keepDragHotspotVisible: true,
                source: "drag.end"
            )
        } else if let finalFrame {
            updatePanelEdgeRecoveryState(for: finalFrame, source: "drag.end")
        }
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
                    self.repositionChildWindow(
                        clampToParentArea: !self.hasUserPositioned,
                        clampToScreenArea: false,
                        keepDragHotspotVisible: true,
                        source: "parentWindow.\(name.rawValue)"
                    )
                }
            }
        }
        observers.append(
            center.addObserver(forName: NSWindow.didResizeNotification, object: parentWindow, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.scheduleSyncChildFrame(preserveExistingOrigin: false)
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

    private let conversationWidth = SortAssistantFloatingPanelMetrics.conversationWidth
    private let avatarSize = SortAssistantFloatingPanelMetrics.avatarSize
    private let avatarBottomPadding = SortAssistantFloatingPanelMetrics.avatarBottomPadding
    private let connectorSize = SortAssistantFloatingPanelMetrics.connectorSize
    private let widgetSpacing = SortAssistantFloatingPanelMetrics.widgetSpacing

    var body: some View {
        let isBubbleVisible = coordinator.isConversationBubblePresented && !coordinator.isPanelEdgeRecovery
        let bubbleSide = coordinator.effectiveConversationBubbleSide
        VStack(spacing: 0) {
            if isBubbleVisible {
                Color.clear
                    .frame(height: Self.topOverlayReserveHeight)
                    .allowsHitTesting(false)
            }
            HStack(alignment: .bottom, spacing: widgetSpacing) {
                if isBubbleVisible && bubbleSide == .left {
                    conversationBubble(side: bubbleSide)
                        .transition(.opacity)
                }
                mascot
                if isBubbleVisible && bubbleSide == .right {
                    conversationBubble(side: bubbleSide)
                        .transition(.opacity)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(SortAssistantAccessibility.floatingPanel)
#if DEBUG
        .onAppear {
            cmuxDebugLog("sprite.render appear bubble=\(coordinator.isConversationBubblePresented) edgeRecovery=\(coordinator.isPanelEdgeRecovery) color=\(String(describing: coordinator.spriteColor))")
        }
        .onChange(of: coordinator.isPanelEdgeRecovery) { _, active in
            cmuxDebugLog("sprite.render edgeRecovery=\(active) bubble=\(coordinator.isConversationBubblePresented) color=\(String(describing: coordinator.spriteColor))")
        }
        .onChange(of: coordinator.isConversationBubblePresented) { _, active in
            cmuxDebugLog("sprite.render bubble=\(active) edgeRecovery=\(coordinator.isPanelEdgeRecovery) color=\(String(describing: coordinator.spriteColor))")
        }
#endif
    }

    private var mascot: some View {
        ZStack {
            // 窗边小精灵: shown only when the visible avatar sprite leaves the
            // physical display visible frame (driven by
            // `SortAssistantCoordinator.isPanelEdgeRecovery` from the host
            // view). When visible it sits centered inside the 56×56 avatar slot
            // so it lands on top of the visible recovery hotspot at the
            // screen edge.
            if coordinator.isPanelEdgeRecovery {
                Button {
                    coordinator.toggleConversationBubble(reason: "floatingMascot")
                } label: {
                    recoveryMiniSprite
                        .frame(width: avatarSize, height: avatarSize)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "sortAssistant.mascot.open", defaultValue: "Open sort assistant"))
                .help(String(localized: "sortAssistant.mascot.open", defaultValue: "Open sort assistant"))
            } else {
                SortAssistantMascotButton(
                    presentation: .floating,
                    isActive: coordinator.isSorting,
                    state: coordinator.mascotState,
                    attentionBadgeCount: coordinator.proactiveAttentionCount,
                    action: {
                        coordinator.toggleConversationBubble(reason: "floatingMascot")
                    }
                )
            }
        }
        .padding(.bottom, avatarBottomPadding)
    }

    // 窗边小精灵 — a mini-sprite that lives behind the full-size avatar at the
    // avatar's center. The center coincides with `avatarDragRecoveryHotspot`'s
    // center, so when the floating panel is pushed out of the screen visible
    // frame and only that recovery hotspot remains visible (via the
    // `keepDragHotspotVisible` clamp in `repositionChildWindow`), this mini
    // sprite is the user-visible piece left at the recovery edge. The sprite
    // animation is `.failed` because row 5 of the universal sprite sheet is the
    // only one whose frames are drawn in a lying-down pose — the visual closest
    // to "趴在屏幕边缘" (lying at the screen edge). The state is used purely as a
    // pose; it does NOT signal a failure in the sprite workflow.
    private var recoveryMiniSprite: some View {
        let diameter = SortAssistantFloatingPanelMetrics.recoveryMiniSpriteDiameter
        return ZStack {
            Circle()
                .fill(Color(nsColor: coordinator.spriteColor ?? defaultMiniSpriteFill))
                .overlay(
                    Circle().stroke(Color.black.opacity(0.35), lineWidth: 1)
                )
            SortAssistantMascotAvatar(
                size: diameter * 0.95,
                isActive: false,
                state: .failed
            )
        }
        .frame(width: diameter, height: diameter)
        .allowsHitTesting(false)
    }

    private var defaultMiniSpriteFill: NSColor {
        NSColor.controlBackgroundColor
    }

    private var compactAutoBubble: some View {
        let suggestion = coordinator.compactAutoBubbleSuggestion
        return Button {
            coordinator.openEntry()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(suggestion?.title ?? String(
                    localized: "sortAssistant.autoBubble.fallbackTitle",
                    defaultValue: "Something needs your attention"
                ))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                if let reason = suggestion?.reason, !reason.isEmpty {
                    Text(reason)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(String(localized: "sortAssistant.autoBubble.openHint", defaultValue: "Tap to open"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("SortAssistantAutoBubble")
    }

    private func conversationBubble(side: SortAssistantFloatingConversationBubbleSide) -> some View {
        Group {
            if coordinator.isCompactAutoBubble {
                compactAutoBubble
            } else {
                SortAssistantThreadView(
                    coordinator: coordinator,
                    tabManager: tabManager,
                    workspaceTabStore: workspaceTabStore,
                    showsHeader: false,
                    showsAssistantMessageAvatar: false,
                    completionLayout: .overlay
                )
            }
        }
        .frame(width: conversationWidth, alignment: .topLeading)
        .background(alignment: .bottomTrailing) {
            conversationShadow
        }
        .background(conversationFill)
        .overlay(conversationOuterBorder)
        .overlay(conversationInnerHighlight)
        .overlay(conversationInnerLowlight)
        .overlay(alignment: .topLeading) {
            conversationConnectorOverlay(side: side)
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

    private func conversationConnectorOverlay(side: SortAssistantFloatingConversationBubbleSide) -> some View {
        GeometryReader { proxy in
            conversationConnector
                .scaleEffect(x: side == .left ? -1 : 1, y: 1, anchor: .center)
                .offset(
                    x: side == .left ? 12 : -12,
                    y: connectorTopOffset(forBubbleHeight: proxy.size.height)
                )
                .frame(
                    width: proxy.size.width,
                    height: proxy.size.height,
                    alignment: side == .left ? .topTrailing : .topLeading
                )
        }
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
    private let dragThresholdSquared: CGFloat = 9

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    // NSWindow's default constrainFrameRect keeps the titlebar visible by
    // snapping the frame to the screen's visible area. For the floating sprite
    // panel that snap actively fights the mouse drag — when the cursor pushes
    // the panel up to (or past) the visible-frame top, the constraint pulls
    // the panel back by a pixel and the cursor detaches from the avatar.
    // The sprite panel is borderless, has no titlebar to keep visible, and is
    // already responsible for its own on-screen logic via clampedScreenRect,
    // so the default constraint must be bypassed here.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            let point = event.locationInWindow
            let inHotspot = isInAvatarDragHotspot(point)
            let interactive = isInInteractiveHitRegion(point)
#if DEBUG
            cmuxDebugLog(
                "sprite.mouse leftDown point=\(point) screenPoint=\(currentMouseScreenPoint()) frame=\(frame) edgeRecovery=\(dragOwner?.isPanelEdgeRecoveryActive == true) inHotspot=\(inHotspot) interactive=\(interactive)"
            )
#endif
            guard interactive else {
                isForwardingMouseEventsToParent = true
                forwardMouseEventToParent(event)
                return
            }
            pendingDragStartPoint = inHotspot ? point : nil
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
#if DEBUG
                cmuxDebugLog(
                    "sprite.mouse dragStart start=\(start) current=\(current) screenPoint=\(currentMouseScreenPoint()) frame=\(frame) edgeRecovery=\(dragOwner?.isPanelEdgeRecoveryActive == true)"
                )
#endif
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
        let side = dragOwner?.effectiveConversationBubbleSide ?? .right
        let rect = dragOwner?.isPanelEdgeRecoveryActive == true
            ? SortAssistantFloatingPanelMetrics.avatarDragRecoveryHotspot(side: side)
            : SortAssistantFloatingPanelMetrics.avatarDragHotspot(side: side)
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
        if dragOwner?.isPanelEdgeRecoveryActive == true {
            return false
        }
        guard dragOwner?.isConversationBubbleVisibleForHitTesting == true else {
            return false
        }
        let bounds = contentView?.bounds ?? NSRect(origin: .zero, size: frame.size)
        let bubbleFrame = SortAssistantFloatingPanelMetrics.conversationBubbleHitFrame(
            side: dragOwner?.effectiveConversationBubbleSide ?? .right,
            in: bounds
        )
        return bubbleFrame.contains(point)
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

#if DEBUG
extension SortAssistantFloatingPanelHostView {
    var debugChildPanelScreenFrame: NSRect? { childWindow?.frame }
    var debugHasActiveDragSession: Bool { dragSession != nil }
    func debugSetUserPositioned(_ value: Bool) { hasUserPositioned = value }
}
#endif

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
