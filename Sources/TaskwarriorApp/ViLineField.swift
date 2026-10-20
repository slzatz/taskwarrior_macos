import AppKit
import SwiftUI
import TaskwarriorCore

/// The list's description editor: a borderless text field driven by `ViLineEditor`, which starts
/// in normal mode. A local key monitor sees keys before the field does. In normal mode it gives
/// the editor every key without ⌘ and shows the result, the cursor as a one-character selection;
/// in insert mode it takes only Esc, Return, Ctrl-W and Ctrl-U, so typing and input methods stay
/// the field's own. The editor alone owns the cursor: it is read back from the field before each
/// key and written after, so the two never disagree (vimango_macos's NSTextView editor failed on
/// exactly that).
///
/// Focus is handled in AppKit, not with SwiftUI's focus state, which doesn't see the field take
/// it: the field takes focus once it is in a window, and before it goes away hands focus to the
/// list it sits in (Return, Esc), or leaves it for the command line (`:`). Otherwise the
/// window's first responder is left on a field editor that is no longer shown, and keys beep.
struct ViLineField: NSViewRepresentable {
    let initialText: String
    let fontSize: Double
    let onCommit: (String) -> Void
    let onCancel: () -> Void
    /// `:` in normal mode: the edit is dropped and the command line wanted instead.
    let onCommandLine: () -> Void
    /// The mode after each key, and once when the field opens.
    let onModeChange: (ViLineEditor.Mode) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = WindowAwareTextField(string: initialText)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: fontSize)
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.attach(field)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.font?.pointSize != CGFloat(fontSize) { field.font = .systemFont(ofSize: fontSize) }
    }

    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ViLineField
        private var editor: ViLineEditor
        private weak var field: NSTextField?
        private var monitor: Any?
        /// Set once committed or cancelled, so the focus loss that follows doesn't cancel again.
        private var finished = false
        private var reportedMode: ViLineEditor.Mode?

        init(parent: ViLineField) {
            self.parent = parent
            editor = ViLineEditor(text: parent.initialText)
        }

        func attach(_ field: WindowAwareTextField) {
            self.field = field
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
                return handled ? nil : event
            }
            // Taking focus selects all; `show` replaces that.
            field.movedToWindow = { [weak self] in
                guard let self, let field = self.field, !self.finished else { return }
                field.window?.makeFirstResponder(field)
                self.show()
            }
        }

        func detach() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// The field editor, while it is editing this field.
        private var textView: NSTextView? {
            guard let field, let textView = field.currentEditor() as? NSTextView,
                  field.window?.firstResponder === textView else { return nil }
            return textView
        }

        /// True when the key was the editor's (and is swallowed).
        private func handle(_ event: NSEvent) -> Bool {
            guard !finished, let textView, !textView.hasMarkedText() else { return false }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains(.command) { return false }
            guard let key = Self.key(for: event, flags: flags) else { return editor.mode == .normal }
            if editor.mode == .insert {
                switch key {
                case .escape, .enter, .ctrl("w"), .ctrl("u"): break
                default: return false
                }
            }
            editor.sync(text: textView.string, utf16Cursor: textView.selectedRange().location)
            switch editor.handle(key) {
            case .commit:
                finish(focusingList: true)
                parent.onCommit(editor.text)
            case .cancel:
                finish(focusingList: true)
                parent.onCancel()
            case .commandLine:
                finish(focusingList: false)
                parent.onCommandLine()
            case .none:
                show()
            }
            return true
        }

        private func show() {
            guard let textView = field?.currentEditor() as? NSTextView else { return }
            if textView.string != editor.text { textView.string = editor.text }
            let selection = editor.selectionUTF16
            let range = NSRange(location: selection.location, length: selection.length)
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
            if reportedMode != editor.mode {
                reportedMode = editor.mode
                parent.onModeChange(editor.mode)
            }
        }

        /// With `focusingList`, the list's table view gets focus back (its row selection is kept).
        private func finish(focusingList: Bool) {
            finished = true
            detach()
            guard focusingList, let field, let window = field.window else { return }
            var view = field.superview
            while let current = view, !(current is NSTableView) { view = current.superview }
            window.makeFirstResponder(view)
        }

        /// Focus went elsewhere (a click): whatever took it keeps it.
        func controlTextDidEndEditing(_ notification: Notification) {
            guard !finished else { return }
            finish(focusingList: false)
            parent.onCancel()
        }

        private static func key(for event: NSEvent, flags: NSEvent.ModifierFlags) -> ViLineEditor.Key? {
            switch event.keyCode {
            case 53: return .escape
            case 36, 76: return .enter
            case 51: return .backspace
            case 123: return .left
            case 124: return .right
            case 115: return .home
            case 119: return .end
            default: break
            }
            if flags.contains(.control) {
                return event.charactersIgnoringModifiers?.lowercased().first.map { .ctrl($0) }
            }
            // Function keys (arrows up/down, F1…) arrive as private-use characters.
            guard let c = event.characters?.first,
                  !c.unicodeScalars.contains(where: { (0xF700...0xF8FF).contains($0.value) }) else { return nil }
            return .char(c)
        }
    }
}

/// Says when it has been put in a window, the moment it can take focus.
final class WindowAwareTextField: NSTextField {
    var movedToWindow: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, let movedToWindow else { return }
        self.movedToWindow = nil
        // After the move completes; becoming first responder during it is not reliable.
        DispatchQueue.main.async(execute: movedToWindow)
    }
}
