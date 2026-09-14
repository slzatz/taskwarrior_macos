import AppKit
import SwiftUI
import TaskwarriorCore

/// Font metrics for the monospaced display font.
enum TerminalFont {
    struct Metrics {
        let charWidth: CGFloat
        let lineHeight: CGFloat
    }

    static func font(size: Double, bold: Bool = false) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
    }

    static func metrics(size: Double) -> Metrics {
        let f = font(size: size)
        let width = ("0" as NSString).size(withAttributes: [.font: f]).width
        let layout = NSLayoutManager()
        return Metrics(charWidth: width, lineHeight: layout.defaultLineHeight(for: f))
    }
}

/// Maps ANSI colours to a terminal-like palette. Taskwarrior's default theme
/// (dark row shading, bright text) assumes a dark background, so the display uses one.
enum TerminalPalette {
    static let background = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    static let logBackground = NSColor(srgbRed: 0.09, green: 0.09, blue: 0.10, alpha: 1)
    static let headerBackground = NSColor(srgbRed: 0.13, green: 0.13, blue: 0.14, alpha: 1)
    static let foreground = NSColor(srgbRed: 0.82, green: 0.82, blue: 0.82, alpha: 1)
    static let dimForeground = NSColor(srgbRed: 0.6, green: 0.6, blue: 0.62, alpha: 1)

    private static let standard: [NSColor] = [
        rgb(0x00, 0x00, 0x00), rgb(0xCD, 0x31, 0x31), rgb(0x0D, 0xBC, 0x79), rgb(0xE5, 0xE5, 0x10),
        rgb(0x24, 0x72, 0xC8), rgb(0xBC, 0x3F, 0xBC), rgb(0x11, 0xA8, 0xCD), rgb(0xE5, 0xE5, 0xE5),
        rgb(0x66, 0x66, 0x66), rgb(0xF1, 0x4C, 0x4C), rgb(0x23, 0xD1, 0x8B), rgb(0xF5, 0xF5, 0x43),
        rgb(0x3B, 0x8E, 0xEA), rgb(0xD6, 0x70, 0xD6), rgb(0x29, 0xB8, 0xDB), rgb(0xFF, 0xFF, 0xFF),
    ]

    static func color(_ c: ANSIColor) -> NSColor {
        switch c {
        case .standard(let n):
            return standard[min(max(n, 0), 15)]
        case .indexed(let n):
            if n < 16 { return standard[max(n, 0)] }
            if n >= 232 {
                let level = CGFloat(8 + 10 * (n - 232)) / 255
                return NSColor(srgbRed: level, green: level, blue: level, alpha: 1)
            }
            let steps: [CGFloat] = [0, 95, 135, 175, 215, 255]
            let i = n - 16
            return NSColor(srgbRed: steps[i / 36] / 255, green: steps[(i / 6) % 6] / 255, blue: steps[i % 6] / 255, alpha: 1)
        case .rgb(let r, let g, let b):
            return rgb(r, g, b)
        }
    }

    private static func rgb(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }
}

enum TerminalStyle {
    /// Attributed string for the AppKit text view.
    static func nsAttributedString(_ runs: [StyledRun], fontSize: Double) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for run in runs {
            result.append(NSAttributedString(string: run.text, attributes: attributes(for: run.style, fontSize: fontSize)))
        }
        return result
    }

    static func attributes(for style: TextStyle, fontSize: Double) -> [NSAttributedString.Key: Any] {
        var fg = style.foreground.map(TerminalPalette.color) ?? TerminalPalette.foreground
        var bg = style.background.map(TerminalPalette.color)
        if style.inverse {
            let oldFg = fg
            fg = bg ?? TerminalPalette.background
            bg = oldFg
        }
        var attrs: [NSAttributedString.Key: Any] = [
            .font: TerminalFont.font(size: fontSize, bold: style.bold),
            .foregroundColor: fg,
        ]
        if let bg { attrs[.backgroundColor] = bg }
        if style.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        return attrs
    }

    /// Attributed string for SwiftUI `Text` (used by the log pane).
    static func attributedString(_ runs: [StyledRun], fontSize: Double) -> AttributedString {
        var result = AttributedString()
        for run in runs {
            var piece = AttributedString(run.text)
            var fg = run.style.foreground.map(TerminalPalette.color) ?? TerminalPalette.foreground
            var bg = run.style.background.map(TerminalPalette.color)
            if run.style.inverse {
                let oldFg = fg
                fg = bg ?? TerminalPalette.logBackground
                bg = oldFg
            }
            piece.foregroundColor = Color(nsColor: fg)
            if let bg { piece.backgroundColor = Color(nsColor: bg) }
            piece.font = .system(size: fontSize, weight: run.style.bold ? .bold : .regular, design: .monospaced)
            if run.style.underline { piece.underlineStyle = .single }
            result += piece
        }
        return result
    }
}
