import Foundation

/// A vi editor for one line of text, behind the list's description field. Pure state, so it is
/// tested without AppKit: the view feeds it keys and shows `text` and `cursor`. In insert mode
/// the view lets the text field type natively (so input methods work) and hands the result back
/// with `sync(text:utf16Cursor:)`; Esc then works out what was inserted, for `.`.
///
/// Normal mode: `h l 0 ^ $ w b e W B E f F t T ; ,`, `x X r s S D C ~ p P`, `i a I A`,
/// `d c y` with a motion or a text object (`iw aw iW aW`, quotes, brackets), `dd cc yy`,
/// counts, `u`, Ctrl-R and `.`. Insert mode: typing, Backspace, arrows, Ctrl-W, Ctrl-U.
/// Return commits from either mode; Esc in normal mode with nothing pending cancels.
public struct ViLineEditor: Sendable {
    public enum Mode: Sendable { case normal, insert }

    public enum Key: Sendable, Equatable {
        case char(Character)
        case ctrl(Character)
        case escape, enter, backspace, left, right, home, end
    }

    public enum Outcome: Sendable, Equatable { case none, commit, cancel }

    public private(set) var chars: [Character]
    /// The character under the cursor in normal mode, the insertion point in insert mode.
    public private(set) var cursor: Int
    public private(set) var mode = Mode.normal
    public var text: String { String(chars) }

    private struct Snapshot: Sendable {
        var chars: [Character]
        var cursor: Int
    }

    private struct Find: Sendable {
        var kind: Character
        var char: Character
    }

    private struct Target {
        var index: Int
        var inclusive: Bool
    }

    // The normal-mode command being typed.
    private var count: Int?
    private var operatorCount: Int?
    private var op: Character?
    /// `f F t T r` waiting for their character, or `i a` after an operator waiting for the object.
    private var pending: Character?
    /// Its keys so far, kept for `.` if it turns out to be a change.
    private var keys: [Key] = []

    private var lastChange: [Key]?
    private var lastFind: Find?
    private var register: [Character] = []
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    /// The text when insert mode began, to tell what was typed.
    private var insertStart: [Character]?
    private var insertRepeat = 1
    private var replaying = false

    public init(text: String) {
        chars = Array(text)
        cursor = max(0, chars.count - 1)
    }

    /// The field's selection in UTF-16 units: the character under the cursor in normal mode
    /// (a block cursor), the insertion point in insert mode.
    public var selectionUTF16: (location: Int, length: Int) {
        let location = String(chars[..<cursor]).utf16.count
        guard mode == .normal, cursor < chars.count else { return (location, 0) }
        return (location, String(chars[cursor]).utf16.count)
    }

    /// Takes the text and caret from the field, which edits natively in insert mode (and may
    /// have been clicked or pasted into in normal mode).
    public mutating func sync(text: String, utf16Cursor: Int) {
        chars = Array(text)
        var offset = 0
        var index = 0
        while index < chars.count, offset < utf16Cursor {
            offset += String(chars[index]).utf16.count
            index += 1
        }
        cursor = mode == .insert ? index : clampNormal(index)
    }

    @discardableResult
    public mutating func handle(_ key: Key) -> Outcome {
        mode == .insert ? handleInsert(key) : handleNormal(key)
    }

    /// Keys in vim's notation, for tests and scripts: `ciwfoo<Esc>`, `<CR>`, `<BS>`, `<C-r>`.
    public static func keys(_ notation: String) -> [Key] {
        var keys: [Key] = []
        var rest = Substring(notation)
        while let c = rest.first {
            if c == "<", let close = rest.firstIndex(of: ">") {
                let name = rest[rest.index(after: rest.startIndex)..<close].lowercased()
                let key: Key? = switch name {
                case "esc": .escape
                case "cr", "enter", "return": .enter
                case "bs": .backspace
                case "left": .left
                case "right": .right
                case "home": .home
                case "end": .end
                case "lt": .char("<")
                default: name.count == 3 && name.hasPrefix("c-") ? .ctrl(name.last!) : nil
                }
                if let key {
                    keys.append(key)
                    rest = rest[rest.index(after: close)...]
                    continue
                }
            }
            keys.append(.char(c))
            rest = rest.dropFirst()
        }
        return keys
    }

    // MARK: Insert mode

    private mutating func handleInsert(_ key: Key) -> Outcome {
        switch key {
        case .escape:
            finishInsert()
        case .enter:
            finishInsert()
            return .commit
        case .char(let c):
            chars.insert(c, at: cursor)
            cursor += 1
        case .backspace:
            if cursor > 0 {
                chars.remove(at: cursor - 1)
                cursor -= 1
            }
        case .left: cursor = max(0, cursor - 1)
        case .right: cursor = min(chars.count, cursor + 1)
        case .home: cursor = 0
        case .end: cursor = chars.count
        case .ctrl("w"):
            let start = prevWordStart(cursor, false)
            chars.removeSubrange(start..<cursor)
            cursor = start
        case .ctrl("u"):
            chars.removeSubrange(0..<cursor)
            cursor = 0
        case .ctrl:
            break
        }
        return .none
    }

    private mutating func startInsert(at index: Int, repeat times: Int) {
        cursor = index
        mode = .insert
        insertStart = chars
        insertRepeat = times
        count = nil
        operatorCount = nil
        op = nil
        pending = nil
    }

    private mutating func finishInsert() {
        let inserted = Self.insertedText(from: insertStart ?? chars, to: chars)
        if insertRepeat > 1, !inserted.isEmpty {
            let more = Array(repeatElement(inserted, count: insertRepeat - 1).joined())
            chars.insert(contentsOf: more, at: cursor)
            cursor += more.count
        }
        if !replaying { keys += inserted.map { Key.char($0) } + [.escape] }
        mode = .normal
        cursor = clampNormal(cursor - 1)
        insertStart = nil
        insertRepeat = 1
        endChange()
    }

    /// What was typed between two versions of the line: the part of `after` that its common
    /// prefix and suffix with `before` leave over.
    static func insertedText(from before: [Character], to after: [Character]) -> [Character] {
        var prefix = 0
        while prefix < before.count, prefix < after.count, before[prefix] == after[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < before.count - prefix, suffix < after.count - prefix,
              before[before.count - 1 - suffix] == after[after.count - 1 - suffix] {
            suffix += 1
        }
        return Array(after[prefix..<(after.count - suffix)])
    }

    // MARK: Normal mode

    private static let motionKeys: Set<Character> = ["h", "l", " ", "0", "^", "$", "w", "W", "b", "B", "e", "E", ";", ","]

    private var effectiveCount: Int { (operatorCount ?? 1) * (count ?? 1) }

    private mutating func handleNormal(_ key: Key) -> Outcome {
        if !replaying { keys.append(key) }
        if let waiting = pending {
            pending = nil
            guard case .char(let c) = key else {
                resetCommand()
                return .none
            }
            switch waiting {
            case "r":
                replaceChars(with: c)
            case "i", "a":
                applyTextObject(around: waiting == "a", c)
            default:
                lastFind = Find(kind: waiting, char: c)
                apply(find(waiting, c, repeating: false).map { Target(index: $0, inclusive: "ft".contains(waiting)) }, key: waiting)
            }
            return .none
        }

        let c: Character
        switch key {
        case .char(let ch): c = ch
        case .left, .backspace: c = "h"
        case .right: c = "l"
        case .home: c = "0"
        case .end: c = "$"
        case .enter:
            resetCommand()
            return .commit
        case .escape:
            let idle = op == nil && count == nil
            resetCommand()
            return idle ? .cancel : .none
        case .ctrl("r"):
            resetCommand()
            redo()
            return .none
        case .ctrl:
            resetCommand()
            return .none
        }

        if c.isASCII, let digit = c.wholeNumberValue, digit > 0 || count != nil {
            count = (count ?? 0) * 10 + digit
            return .none
        }

        if let current = op {
            if c == current {
                operate(current, 0..<chars.count)
            } else if c == "i" || c == "a" || "fFtT".contains(c) {
                pending = c
            } else if Self.motionKeys.contains(c) {
                apply(motion(c), key: c)
            } else {
                resetCommand()
            }
            return .none
        }

        let n = chars.count
        let times = effectiveCount
        switch c {
        case _ where Self.motionKeys.contains(c):
            apply(motion(c), key: c)
        case "f", "F", "t", "T", "r":
            pending = c
        case "d", "c", "y":
            op = c
            operatorCount = count
            count = nil
        case "i":
            beginChange()
            startInsert(at: cursor, repeat: times)
        case "a":
            beginChange()
            startInsert(at: min(n, cursor + 1), repeat: times)
        case "I":
            beginChange()
            startInsert(at: firstNonBlank, repeat: times)
        case "A":
            beginChange()
            startInsert(at: n, repeat: times)
        case "x":
            if n > 0 { operate("d", cursor..<min(n, cursor + times)) } else { resetCommand() }
        case "X":
            if cursor > 0 { operate("d", max(0, cursor - times)..<cursor) } else { resetCommand() }
        case "s":
            operate("c", cursor..<min(n, cursor + times))
        case "S":
            operate("c", 0..<n)
        case "D":
            operate("d", cursor..<n)
        case "C":
            operate("c", cursor..<n)
        case "~":
            toggleCase(times)
        case "p", "P":
            paste(after: c == "p", times: times)
        case "u":
            resetCommand()
            undo()
        case ".":
            repeatLastChange()
        default:
            resetCommand()
        }
        return .none
    }

    private mutating func resetCommand() {
        count = nil
        operatorCount = nil
        op = nil
        pending = nil
        keys = []
    }

    /// Moves to `target`, or with an operator pending applies it from the cursor to there.
    private mutating func apply(_ target: Target?, key: Character) {
        guard let target else {
            resetCommand()
            return
        }
        guard let current = op else {
            cursor = clampNormal(target.index)
            resetCommand()
            return
        }
        let lower = min(cursor, target.index)
        let upper = min(chars.count, max(cursor, target.index) + (target.inclusive ? 1 : 0))
        operate(current, lower..<upper)
    }

    private mutating func applyTextObject(around: Bool, _ c: Character) {
        guard let current = op, let range = textObject(around: around, c) else {
            resetCommand()
            return
        }
        operate(current, range)
    }

    private mutating func operate(_ current: Character, _ range: Range<Int>) {
        if !range.isEmpty { register = Array(chars[range]) }
        switch current {
        case "y":
            cursor = clampNormal(range.lowerBound)
            resetCommand()
        case "d":
            beginChange()
            chars.removeSubrange(range)
            cursor = clampNormal(range.lowerBound)
            endChange()
        default:
            beginChange()
            chars.removeSubrange(range)
            startInsert(at: range.lowerBound, repeat: 1)
        }
    }

    private mutating func replaceChars(with c: Character) {
        let times = effectiveCount
        guard !chars.isEmpty, cursor + times <= chars.count else {
            resetCommand()
            return
        }
        beginChange()
        for i in cursor..<(cursor + times) { chars[i] = c }
        cursor += times - 1
        endChange()
    }

    private mutating func toggleCase(_ times: Int) {
        guard !chars.isEmpty else {
            resetCommand()
            return
        }
        beginChange()
        let end = min(chars.count, cursor + times)
        for i in cursor..<end {
            let s = String(chars[i])
            let toggled = s == s.uppercased() ? s.lowercased() : s.uppercased()
            if toggled.count == 1 { chars[i] = Character(toggled) }
        }
        cursor = clampNormal(end)
        endChange()
    }

    private mutating func paste(after: Bool, times: Int) {
        guard !register.isEmpty else {
            resetCommand()
            return
        }
        beginChange()
        let pasted = Array(repeatElement(register, count: times).joined())
        let at = after && !chars.isEmpty ? cursor + 1 : cursor
        chars.insert(contentsOf: pasted, at: at)
        cursor = at + pasted.count - 1
        endChange()
    }

    // MARK: Undo and repeat

    private mutating func beginChange() {
        undoStack.append(Snapshot(chars: chars, cursor: cursor))
        redoStack.removeAll()
    }

    private mutating func endChange() {
        if undoStack.last?.chars == chars { undoStack.removeLast() }
        if !replaying { lastChange = keys }
        resetCommand()
    }

    private mutating func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(Snapshot(chars: chars, cursor: cursor))
        chars = snapshot.chars
        cursor = clampNormal(snapshot.cursor)
    }

    private mutating func redo() {
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(Snapshot(chars: chars, cursor: cursor))
        chars = snapshot.chars
        cursor = clampNormal(snapshot.cursor)
    }

    /// Plays the last change's keys again; a count given to `.` replaces the one it had.
    private mutating func repeatLastChange() {
        let given = count
        resetCommand()
        guard var replay = lastChange else { return }
        if let given {
            while case .char(let c)? = replay.first, c.isASCII, c.isNumber { replay.removeFirst() }
            replay = String(given).map { Key.char($0) } + replay
        }
        replaying = true
        for key in replay { handle(key) }
        replaying = false
        resetCommand()
    }

    // MARK: Motions

    private func clampNormal(_ index: Int) -> Int {
        chars.isEmpty ? 0 : min(max(0, index), chars.count - 1)
    }

    private var firstNonBlank: Int { chars.firstIndex { !$0.isWhitespace } ?? chars.count }

    private func motion(_ c: Character) -> Target? {
        let n = chars.count
        let times = effectiveCount
        switch c {
        case "h":
            return Target(index: max(0, cursor - times), inclusive: false)
        case "l", " ":
            return Target(index: min(n, cursor + times), inclusive: false)
        case "0":
            return Target(index: 0, inclusive: false)
        case "^":
            return Target(index: firstNonBlank, inclusive: false)
        case "$":
            return Target(index: max(0, n - 1), inclusive: true)
        case "w", "W":
            let big = c == "W"
            if op == "c", cursor < n, !chars[cursor].isWhitespace {
                // `cw` changes to the end of the word, as `ce` would, but not past it from its last letter.
                var i = endOfRun(cursor, big)
                for _ in 1..<times { i = wordEnd(i, big) }
                return Target(index: i, inclusive: true)
            }
            var i = cursor
            for _ in 0..<times { i = nextWordStart(i, big) }
            return Target(index: i, inclusive: false)
        case "e", "E":
            var i = cursor
            for _ in 0..<times { i = wordEnd(i, c == "E") }
            return Target(index: i, inclusive: true)
        case "b", "B":
            var i = cursor
            for _ in 0..<times { i = prevWordStart(i, c == "B") }
            return Target(index: i, inclusive: false)
        case ";", ",":
            guard let last = lastFind else { return nil }
            let kind = c == ";" ? last.kind : Self.reversed(last.kind)
            return find(kind, last.char, repeating: true).map { Target(index: $0, inclusive: kind == "f" || kind == "t") }
        default:
            return nil
        }
    }

    private static func reversed(_ kind: Character) -> Character {
        Character(kind.isUppercase ? kind.lowercased() : kind.uppercased())
    }

    /// `f F t T`: the count-th `target` after (or before) the cursor. Repeated with `;` a `t`
    /// starts one further on, or it would stop where it is.
    private func find(_ kind: Character, _ target: Character, repeating: Bool) -> Int? {
        let n = chars.count
        let forward = kind == "f" || kind == "t"
        let till = kind == "t" || kind == "T"
        let step = forward ? 1 : -1
        var i = cursor
        if till && repeating { i += step }
        for _ in 0..<effectiveCount {
            var j = i + step
            while j >= 0, j < n, chars[j] != target { j += step }
            guard j >= 0, j < n else { return nil }
            i = j
        }
        return till ? i - step : i
    }

    private enum CharClass { case blank, word, punctuation }

    /// vi's word classes: letters, digits and `_` make words, other non-blanks are punctuation
    /// words of their own; for WORDs (`big`) every non-blank counts.
    private func charClass(_ c: Character, _ big: Bool) -> CharClass {
        if c.isWhitespace { return .blank }
        if big || c.isLetter || c.isNumber || c == "_" { return .word }
        return .punctuation
    }

    private func nextWordStart(_ i: Int, _ big: Bool) -> Int {
        let n = chars.count
        guard i < n else { return n }
        var j = i
        let start = charClass(chars[j], big)
        if start != .blank {
            while j < n, charClass(chars[j], big) == start { j += 1 }
        }
        while j < n, chars[j].isWhitespace { j += 1 }
        return j
    }

    private func wordEnd(_ i: Int, _ big: Bool) -> Int {
        let n = chars.count
        var j = i + 1
        while j < n, chars[j].isWhitespace { j += 1 }
        guard j < n else { return max(0, n - 1) }
        return endOfRun(j, big)
    }

    private func prevWordStart(_ i: Int, _ big: Bool) -> Int {
        var j = i - 1
        while j > 0, chars[j].isWhitespace { j -= 1 }
        guard j > 0 else { return 0 }
        return startOfRun(j, big)
    }

    private func startOfRun(_ i: Int, _ big: Bool) -> Int {
        let kind = charClass(chars[i], big)
        var j = i
        while j > 0, charClass(chars[j - 1], big) == kind { j -= 1 }
        return j
    }

    private func endOfRun(_ i: Int, _ big: Bool) -> Int {
        let kind = charClass(chars[i], big)
        var j = i
        while j + 1 < chars.count, charClass(chars[j + 1], big) == kind { j += 1 }
        return j
    }

    // MARK: Text objects

    private func textObject(around: Bool, _ c: Character) -> Range<Int>? {
        switch c {
        case "w", "W": return wordObject(around: around, big: c == "W")
        case "\"", "'", "`": return quoteObject(around: around, c)
        case "(", ")", "b": return bracketObject(around: around, "(", ")")
        case "[", "]": return bracketObject(around: around, "[", "]")
        case "{", "}", "B": return bracketObject(around: around, "{", "}")
        case "<", ">": return bracketObject(around: around, "<", ">")
        default: return nil
        }
    }

    /// `iw` is the run under the cursor; `aw` adds the blanks after it, or before it when there
    /// are none after (on blanks, the word after them).
    private func wordObject(around: Bool, big: Bool) -> Range<Int>? {
        let n = chars.count
        guard cursor < n else { return nil }
        var lower = startOfRun(cursor, big)
        var upper = endOfRun(cursor, big) + 1
        guard around else { return lower..<upper }
        if chars[cursor].isWhitespace {
            if upper < n { upper = endOfRun(upper, big) + 1 }
        } else {
            let end = upper
            while upper < n, chars[upper].isWhitespace { upper += 1 }
            if upper == end {
                while lower > 0, chars[lower - 1].isWhitespace { lower -= 1 }
            }
        }
        return lower..<upper
    }

    /// Quotes pair up from the start of the line; the pair around the cursor, else the next one.
    private func quoteObject(around: Bool, _ quote: Character) -> Range<Int>? {
        let quotes = chars.indices.filter { chars[$0] == quote }
        let pairs = stride(from: 0, to: quotes.count - 1, by: 2).map { (open: quotes[$0], close: quotes[$0 + 1]) }
        guard let pair = pairs.first(where: { $0.open <= cursor && cursor <= $0.close }) ?? pairs.first(where: { $0.open > cursor }) else {
            return nil
        }
        guard around else { return (pair.open + 1)..<pair.close }
        var upper = pair.close + 1
        while upper < chars.count, chars[upper].isWhitespace { upper += 1 }
        return pair.open..<upper
    }

    /// The innermost bracket pair around the cursor (a bracket under the cursor counts as inside).
    private func bracketObject(around: Bool, _ open: Character, _ close: Character) -> Range<Int>? {
        let n = chars.count
        guard cursor < n else { return nil }
        var lower = cursor
        if chars[cursor] != open {
            var depth = 0
            var j = cursor - 1
            while j >= 0 {
                if chars[j] == close {
                    depth += 1
                } else if chars[j] == open {
                    if depth == 0 { break }
                    depth -= 1
                }
                j -= 1
            }
            guard j >= 0 else { return nil }
            lower = j
        }
        var depth = 0
        var k = lower + 1
        while k < n {
            if chars[k] == open {
                depth += 1
            } else if chars[k] == close {
                if depth == 0 { break }
                depth -= 1
            }
            k += 1
        }
        guard k < n else { return nil }
        return around ? lower..<(k + 1) : (lower + 1)..<k
    }
}
