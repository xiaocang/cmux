import AppKit
import SwiftUI

/// Debug-only window that previews every ``SortAssistantMascotState`` (all 24
/// emotes) live-animating in a grid, and can push any emote onto the live
/// floating sprite via `SortAssistantCoordinator.shared.emoteOverride`.
///
/// Rows 0–8 are the OpenPets engine art; rows 9–23 are the Clawd extension and
/// render as empty cells until a 24-row `OpenPetsClawClaudeSprite.png` is
/// installed. This window is the iteration tool for generating that art.
final class SpriteEmoteGalleryWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SpriteEmoteGalleryWindowController()

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 680),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "debug.spriteEmotes.title", defaultValue: "Sprite Emotes")
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.spriteEmoteGallery")
        window.center()
        window.contentView = NSHostingView(rootView: SpriteEmoteGalleryView())
        AppDelegate.shared?.applyWindowDecorations(to: window)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @MainActor
    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct SpriteEmoteGalleryView: View {
    @ObservedObject private var coordinator = SortAssistantCoordinator.shared
    @State private var size: Double = 64

    private let columns = [GridItem(.adaptive(minimum: 124), spacing: 16)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(SortAssistantMascotState.allCases, id: \.self) { state in
                        cell(for: state)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        let rowCount = SortAssistantMascotState.installedSheetRowCount
        let hasClawd = SortAssistantMascotState.hasClawdRows
        let detail = hasClawd
            ? String(localized: "debug.spriteEmotes.sheetFull",
                     defaultValue: "Clawd rows present — the 15 new emotes will render.")
            : String(localized: "debug.spriteEmotes.sheet9",
                     defaultValue: "Rows 9–23 have no art yet, so the 15 new emotes show as empty cells. Drop a 24-row OpenPetsClawClaudeSprite.png into the asset to light them up.")
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(String(localized: "debug.spriteEmotes.title", defaultValue: "Sprite Emotes"))
                    .font(.headline)
                Spacer()
                if coordinator.emoteOverride != nil {
                    Button(String(localized: "debug.spriteEmotes.clear", defaultValue: "Clear live override")) {
                        coordinator.emoteOverride = nil
                    }
                }
            }
            Text("\(rowCount)-row sheet · " + detail)
                .font(.caption)
                .foregroundStyle(hasClawd ? Color.green : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text(String(localized: "debug.spriteEmotes.size", defaultValue: "Size"))
                    .font(.caption)
                Slider(value: $size, in: 32...160, step: 4)
                Text(verbatim: "\(Int(size))")
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 32, alignment: .trailing)
            }
            Text(String(localized: "debug.spriteEmotes.hint",
                        defaultValue: "Tap an emote to drive the live floating sprite; tap again (or Clear) to return to the derived state."))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func cell(for state: SortAssistantMascotState) -> some View {
        let isLive = coordinator.emoteOverride == state
        Button {
            coordinator.emoteOverride = isLive ? nil : state
        } label: {
            VStack(spacing: 6) {
                SortAssistantMascotAvatar(size: size, state: state)
                    .frame(width: size, height: size)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.primary.opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                isLive ? Color.accentColor : Color.primary.opacity(0.08),
                                lineWidth: isLive ? 2 : 1
                            )
                    )
                Text(verbatim: String(describing: state))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                Text(verbatim: "row \(state.row) · \(state.frames)f · \(String(format: "%.2fs", state.duration))")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .help(
            isLive
                ? String(localized: "debug.spriteEmotes.clearLive", defaultValue: "Clear the live override")
                : String(localized: "debug.spriteEmotes.driveLive", defaultValue: "Drive the live floating sprite with this emote")
        )
    }
}
