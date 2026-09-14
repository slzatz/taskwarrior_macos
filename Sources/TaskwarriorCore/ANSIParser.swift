import Foundation

public enum ANSIColor: Sendable, Equatable, Hashable {
    /// The 16 standard terminal colours (0-7 normal, 8-15 bright).
    case standard(Int)
    /// xterm 256-colour index (16-255).
    case indexed(Int)
    case rgb(UInt8, UInt8, UInt8)
}

public struct TextStyle: Sendable, Equatable, Hashable {
    public var foreground: ANSIColor?
    public var background: ANSIColor?
    public var bold = false
    public var underline = false
    public var inverse = false

    public static let plain = TextStyle()
    public init() {}
}

public struct StyledRun: Sendable, Equatable {
    public var text: String
    public var style: TextStyle
    public init(text: String, style: TextStyle = .plain) {
        self.text = text
        self.style = style
    }
}

/// Turns taskwarrior's coloured output (SGR escape sequences) into styled runs.
public enum ANSIParser {
    public static func parse(_ input: String) -> [StyledRun] {
        var runs: [StyledRun] = []
        var current = String.UnicodeScalarView()
        var style = TextStyle.plain

        func flush() {
            guard !current.isEmpty else { return }
            let text = String(current)
            if let last = runs.indices.last, runs[last].style == style {
                runs[last].text += text
            } else {
                runs.append(StyledRun(text: text, style: style))
            }
            current = String.UnicodeScalarView()
        }

        let scalars = Array(input.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let s = scalars[i]
            if s == "\u{1B}", i + 1 < scalars.count, scalars[i + 1] == "[" {
                var j = i + 2
                var params = ""
                while j < scalars.count, !(0x40...0x7E).contains(scalars[j].value) {
                    params.unicodeScalars.append(scalars[j])
                    j += 1
                }
                guard j < scalars.count else { break }
                if scalars[j] == "m" {
                    flush()
                    style = apply(sgr: params, to: style)
                }
                i = j + 1
                continue
            }
            if s == "\r" { i += 1; continue }
            current.append(s)
            i += 1
        }
        flush()
        return runs
    }

    public static func plainText(_ runs: [StyledRun]) -> String {
        runs.map(\.text).joined()
    }

    static func apply(sgr params: String, to style: TextStyle) -> TextStyle {
        var style = style
        let codes = params.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        var i = 0
        while i < codes.count {
            let code = codes[i]
            switch code {
            case 0: style = .plain
            case 1: style.bold = true
            case 4: style.underline = true
            case 7: style.inverse = true
            case 22: style.bold = false
            case 24: style.underline = false
            case 27: style.inverse = false
            case 30...37: style.foreground = .standard(code - 30)
            case 39: style.foreground = nil
            case 40...47: style.background = .standard(code - 40)
            case 49: style.background = nil
            case 90...97: style.foreground = .standard(code - 90 + 8)
            case 100...107: style.background = .standard(code - 100 + 8)
            case 38, 48:
                var color: ANSIColor? = nil
                if i + 1 < codes.count, codes[i + 1] == 5, i + 2 < codes.count {
                    let n = codes[i + 2]
                    color = n < 16 ? .standard(n) : .indexed(min(n, 255))
                    i += 2
                } else if i + 1 < codes.count, codes[i + 1] == 2, i + 4 < codes.count {
                    color = .rgb(UInt8(clamping: codes[i + 2]), UInt8(clamping: codes[i + 3]), UInt8(clamping: codes[i + 4]))
                    i += 4
                }
                if code == 38 { style.foreground = color } else { style.background = color }
            default: break
            }
            i += 1
        }
        return style
    }
}
