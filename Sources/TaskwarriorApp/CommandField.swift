import AppKit
import SwiftUI
import TaskwarriorCore

/// The single-line command input. AppKit is used so Up/Down reliably walk the
/// history and Return submits without fighting SwiftUI's key handling. Like vim's `:` line it
/// is visited from the list: Return runs the line and Esc drops it, and both go back
/// (`onSubmit` / `onLeave`).
///
/// While it is edited the field starts with a `:` (`CommandPrompt`), real text that `text`
/// never holds. The caret can't go before it and edits can't remove it; Backspace on a line
/// that is only the prompt leaves, as in vim. Unfocused, the field shows the line without it.
struct CommandField: NSViewRepresentable {
    @Binding var text: String
    var fontSize: Double
    var history: [String]
    var focusRequest: Int
    var onSubmit: () -> Void
    var onLeave: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = PromptField()
        field.appearance = NSAppearance(named: .darkAqua)
        field.delegate = context.coordinator
        field.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        field.placeholderString = "task command  (e.g. next · done · modify due:fri · add Buy milk · sync)"
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        context.coordinator.field = field
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if CommandPrompt.line(fromField: field.stringValue) != text {
            field.stringValue = field.currentEditor() == nil ? text : CommandPrompt.field(for: text)
        }
        if field.font?.pointSize != CGFloat(fontSize) {
            field.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CommandField
        var focusRequest = 0
        weak var field: NSTextField?
        /// Position while browsing history; nil means "editing a new line".
        private var historyIndex: Int?
        private var draft = ""
        private var selectionObserver: NSObjectProtocol?

        init(parent: CommandField) {
            self.parent = parent
            super.init()
            // The window's field editor is shared (the row editor uses it too), so this acts
            // only while it is editing this field.
            selectionObserver = NotificationCenter.default.addObserver(
                forName: NSTextView.didChangeSelectionNotification, object: nil, queue: nil
            ) { [weak self] note in
                MainActor.assumeIsolated { self?.keepCaretAfterPrompt(note.object as? NSTextView) }
            }
        }

        deinit {
            if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            // The caret never sits before the prompt, so a change that lost it deleted it
            // (Cmd-Backspace, a selection reaching it): put it back where it was.
            if !field.stringValue.hasPrefix(CommandPrompt.prompt), let editor = field.currentEditor() {
                let caret = editor.selectedRange
                field.stringValue = CommandPrompt.field(for: field.stringValue)
                field.currentEditor()?.selectedRange = NSRange(location: caret.location + 1, length: caret.length)
            }
            parent.text = CommandPrompt.line(fromField: field.stringValue)
        }

        /// Clamps the field editor's selection to after the prompt (clicks, Home, Cmd-A).
        private func keepCaretAfterPrompt(_ editor: NSTextView?) {
            guard let editor, let field, editor === field.currentEditor(),
                  field.stringValue.hasPrefix(CommandPrompt.prompt) else { return }
            let range = editor.selectedRange()
            guard range.location == 0 else { return }
            let length = max(range.length - 1, 0)
            editor.setSelectedRange(NSRange(location: 1, length: length))
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                historyIndex = nil
                draft = ""
                parent.onSubmit()
                return true
            case #selector(NSResponder.moveUp(_:)):
                navigateHistory(by: -1, control: control)
                return true
            case #selector(NSResponder.moveDown(_:)):
                navigateHistory(by: 1, control: control)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                leave(control)
                return true
            case #selector(NSResponder.deleteBackward(_:)),
                 #selector(NSResponder.deleteBackwardByDecomposingPreviousCharacter(_:)):
                // Backspace on an empty line leaves, as in vim; just after the prompt it does
                // nothing.
                let caret = textView.selectedRange()
                guard caret.length == 0, caret.location <= 1 else { return false }
                if control.stringValue == CommandPrompt.prompt { leave(control) }
                return true
            default:
                return false
            }
        }

        private func leave(_ control: NSControl) {
            historyIndex = nil
            set("", on: control)
            parent.onLeave()
        }

        private func navigateHistory(by delta: Int, control: NSControl) {
            let history = parent.history
            guard !history.isEmpty else { return }
            if historyIndex == nil {
                guard delta < 0 else { return }
                draft = CommandPrompt.line(fromField: control.stringValue)
                historyIndex = history.count
            }
            let next = (historyIndex ?? history.count) + delta
            if next >= history.count {
                historyIndex = nil
                set(draft, on: control)
            } else if next >= 0 {
                historyIndex = next
                set(history[next], on: control)
            }
        }

        private func set(_ value: String, on control: NSControl) {
            control.stringValue = CommandPrompt.field(for: value)
            parent.text = value
            control.currentEditor()?.selectedRange = NSRange(location: (control.stringValue as NSString).length, length: 0)
        }
    }
}

/// Shows the prompt while it is edited, however it got focus (`:`, a click, the menu), and
/// drops it when it loses focus, so the placeholder comes back.
private final class PromptField: NSTextField {
    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        if !stringValue.hasPrefix(CommandPrompt.prompt) {
            stringValue = CommandPrompt.field(for: stringValue)
        }
        currentEditor()?.selectedRange = NSRange(location: (stringValue as NSString).length, length: 0)
        return true
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        stringValue = CommandPrompt.line(fromField: stringValue)
    }
}
