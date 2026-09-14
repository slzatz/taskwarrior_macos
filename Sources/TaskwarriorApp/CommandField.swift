import AppKit
import SwiftUI

/// The single-line command input. AppKit is used so Up/Down reliably walk the
/// history and Return submits without fighting SwiftUI's key handling.
struct CommandField: NSViewRepresentable {
    @Binding var text: String
    var fontSize: Double
    var history: [String]
    var focusRequest: Int
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        field.placeholderString = "task command  (e.g. next · 5 done · add Buy milk due:tomorrow · sync)"
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
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
        /// Position while browsing history; nil means "editing a new line".
        private var historyIndex: Int?
        private var draft = ""

        init(parent: CommandField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
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
                historyIndex = nil
                set("", on: control)
                return true
            default:
                return false
            }
        }

        private func navigateHistory(by delta: Int, control: NSControl) {
            let history = parent.history
            guard !history.isEmpty else { return }
            if historyIndex == nil {
                guard delta < 0 else { return }
                draft = control.stringValue
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
            control.stringValue = value
            parent.text = value
            control.currentEditor()?.selectedRange = NSRange(location: (value as NSString).length, length: 0)
        }
    }
}
