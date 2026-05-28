import AppKit
import Foundation
import SwiftUI

final class SortAssistantNativeTextField: NSTextField {
    var onHandleKeyEvent: ((NSEvent, NSTextView?) -> Bool)?
    var onWindowReady: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        usesSingleLineMode = true
        isEditable = true
        isSelectable = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowReady?()
    }

    override func keyDown(with event: NSEvent) {
        if (currentEditor() as? NSTextView)?.hasMarkedText() == true {
            super.keyDown(with: event)
            return
        }
        if onHandleKeyEvent?(event, currentEditor() as? NSTextView) == true {
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if (currentEditor() as? NSTextView)?.hasMarkedText() == true {
            return super.performKeyEquivalent(with: event)
        }
        if onHandleKeyEvent?(event, currentEditor() as? NSTextView) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private final class SortAssistantPlaceholderTextView: NSTextView {
    var placeholderString = "" {
        didSet { needsDisplay = true }
    }

    override var string: String {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard string.isEmpty, !placeholderString.isEmpty else { return }
        let inset = textContainerInset
        let rect = bounds.insetBy(dx: inset.width + 2, dy: inset.height)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        placeholderString.draw(in: rect, withAttributes: attributes)
    }
}

struct SortAssistantMemoryCandidateTextEditor: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SortAssistantMemoryCandidateTextEditor
        var isProgrammaticMutation = false

        init(parent: SortAssistantMemoryCandidateTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Foundation.Notification) {
            guard !isProgrammaticMutation,
                  let textView = notification.object as? SortAssistantPlaceholderTextView else {
                return
            }
            parent.text = textView.string
            textView.needsDisplay = true
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView(frame: .zero)
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = SortAssistantPlaceholderTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.font = .systemFont(ofSize: 11)
        textView.string = text
        textView.placeholderString = placeholder
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? SortAssistantPlaceholderTextView else { return }
        textView.placeholderString = placeholder
        if textView.string != text {
            context.coordinator.isProgrammaticMutation = true
            textView.string = text
            context.coordinator.isProgrammaticMutation = false
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        (scrollView.documentView as? NSTextView)?.delegate = nil
    }
}

struct SortAssistantInputTextField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    @Binding var selection: NSRange
    let selectionRevision: Int
    @Binding var isFocused: Bool
    let hasCompletion: Bool
    let onSubmit: () -> Void
    let onMoveCompletion: (Int) -> Void
    let onAcceptCompletion: () -> Bool
    let onDismissCompletion: () -> Void
    let keyboardOptionCount: Int
    let onActivateKeyboardOption: (Int) -> Bool
    let onActivatePrimaryKeyboardOption: () -> Bool
    let onCancelKeyboardOption: () -> Bool
    let onMoveKeyboardOption: (Int) -> Bool

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SortAssistantInputTextField
        var isProgrammaticMutation = false
        weak var parentField: SortAssistantNativeTextField?
        var pendingFocusRequest = false
        var appliedSelectionRevision = 0

        init(parent: SortAssistantInputTextField) {
            self.parent = parent
        }

        func controlTextDidBeginEditing(_ obj: Foundation.Notification) {
            publishSelection(from: obj.object as? NSTextField)
            if !parent.isFocused {
                DispatchQueue.main.async {
                    self.parent.isFocused = true
                }
            }
        }

        func controlTextDidChange(_ obj: Foundation.Notification) {
            guard !isProgrammaticMutation,
                  let field = obj.object as? NSTextField else {
                return
            }
            parent.text = field.stringValue
            publishSelection(from: field)
        }

        func controlTextDidEndEditing(_ obj: Foundation.Notification) {
            publishSelection(from: obj.object as? NSTextField)
            if parent.isFocused {
                DispatchQueue.main.async {
                    self.parent.isFocused = false
                }
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveDown(_:)):
                if parent.hasCompletion {
                    parent.onMoveCompletion(+1)
                } else if parent.isDraftEmpty, parent.onMoveKeyboardOption(+1) {
                    parent.selection = textView.selectedRange()
                } else {
                    return false
                }
                parent.selection = textView.selectedRange()
                return true
            case #selector(NSResponder.moveUp(_:)):
                if parent.hasCompletion {
                    parent.onMoveCompletion(-1)
                } else if parent.isDraftEmpty, parent.onMoveKeyboardOption(-1) {
                    parent.selection = textView.selectedRange()
                } else {
                    return false
                }
                parent.selection = textView.selectedRange()
                return true
            case #selector(NSResponder.insertTab(_:)):
                guard acceptCompletionIfAvailable(editor: textView) || parent.hasCompletion else { return false }
                return true
            case #selector(NSResponder.insertNewline(_:)):
                guard !textView.hasMarkedText() else { return false }
                if acceptCompletionIfAvailable(editor: textView) || parent.hasCompletion {
                    return true
                } else if parent.isDraftEmpty, parent.onActivatePrimaryKeyboardOption() {
                    parent.selection = textView.selectedRange()
                } else {
                    parent.selection = textView.selectedRange()
                    parent.onSubmit()
                }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                guard !textView.hasMarkedText() else { return false }
                if parent.hasCompletion {
                    parent.onDismissCompletion()
                } else if parent.isDraftEmpty, parent.onCancelKeyboardOption() {
                    parent.selection = textView.selectedRange()
                } else {
                    parent.selection = textView.selectedRange()
                    parent.isFocused = false
                    parentField?.window?.makeFirstResponder(nil)
                }
                return true
            default:
                parent.selection = textView.selectedRange()
                return false
            }
        }

        func handleKeyEvent(_ event: NSEvent, editor: NSTextView?) -> Bool {
            guard !(editor?.hasMarkedText() ?? false) else { return false }
            let flags = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .subtracting([.numericPad, .function, .capsLock])
            guard flags.isEmpty else { return false }

            if parent.isDraftEmpty, !parent.hasCompletion {
                if let optionIndex = SortAssistantInputTextField.keyboardOptionIndex(for: event.keyCode),
                   optionIndex < parent.keyboardOptionCount {
                    parent.onActivateKeyboardOption(optionIndex)
                    publishSelection(from: parentField)
                    return true
                }
                switch event.keyCode {
                case 123, 126:
                    guard parent.onMoveKeyboardOption(-1) else { return false }
                    publishSelection(from: parentField)
                    return true
                case 124, 125:
                    guard parent.onMoveKeyboardOption(+1) else { return false }
                    publishSelection(from: parentField)
                    return true
                case 36, 76:
                    guard parent.onActivatePrimaryKeyboardOption() else { break }
                    publishSelection(from: parentField)
                    return true
                case 53:
                    guard parent.onCancelKeyboardOption() else { break }
                    publishSelection(from: parentField)
                    return true
                default:
                    break
                }
            }

            switch event.keyCode {
            case 125:
                guard parent.hasCompletion else { return false }
                parent.onMoveCompletion(+1)
                publishSelection(from: parentField)
                return true
            case 126:
                guard parent.hasCompletion else { return false }
                parent.onMoveCompletion(-1)
                publishSelection(from: parentField)
                return true
            case 48:
                guard acceptCompletionIfAvailable(editor: editor) || parent.hasCompletion else { return false }
                return true
            case 36, 76:
                if acceptCompletionIfAvailable(editor: editor) || parent.hasCompletion { return true }
                parent.onSubmit()
                return true
            case 53:
                if parent.hasCompletion {
                    parent.onDismissCompletion()
                } else {
                    parent.isFocused = false
                    parentField?.window?.makeFirstResponder(nil)
                }
                return true
            default:
                return false
            }
        }

        func publishSelection(from field: NSTextField?) {
            let textLength = ((field?.stringValue ?? "") as NSString).length
            let selectedRange = (field?.currentEditor() as? NSTextView)?.selectedRange()
                ?? NSRange(location: textLength, length: 0)
            if parent.selection != selectedRange {
                parent.selection = selectedRange
            }
        }

        private func acceptCompletionIfAvailable(editor: NSTextView?) -> Bool {
            guard parent.onAcceptCompletion() else { return false }
            syncEditorAfterProgrammaticMutation(editor: editor)
            return true
        }

        private func syncEditorAfterProgrammaticMutation(editor: NSTextView?) {
            guard let field = parentField else { return }
            let targetText = parent.text
            let targetSelection = SortAssistantInputTextField.clamped(parent.selection, text: targetText)
            let activeEditor = editor ?? field.currentEditor() as? NSTextView
            if let activeEditor, !activeEditor.hasMarkedText() {
                isProgrammaticMutation = true
                activeEditor.string = targetText
                field.stringValue = targetText
                isProgrammaticMutation = false
                activeEditor.setSelectedRange(targetSelection)
            } else {
                field.stringValue = targetText
            }
            appliedSelectionRevision = parent.selectionRevision
        }

        func applySelectionToEditorIfNeeded(
            field: SortAssistantNativeTextField,
            force: Bool
        ) {
            guard let editor = field.currentEditor() as? NSTextView,
                  !editor.hasMarkedText() else {
                return
            }
            let targetSelection = SortAssistantInputTextField.clamped(parent.selection, text: editor.string)
            guard force || editor.selectedRange() != targetSelection else { return }
            editor.setSelectedRange(targetSelection)

            let expectedText = parent.text
            let expectedSelection = targetSelection
            let expectedRevision = parent.selectionRevision
            DispatchQueue.main.async { [weak self, weak field] in
                guard let self,
                      self.parent.selectionRevision == expectedRevision,
                      self.parent.text == expectedText,
                      self.parent.selection == expectedSelection,
                      let field,
                      let editor = field.currentEditor() as? NSTextView,
                      editor.string == expectedText,
                      !editor.hasMarkedText() else {
                    return
                }
                if editor.selectedRange() != expectedSelection {
                    editor.setSelectedRange(expectedSelection)
                }
            }
        }

        func requestFocusIfNeeded() {
            guard let parentField else { return }
            requestFocusIfNeeded(field: parentField)
        }

        func requestFocusIfNeeded(field: SortAssistantNativeTextField) {
            guard parent.isFocused,
                  let window = field.window,
                  !isFieldFirstResponder(field, in: window),
                  !pendingFocusRequest else {
                return
            }

            pendingFocusRequest = true
            DispatchQueue.main.async { [weak self, weak field] in
                guard let self else { return }
                self.pendingFocusRequest = false
                guard self.parent.isFocused,
                      let field,
                      let window = field.window else {
                    return
                }
                if !window.isKeyWindow {
                    window.makeKey()
                }
                window.makeFirstResponder(field)
                self.applySelectionToEditorIfNeeded(field: field, force: true)
                self.appliedSelectionRevision = self.parent.selectionRevision
            }
        }

        private func isFieldFirstResponder(_ field: SortAssistantNativeTextField, in window: NSWindow) -> Bool {
            let firstResponder = window.firstResponder
            return firstResponder === field ||
                field.currentEditor() != nil ||
                ((firstResponder as? NSTextView)?.delegate as? NSTextField) === field
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> SortAssistantNativeTextField {
        let field = SortAssistantNativeTextField(frame: .zero)
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.stringValue = text
        field.setAccessibilityIdentifier(SortAssistantAccessibility.inputField)
        field.onHandleKeyEvent = { [weak coordinator = context.coordinator] event, editor in
            coordinator?.handleKeyEvent(event, editor: editor) ?? false
        }
        field.onWindowReady = { [weak coordinator = context.coordinator] in
            coordinator?.requestFocusIfNeeded()
        }
        context.coordinator.parentField = field
        return field
    }

    func updateNSView(_ nsView: SortAssistantNativeTextField, context: Context) {
        context.coordinator.parent = self
        context.coordinator.parentField = nsView
        nsView.placeholderString = placeholder
        let forceSelection = context.coordinator.appliedSelectionRevision != selectionRevision

        if let editor = nsView.currentEditor() as? NSTextView {
            if editor.string != text, !editor.hasMarkedText() {
                context.coordinator.isProgrammaticMutation = true
                editor.string = text
                nsView.stringValue = text
                context.coordinator.isProgrammaticMutation = false
            }
            context.coordinator.applySelectionToEditorIfNeeded(
                field: nsView,
                force: forceSelection
            )
            context.coordinator.appliedSelectionRevision = selectionRevision
        } else if nsView.stringValue != text {
            nsView.stringValue = text
        }

        context.coordinator.requestFocusIfNeeded(field: nsView)
    }

    static func dismantleNSView(_ nsView: SortAssistantNativeTextField, coordinator: Coordinator) {
        nsView.delegate = nil
        nsView.onHandleKeyEvent = nil
        nsView.onWindowReady = nil
        coordinator.parentField = nil
    }

    private var isDraftEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func keyboardOptionIndex(for keyCode: UInt16) -> Int? {
        switch keyCode {
        case 18, 83: return 0
        case 19, 84: return 1
        case 20, 85: return 2
        case 21, 86: return 3
        case 23, 87: return 4
        case 22, 88: return 5
        case 26, 89: return 6
        case 28, 91: return 7
        case 25, 92: return 8
        default: return nil
        }
    }

    private static func clamped(_ range: NSRange, text: String) -> NSRange {
        let length = (text as NSString).length
        let location = min(max(range.location, 0), length)
        let rangeLength = min(max(range.length, 0), length - location)
        return NSRange(location: location, length: rangeLength)
    }
}
