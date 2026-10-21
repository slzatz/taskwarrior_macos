import AppKit
import SwiftUI

/// Gives keyboard focus to the display: the task list's table, or the text view when text is
/// shown. AppKit's job, not `@FocusState`, which doesn't see the command field (or the row
/// editor) take focus and so treats setting it again as a no-op.
///
/// A new `request` always moves focus. When the display swaps between list and text, the view
/// that had focus leaves the window and nothing has it; the new view then takes it, but only
/// then, so a swap never takes focus from the command line.
struct DisplayFocus: NSViewRepresentable {
    var request: Int
    var showsList: Bool

    final class Coordinator {
        var request = 0
        var showsList: Bool?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        let swapped = coordinator.showsList.map { $0 != showsList } ?? false
        coordinator.showsList = showsList
        if coordinator.request != request {
            coordinator.request = request
            Self.focus(from: view, coordinator: coordinator, always: true)
        } else if swapped {
            Self.focus(from: view, coordinator: coordinator, always: false)
        }
    }

    /// After the update that asked for it, once the view for what is shown now is in the window
    /// (a request and a swap often come together, and the old view can still be there). A newly
    /// shown list can take several run-loop turns to get its table, so this retries for a second.
    private static func focus(from view: NSView, coordinator: Coordinator, always: Bool, attempts: Int = 50, delay: Double = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak view] in
            guard let view, let window = view.window, let content = window.contentView else { return }
            let wanted: NSView.Type = coordinator.showsList == true ? NSTableView.self : TerminalNSTextView.self
            guard let target = displayView(in: content, ofType: wanted) else {
                if attempts > 1 { focus(from: view, coordinator: coordinator, always: always, attempts: attempts - 1, delay: 0.02) }
                return
            }
            // On a swap, only when focus was on the old display view or is nowhere.
            if !always, let responder = window.firstResponder, responder !== window,
               !(responder is NSTableView || responder is TerminalNSTextView) { return }
            window.makeFirstResponder(target)
        }
    }

    private static func displayView(in view: NSView, ofType type: NSView.Type) -> NSView? {
        if view.isKind(of: type) { return view }
        for subview in view.subviews {
            if let found = displayView(in: subview, ofType: type) { return found }
        }
        return nil
    }
}
