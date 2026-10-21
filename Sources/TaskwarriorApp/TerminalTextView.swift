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
    /// `?` pressed in the view.
    var onHelp: () -> Void = {}

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
        textView.onHelp = onHelp
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

/// The display's text view, which `DisplayFocus` looks for. Takes `:` (to the command line),
/// `?` (help), Esc (which a text view would otherwise treat as completion) and the keys that scroll it: a
/// read-only text view doesn't scroll for arrows or Page Down itself. j / k and Down / Up move a
/// line, Space / Page Down and Page Up a page, g / Home and G / End to the top and bottom.
final class TerminalNSTextView: NSTextView {
    var onCommandLine: () -> Void = {}
    var onLeave: () -> Void = {}
    var onHelp: () -> Void = {}

    private enum Scroll { case lines(CGFloat), pages(CGFloat), top, bottom }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            return super.keyDown(with: event)
        }
        if event.keyCode == 53 { return onLeave() }
        let scroll: Scroll? = switch (event.keyCode, event.characters ?? "") {
        case (125, _), (_, "j"): .lines(1)
        case (126, _), (_, "k"): .lines(-1)
        case (121, _), (_, " "): .pages(1)
        case (116, _): .pages(-1)
        case (115, _), (_, "g"): .top
        case (119, _), (_, "G"): .bottom
        default: nil
        }
        if let scroll {
            self.scroll(scroll)
        } else if event.characters == ":" {
            onCommandLine()
        } else if event.characters == "?" {
            onHelp()
        } else {
            super.keyDown(with: event)
        }
    }

    private func scroll(_ scroll: Scroll) {
        guard let scrollView = enclosingScrollView else { return }
        let clip = scrollView.contentView
        let line = layoutManager.map { $0.defaultLineHeight(for: font ?? .systemFont(ofSize: 13)) } ?? 16
        let page = max(clip.bounds.height - line, line)
        let bottom = max(frame.height - clip.bounds.height, 0)
        var origin = clip.bounds.origin
        switch scroll {
        case .lines(let n): origin.y += n * line
        case .pages(let n): origin.y += n * page
        case .top: origin.y = 0
        case .bottom: origin.y = bottom
        }
        origin.y = min(max(origin.y, 0), bottom)
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
    }
}
