import AppKit
import SwiftUI

@MainActor
final class SortAssistantMessageScrollController: ObservableObject {
    private weak var scrollView: NSScrollView?
    private let lineStep: CGFloat = 42

    func attach(scrollView: NSScrollView?) {
        self.scrollView = scrollView
    }

    @discardableResult
    func scroll(direction: Int) -> Bool {
        guard direction != 0,
              let scrollView,
              let documentView = scrollView.documentView else {
            return false
        }

        let clipView = scrollView.contentView
        let maxOriginY = max(0, documentView.bounds.height - clipView.bounds.height)
        guard maxOriginY > 0 else { return false }

        let directionMultiplier: CGFloat = direction > 0 ? 1 : -1
        let flippedMultiplier: CGFloat = documentView.isFlipped ? 1 : -1
        let currentY = clipView.bounds.origin.y
        let targetY = min(max(currentY + directionMultiplier * flippedMultiplier * lineStep, 0), maxOriginY)
        guard abs(targetY - currentY) > 0.01 else { return false }

        clipView.scroll(to: CGPoint(x: clipView.bounds.origin.x, y: targetY))
        scrollView.reflectScrolledClipView(clipView)
        return true
    }
}

struct SortAssistantScrollViewResolver: NSViewRepresentable {
    let onResolve: (NSScrollView?) -> Void

    func makeNSView(context: Context) -> SortAssistantScrollViewResolverView {
        let view = SortAssistantScrollViewResolverView()
        view.onResolve = onResolve
        return view
    }

    func updateNSView(_ nsView: SortAssistantScrollViewResolverView, context: Context) {
        nsView.onResolve = onResolve
        nsView.resolveSoon()
    }
}

final class SortAssistantScrollViewResolverView: NSView {
    var onResolve: ((NSScrollView?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resolveSoon()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        resolveSoon()
    }

    func resolveSoon() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onResolve?(self.enclosingScrollView)
        }
    }
}

enum SortAssistantMessageCollapseRules {
    static let lineLimit = 6

    static func isCollapsible(_ message: SortAssistantMessage) -> Bool {
        guard message.kind == .assistant || message.kind == .warning || message.kind == .error else { return false }
        return message.text.count > 260 ||
            message.text.filter { $0 == "\n" }.count + 1 > lineLimit
    }
}

struct SortAssistantMessageRow: View {
    let message: SortAssistantMessage
    var showsAssistantAvatar = true
    let isExpanded: Bool
    let isKeyboardFocused: Bool
    let onToggleExpanded: () -> Void

    @State private var copied = false
    @State private var copyFeedbackToken: UUID?

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
                    .lineLimit(isMessageExpanded ? nil : SortAssistantMessageCollapseRules.lineLimit)
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
                            onToggleExpanded()
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
                .stroke(
                    isKeyboardFocused ? Color.accentColor.opacity(0.78) : stroke,
                    lineWidth: isKeyboardFocused ? 1 : (message.kind == .assistant ? 0 : 1)
                )
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
        message.kind == .assistant || message.kind == .warning || message.kind == .error
    }

    private var showsExpandButton: Bool {
        SortAssistantMessageCollapseRules.isCollapsible(message)
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
        switch message.kind {
        case .error:
            return Color.red
        case .warning:
            return Color.orange
        case .user, .assistant, .progress:
            return Color.primary
        }
    }

    private var avatarState: SortAssistantMascotState {
        switch message.kind {
        case .progress:
            return .review
        case .warning:
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
        case .warning:
            return Color.orange.opacity(0.075)
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
        case .warning:
            return Color.orange.opacity(0.16)
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
