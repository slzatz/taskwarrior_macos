import AppKit
import SwiftUI

/// One line of the help sheet: the keys (or command) and what they do.
struct HelpEntry: Identifiable {
    let keys: String
    let summary: String
    var id: String { keys }
}

/// A group of entries under a heading.
struct HelpSection: Identifiable {
    let title: String
    let entries: [HelpEntry]
    var id: String { title }

    /// The app's keys and commands. A new key binding, or a change to one, belongs here too:
    /// nothing checks this table against the code.
    static let all: [HelpSection] = [
        HelpSection(title: "List", entries: [
            .init(keys: "j / k,  ↓ / ↑", summary: "Move the selection"),
            .init(keys: "Space", summary: "Mark the task done"),
            .init(keys: "Return", summary: "Show its information (Esc goes back to the list); also a double-click"),
            .init(keys: "e", summary: "Edit its description in the row, with vi keys (below)"),
            .init(keys: ":", summary: "Go to the command line"),
            .init(keys: "?", summary: "This help"),
            .init(keys: "Right-click", summary: "Done, Start/Stop, Show Info, Edit Description, vimango note, Copy UUID, Delete"),
        ]),
        HelpSection(title: "Command line", entries: [
            .init(keys: "Return", summary: "Run the line and go back to the list, whatever ran"),
            .init(keys: "Esc", summary: "Clear the line and go back to the list"),
            .init(keys: "↑ / ↓", summary: "Walk the history (: then ↑ repeats or fixes the last line)"),
            .init(keys: "help,  h,  ?", summary: "This help; type task help for taskwarrior's own"),
            .init(keys: "Where you land", summary: "On the task a command named (5 done, 3 modify …), or the row that took its place; on the new task after add; on the first row of a new listing; otherwise where you were"),
        ]),
        HelpSection(title: "Description editor", entries: [
            .init(keys: "e", summary: "Opens it in NORMAL mode on the last character; the badge shows the mode"),
            .init(keys: "h l w b e W B E 0 ^ $", summary: "Motions; also f t F T with ; and ,"),
            .init(keys: "x X r s S C D ~ p P", summary: "Edits; i a I A to insert"),
            .init(keys: "d c y + motion", summary: "With a motion or text object (iw aw, quotes, brackets); counts work"),
            .init(keys: "u,  Ctrl-R,  .", summary: "Undo, redo, repeat the last change"),
            .init(keys: "Ctrl-W,  Ctrl-U", summary: "In insert mode: delete the word, or the line, before the cursor"),
            .init(keys: "Return", summary: "Save (either mode)"),
            .init(keys: "Esc", summary: "In normal mode: cancel (as does clicking away)"),
            .init(keys: ":", summary: "In normal mode: cancel and go to the command line"),
        ]),
        HelpSection(title: "Raw view and information", entries: [
            .init(keys: "j / k,  ↓ / ↑", summary: "Scroll a line"),
            .init(keys: "Space,  Page Down / Up", summary: "Scroll a page"),
            .init(keys: "g / G,  Home / End", summary: "Go to the top / bottom"),
            .init(keys: "Esc", summary: "Back to the list from information or task help"),
            .init(keys: ":", summary: "Go to the command line"),
            .init(keys: "?", summary: "This help"),
        ]),
        HelpSection(title: "Menu shortcuts", entries: [
            .init(keys: "⌘1 / ⌘2", summary: "Show reports as a list / as taskwarrior's raw output"),
            .init(keys: "⌘R", summary: "Re-run the current listing"),
            .init(keys: "⌘L", summary: "Go to the command line"),
            .init(keys: "⌘= / ⌘- / ⌘0", summary: "Font size larger / smaller / default"),
            .init(keys: "⌘⇧O,  ⌘K", summary: "Show or hide the output pane; clear it"),
            .init(keys: "⌘?", summary: "This help"),
        ]),
        HelpSection(title: "Sync cloud (status bar)", entries: [
            .init(keys: "↑ and a number", summary: "Tasks with changes not yet synced"),
            .init(keys: "↓", summary: "The server has changes from another machine (checked when the app comes to the front, and every 15 minutes)"),
            .init(keys: "!", summary: "The last sync failed"),
            .init(keys: "Click", summary: "Run task sync; nothing syncs on its own"),
        ]),
        HelpSection(title: "Taskwarrior commands", entries: [
            .init(keys: "[filter] command [args]", summary: "As in a terminal, with or without the leading task: 5 done, project:work next, add Buy milk due:tomorrow"),
            .init(keys: "Reports", summary: "Replace the view; every task is shown (no page limit), and the view is re-run after each change"),
            .init(keys: "Changes", summary: "Logged in the output pane; delete, purge, undo and bulk changes ask first"),
            .init(keys: "done, modify …, delete", summary: "With no filter, act on the selected task (also from its info page), like an ex command on vim's current line"),
            .init(keys: "5 done, +home done", summary: "A filter is used as typed; ids are shown in the raw view and renumber after changes"),
            .init(keys: "No shell", summary: "Quoting works; globs, pipes and $VAR don't. edit and execute aren't available"),
        ]),
    ]
}

/// The help sheet (`help` on the command line, `?` in the list, Help menu). Esc or Close
/// dismisses it; it scrolls from the keyboard like the raw view.
struct HelpView: View {
    let onDismiss: () -> Void
    @State private var scroller = SheetKeyScroller()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Keyboard and commands").font(.headline)
                Spacer()
                Button("Close", action: onDismiss).keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            ScrollView {
                HelpContent()
                    .padding(12)
                    .background(EnclosingScrollViewGrabber { scroller.scrollView = $0 })
            }
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 360, idealHeight: 560)
        .onAppear { scroller.install() }
        .onDisappear { scroller.uninstall() }
    }
}

/// The sheet's text: an introduction, then each section's keys. Separate so a scripted run can
/// draw it (a snapshot of the sheet's window comes out blank).
struct HelpContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Everything works from the keyboard: : in the list opens the command line, and Return or Esc there come back. Scroll this sheet with j/k, Space/Shift-Space, Page Down/Up, g/G or Ctrl-D/U; Esc closes it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Grid(alignment: .topLeading, horizontalSpacing: 20, verticalSpacing: 6) {
                ForEach(HelpSection.all) { section in
                    GridRow {
                        Text(section.title.uppercased())
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                            .gridCellColumns(2)
                    }
                    ForEach(section.entries) { entry in
                        GridRow {
                            Text(entry.keys)
                                .font(.system(.body, design: .monospaced))
                            Text(entry.summary)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}

/// Resolves the `NSScrollView` behind the SwiftUI `ScrollView` it sits in, so AppKit code can
/// scroll it (from vimango_hybrid's help sheet).
struct EnclosingScrollViewGrabber: NSViewRepresentable {
    let onResolve: (NSScrollView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            if let scrollView = view?.enclosingScrollView { onResolve(scrollView) }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

/// vi-style scrolling for a sheet, which is its own window: j/k and arrows a line,
/// Space/Shift-Space, Page Down/Up and Ctrl-D/U half a page, g/G to the ends. A local key
/// monitor scoped to the sheet's window, alive only while the sheet is (vimango_hybrid's
/// `SheetKeyScroller`).
@MainActor
final class SheetKeyScroller {
    weak var scrollView: NSScrollView?
    private var monitor: Any?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return handled ? nil : event
        }
    }

    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let scrollView, event.window === scrollView.window else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers ?? ""
        let line: CGFloat = 32
        let halfPage = scrollView.contentView.bounds.height / 2

        if flags.contains(.control), flags.isDisjoint(with: [.command, .option]) {
            switch chars {
            case "d": scroll(by: halfPage)
            case "u": scroll(by: -halfPage)
            default: return false
            }
            return true
        }
        guard flags.isDisjoint(with: [.command, .control, .option]) else { return false }
        if chars == " " || event.specialKey == .pageDown || event.specialKey == .pageUp {
            let up = event.specialKey == .pageUp || (chars == " " && flags.contains(.shift))
            scroll(by: up ? -halfPage : halfPage)
        } else if event.specialKey == .downArrow || chars == "j" {
            scroll(by: line)
        } else if event.specialKey == .upArrow || chars == "k" {
            scroll(by: -line)
        } else if event.specialKey == .home || chars == "g" {
            scroll(by: -.greatestFiniteMagnitude)
        } else if event.specialKey == .end || chars == "G" {
            scroll(by: .greatestFiniteMagnitude)
        } else {
            return false
        }
        return true
    }

    /// Positive scrolls toward the end; clamped to the document.
    private func scroll(by dy: CGFloat) {
        guard let scrollView, let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let bottom = max(0, document.frame.height - clip.bounds.height)
        var origin = clip.bounds.origin
        // SwiftUI's scroll view document is flipped: y grows downward.
        origin.y = min(max(origin.y + dy, 0), bottom)
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
    }
}
