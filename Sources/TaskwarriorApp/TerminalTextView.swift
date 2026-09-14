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

    final class Coordinator {
        var generation = -1
        var fontSize = 0.0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
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

        let textView = NSTextView(frame: .zero, textContainer: container)
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
        guard let textView = scrollView.documentView as? NSTextView else { return }
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
