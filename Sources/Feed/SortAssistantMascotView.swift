import SwiftUI

struct SortAssistantMascotButton: View {
    enum Presentation {
        case modeBar
        case threadHeader
        case intro
        case floating

        var size: CGFloat {
            switch self {
            case .modeBar: return 24
            case .threadHeader: return 26
            case .intro: return 42
            case .floating: return 56
            }
        }
    }

    let presentation: Presentation
    let isActive: Bool
    let action: () -> Void

    @State private var isHovered = false
    @State private var bobbing = false

    var body: some View {
        Button(action: action) {
            SortAssistantMascotView(
                size: presentation.size,
                isActive: isActive,
                isHovered: isHovered,
                bobbing: bobbing
            )
            .padding(presentation == .modeBar ? 2 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "sortAssistant.mascot.open", defaultValue: "Open sort assistant"))
        .help(String(localized: "sortAssistant.mascot.open", defaultValue: "Open sort assistant"))
        .onHover { isHovered = $0 }
        .onAppear {
            startAnimation()
        }
    }

    private func startAnimation() {
        guard !bobbing else { return }
        withAnimation(.easeInOut(duration: 1.45).repeatForever(autoreverses: true)) {
            bobbing = true
        }
    }
}

struct SortAssistantMascotIntroView: View {
    let isSorting: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            SortAssistantMascotButton(
                presentation: .intro,
                isActive: isSorting,
                action: action
            )

            Text(String(localized: "sortAssistant.mascot.prompt", defaultValue: "What should move up in the workspace order?"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary.opacity(0.88))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.055))
                )
                .overlay(alignment: .leading) {
                    SpeechBubbleTail()
                        .fill(Color.primary.opacity(0.055))
                        .frame(width: 8, height: 10)
                        .offset(x: -5)
                }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SortAssistantMascotAvatar: View {
    let size: CGFloat
    var isActive: Bool = false

    var body: some View {
        SortAssistantMascotView(
            size: size,
            isActive: isActive,
            isHovered: false,
            bobbing: false
        )
        .accessibilityHidden(true)
    }
}

private struct SortAssistantMascotView: View {
    let size: CGFloat
    let isActive: Bool
    let isHovered: Bool
    let bobbing: Bool

    private enum SpriteState {
        case idle
        case waving
        case review

        var row: Int {
            switch self {
            case .idle: return 0
            case .waving: return 3
            case .review: return 8
            }
        }

        var frames: Int {
            switch self {
            case .idle: return 6
            case .waving: return 4
            case .review: return 6
            }
        }

        var duration: TimeInterval {
            switch self {
            case .idle: return 5.5
            case .waving: return 0.7
            case .review: return 1.03
            }
        }
    }

    private static let frameWidth: CGFloat = 192
    private static let frameHeight: CGFloat = 208
    private static let columns: CGFloat = 8
    private static let rows: CGFloat = 9

    private var spriteState: SpriteState {
        if isActive { return .review }
        if isHovered { return .waving }
        return .idle
    }

    private var spriteWidth: CGFloat {
        size * 0.84
    }

    private var spriteHeight: CGFloat {
        spriteWidth * Self.frameHeight / Self.frameWidth
    }

    private var lift: CGFloat {
        if isHovered { return -2 }
        return bobbing ? -1.5 : 1
    }

    var body: some View {
        let state = spriteState
        ZStack {
            shadow
            TimelineView(.animation(minimumInterval: state.duration / Double(state.frames))) { context in
                sprite(state: state, frame: frameIndex(state: state, at: context.date))
            }
                .offset(y: lift)
        }
        .frame(width: size, height: size)
        .animation(.easeInOut(duration: 0.18), value: isHovered)
    }

    private var shadow: some View {
        Ellipse()
            .fill(Color.black.opacity(0.14))
            .frame(width: size * 0.58, height: size * 0.12)
            .offset(y: size * 0.37)
            .scaleEffect(x: bobbing ? 0.9 : 1.05, y: 1, anchor: .center)
    }

    private func sprite(state: SpriteState, frame: Int) -> some View {
        Image("OpenPetsClawClaudeSprite")
            .interpolation(.none)
            .resizable()
            .frame(
                width: spriteWidth * Self.columns,
                height: spriteHeight * Self.rows,
                alignment: .topLeading
            )
            .offset(
                x: -spriteWidth * CGFloat(frame),
                y: -spriteHeight * CGFloat(state.row)
            )
            .frame(width: spriteWidth, height: spriteHeight, alignment: .topLeading)
            .clipped()
            .shadow(color: Color.black.opacity(isHovered ? 0.22 : 0.14), radius: isHovered ? 4 : 2, x: 0, y: 2)
    }

    private func frameIndex(state: SpriteState, at date: Date) -> Int {
        let elapsed = date.timeIntervalSinceReferenceDate
        let progress = elapsed.truncatingRemainder(dividingBy: state.duration) / state.duration
        return min(state.frames - 1, max(0, Int(progress * Double(state.frames))))
    }
}

private struct SpeechBubbleTail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
