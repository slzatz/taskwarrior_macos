import AppKit
import SwiftUI
import TaskwarriorCore

/// A non-wrapping, read-only, monospaced text view showing taskwarrior's report output.
struct TerminalTextView: NSViewRepresentable {
    static let inset: CGFloat = 8

    var runs: [StyledRun]
    var generation: Int
    var fontSize: Double
    var preserveScroll: Bool
    /// `:` pressed in the view.
    var onCommandLine: () -> Void = {}
    /// Esc pressed in the view.
    var onLeave: () -> Void = {}

    final class Coordinator {
        var generation = -1
        var fontSize = 0.0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.appearance = NSAppearance(named: .darkAqua)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = TerminalPalette.background

        // Explicit TextKit 1 stack: predictable layout and sizing for non-wrapping text.
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        layoutManager.addTextContainer(container)

        let textView = TerminalNSTextView(frame: .zero, textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.backgroundColor = TerminalPalette.background
        textView.textColor = TerminalPalette.foreground
        textView.insertionPointColor = TerminalPalette.foreground
        textView.textContainerInset = NSSize(width: Self.inset, height: Self.inset)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = []
        textView.font = TerminalFont.font(size: fontSize)

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? TerminalNSTextView else { return }
        textView.onCommandLine = onCommandLine
        textView.onLeave = onLeave
        let coordinator = context.coordinator
        let fontChanged = coordinator.fontSize != fontSize
        guard coordinator.generation != generation || fontChanged else { return }
        coordinator.generation = generation
        coordinator.fontSize = fontSize

        let savedOrigin = scrollView.contentView.bounds.origin
        textView.textStorage?.setAttributedString(TerminalStyle.nsAttributedString(runs, fontSize: fontSize))
        textView.font = TerminalFont.font(size: fontSize)
        textView.sizeToFit()

        let target = (preserveScroll && !fontChanged) ? savedOrigin : .zero
        DispatchQueue.main.async {
            textView.scroll(target)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }
}

/// The display's text view, which `DisplayFocus` looks for. Takes `:` (to the command line) and
/// Esc, which a text view would otherwise treat as completion.
final class TerminalNSTextView: NSTextView {
    var onCommandLine: () -> Void = {}
    var onLeave: () -> Void = {}

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        if flags.isEmpty, event.keyCode == 53 {
            onLeave()
        } else if flags.isEmpty, event.characters == ":" {
            onCommandLine()
        } else {
            super.keyDown(with: event)
        }
    }
}
