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
struct ViLineField: NSViewRepresentable {
    let initialText: String
    let fontSize: Double
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: initialText)
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

        init(parent: ViLineField) {
            self.parent = parent
            editor = ViLineEditor(text: parent.initialText)
        }

        func attach(_ field: NSTextField) {
            self.field = field
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
                return handled ? nil : event
            }
            // Once the field is in the window. Taking focus selects all; `show` replaces that.
            DispatchQueue.main.async { [weak self] in
                guard let self, let field = self.field else { return }
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
                finish()
                parent.onCommit(editor.text)
            case .cancel:
                finish()
                parent.onCancel()
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
        }

        private func finish() {
            finished = true
            detach()
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard !finished else { return }
            finish()
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
