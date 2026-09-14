import Foundation

/// Splits a typed command line into arguments the way a shell would, so that
/// `add "Buy milk" due:tomorrow` becomes ["add", "Buy milk", "due:tomorrow"].
public enum ShellTokenizer {
    public static func tokenize(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inToken = false
        var quote: Character? = nil
        var escaped = false

        for ch in input {
            if escaped {
                current.append(ch)
                escaped = false
                inToken = true
                continue
            }
            if let q = quote {
                if ch == q {
                    quote = nil
                } else if ch == "\\" && q == "\"" {
                    escaped = true
                } else {
                    current.append(ch)
                }
                continue
            }
            switch ch {
            case "\\":
                escaped = true
                inToken = true
            case "\"", "'":
                quote = ch
                inToken = true
            case " ", "\t", "\n", "\r":
                if inToken {
                    tokens.append(current)
                    current = ""
                    inToken = false
                }
            default:
                current.append(ch)
                inToken = true
            }
        }
        if inToken { tokens.append(current) }
        return tokens
    }

    /// Re-quotes tokens for display (the inverse of `tokenize`, approximately).
    public static func join(_ tokens: [String]) -> String {
        tokens.map { token in
            if token.isEmpty { return "\"\"" }
            if token.contains(where: { $0 == " " || $0 == "\"" || $0 == "'" || $0 == "\\" }) {
                let escaped = token.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                return "\"\(escaped)\""
            }
            return token
        }.joined(separator: " ")
    }
}
