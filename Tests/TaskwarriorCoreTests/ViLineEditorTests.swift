import XCTest
@testable import TaskwarriorCore

final class ViLineEditorTests: XCTestCase {
    /// Types `keys` (vim notation) into an editor on `text`; the cursor starts on the last character.
    private func edit(_ text: String, _ keys: String) -> ViLineEditor {
        var editor = ViLineEditor(text: text)
        for key in ViLineEditor.keys(keys) { editor.handle(key) }
        return editor
    }

    private func assert(_ text: String, _ keys: String, _ expected: String, cursor: Int? = nil,
                        file: StaticString = #filePath, line: UInt = #line) {
        let editor = edit(text, keys)
        XCTAssertEqual(editor.text, expected, keys, file: file, line: line)
        XCTAssertEqual(editor.mode, .normal, keys, file: file, line: line)
        if let cursor { XCTAssertEqual(editor.cursor, cursor, keys, file: file, line: line) }
    }

    func testStartsInNormalModeOnTheLastCharacter() {
        let editor = ViLineEditor(text: "abc")
        XCTAssertEqual(editor.mode, .normal)
        XCTAssertEqual(editor.cursor, 2)
        XCTAssertEqual(ViLineEditor(text: "").cursor, 0)
    }

    func testMotions() {
        XCTAssertEqual(edit("foo-bar baz", "0w").cursor, 3)
        XCTAssertEqual(edit("foo-bar baz", "0ww").cursor, 4)
        XCTAssertEqual(edit("foo-bar baz", "0W").cursor, 8)
        XCTAssertEqual(edit("foo-bar baz", "0e").cursor, 2)
        XCTAssertEqual(edit("foo-bar baz", "0E").cursor, 6)
        XCTAssertEqual(edit("foo-bar baz", "b").cursor, 8)
        XCTAssertEqual(edit("foo-bar baz", "bb").cursor, 4)
        XCTAssertEqual(edit("foo-bar baz", "bbb").cursor, 3)
        XCTAssertEqual(edit("foo-bar baz", "B").cursor, 8)
        XCTAssertEqual(edit("foo-bar baz", "BB").cursor, 0)
        XCTAssertEqual(edit("  abc", "^").cursor, 2)
        XCTAssertEqual(edit("abcdef", "03l").cursor, 3)
        XCTAssertEqual(edit("abcdef", "09l").cursor, 5)
        XCTAssertEqual(edit("abcdef", "2h").cursor, 3)
        XCTAssertEqual(edit("abcdef", "0$").cursor, 5)
        XCTAssertEqual(edit("abc", "0<Right><Right><Left>").cursor, 1)
    }

    func testFindAndRepeat() {
        XCTAssertEqual(edit("a,b,c,d", "0f,").cursor, 1)
        XCTAssertEqual(edit("a,b,c,d", "0f,;").cursor, 3)
        XCTAssertEqual(edit("a,b,c,d", "0f,;;,").cursor, 3)
        XCTAssertEqual(edit("a,b,c,d", "02f,").cursor, 3)
        XCTAssertEqual(edit("a,b,c,d", "0t,").cursor, 0)
        XCTAssertEqual(edit("a,b,c,d", "0t,;").cursor, 2)
        XCTAssertEqual(edit("a,b,c,d", "F,").cursor, 5)
        XCTAssertEqual(edit("a,b,c,d", "T,").cursor, 6)
        XCTAssertEqual(edit("a,b,c,d", "0fz").cursor, 0)
    }

    func testDeleting() {
        assert("hello world", "0dw", "world", cursor: 0)
        assert("hello world", "0de", " world")
        assert("hello world", "0wD", "hello ", cursor: 5)
        assert("hello world", "x", "hello worl", cursor: 9)
        assert("hello world", "03x", "lo world")
        assert("hello world", "X", "hello word")
        assert("a b c d", "0d2w", "c d")
        assert("a b c d", "02dw", "c d")
        assert("a b c d", "0wd$", "a ")
        assert("a b c d", "$d0", "d")
        assert("a,b,c,d", "0dt,", ",b,c,d")
        assert("a,b,c,d", "0df,", "b,c,d")
        assert("a,b,c,d", "$dF,", "a,b,cd")
        assert("abc", "dd", "", cursor: 0)
        assert("abc", "d<Esc>x", "ab")
    }

    func testChanging() {
        assert("hello world", "0cwbye<Esc>", "bye world", cursor: 2)
        assert("hello world", "0lcwX<Esc>", "hX world")
        assert("ab cd", "0lcwX<Esc>", "aX cd")
        assert("a b c", "0c2wX<Esc>", "X c")
        assert("hello world", "0wCthere<Esc>", "hello there")
        assert("abc", "Sxy<Esc>", "xy")
        assert("abc", "ccxy<Esc>", "xy")
        assert("abc", "0sX<Esc>", "Xbc")
        assert("abc", "02sX<Esc>", "Xc")
        assert("abc", "0rx", "xbc")
        assert("abc", "02rx", "xxc", cursor: 1)
        assert("abc", "05rx", "abc")
        assert("abc", "0~~", "ABc", cursor: 2)
        assert("aBc", "03~", "AbC")
    }

    func testInserting() {
        assert("abc", "Ad<Esc>", "abcd", cursor: 3)
        assert("abc", "Ix<Esc>", "xabc", cursor: 0)
        assert("  abc", "Ix<Esc>", "  xabc")
        assert("abc", "0ix<Esc>", "xabc", cursor: 0)
        assert("abc", "0ax<Esc>", "axbc", cursor: 1)
        assert("abc", "03ix<Esc>", "xxxabc", cursor: 2)
        assert("abc", "Axy<BS>z<Esc>", "abcxz")
        assert("foo bar", "A<C-w>baz<Esc>", "foo baz")
        assert("foo bar", "0wi<C-u>X<Esc>", "Xbar")
        assert("", "ihi<Esc>", "hi", cursor: 1)
    }

    func testTextObjects() {
        assert("one two three", "0wdiw", "one  three")
        assert("one two three", "0wdaw", "one three")
        assert("one two three", "$daw", "one two")
        assert("one two-three", "$diW", "one ")
        assert("foo(bar, baz) qux", "0fbci(x<Esc>", "foo(x) qux")
        assert("foo(bar, baz) qux", "0fbda(", "foo qux")
        assert("f(a (b) c)", "0fadib", "f()")
        assert("f(a (b) c)", "0f(f(lci)x<Esc>", "f(a (x) c)")
        assert("f()", "0f(ci(x<Esc>", "f(x)")
        assert(#"say "hi there" now"#, #"0fhci"yo<Esc>"#, #"say "yo" now"#)
        assert(#"say "hi there" now"#, #"0fhda""#, "say now")
        assert(#"say "hi" now"#, #"0di""#, #"say "" now"#)
        assert("[x] {y} <z>", "0di[wdi{wdi<", "[] {} <>")
        assert("abc", "0diq", "abc")
    }

    func testYankAndPaste() {
        assert("abc", "0xp", "bac", cursor: 1)
        assert("abc", "0yw$p", "abcabc")
        assert("abc", "0yl$2p", "abcaa")
        assert("abc", "0ylP", "aabc", cursor: 0)
        assert("abc", "p", "abc")
    }

    func testUndoAndRedo() {
        assert("abc", "0xx", "c")
        assert("abc", "0xxu", "bc")
        assert("abc", "0xxuu", "abc", cursor: 0)
        assert("abc", "0xxuu<C-r>", "bc")
        assert("abc", "0cwxyz<Esc>u", "abc")
        assert("abc", "0xuu<C-r><C-r>", "bc")
        assert("abc", "0xu0x", "bc")
    }

    func testDotRepeat() {
        assert("a b c d", "0dw..", "d")
        assert("a b c d", "0dw2.", "d")
        assert("foo bar baz", "0cwX<Esc>w.", "X X baz")
        assert("abc", "Ax<Esc>.", "abcxx")
        assert("abcdef", "02x.", "ef")
        assert("abcdef", "02x3.", "f")
        assert("abc", "0rx$.", "xbx")
        assert("aaa", "0~.", "AAa")
        assert("abc", ".", "abc")
        // A yank, motion or undo is not a change and leaves the last one in place.
        assert("a b c d", "0dwywu.", "b c d")
    }

    func testCommitAndCancel() {
        var editor = ViLineEditor(text: "abc")
        XCTAssertEqual(editor.handle(.enter), .commit)
        XCTAssertEqual(editor.handle(.char("d")), .none)
        XCTAssertEqual(editor.handle(.escape), .none, "Esc clears a pending operator first")
        XCTAssertEqual(editor.handle(.char("3")), .none)
        XCTAssertEqual(editor.handle(.escape), .none, "and a count")
        XCTAssertEqual(editor.handle(.escape), .cancel)
        editor.handle(.char("A"))
        editor.handle(.char("d"))
        XCTAssertEqual(editor.handle(.enter), .commit, "Return commits from insert mode too")
        XCTAssertEqual(editor.text, "abcd")
    }

    func testColonAsksForTheCommandLine() {
        var editor = ViLineEditor(text: "abc")
        XCTAssertEqual(editor.handle(.char("d")), .none)
        XCTAssertEqual(editor.handle(.char(":")), .none, "a pending operator is dropped first")
        XCTAssertEqual(editor.handle(.char("x")), .none)
        XCTAssertEqual(editor.text, "ab", "and the next key starts afresh")
        XCTAssertEqual(editor.handle(.char(":")), .commandLine)
        editor.handle(.char("A"))
        XCTAssertEqual(editor.handle(.char(":")), .none)
        XCTAssertEqual(editor.text, "ab:", "in insert mode it is text")
    }

    /// In the app the field types natively in insert mode and hands its text over before Esc.
    func testSyncedInsertIsRepeatable() {
        var editor = ViLineEditor(text: "foo bar")
        for key in ViLineEditor.keys("0cw") { editor.handle(key) }
        XCTAssertEqual(editor.mode, .insert)
        editor.sync(text: "Xy bar", utf16Cursor: 2)
        editor.handle(.escape)
        XCTAssertEqual(editor.text, "Xy bar")
        XCTAssertEqual(editor.cursor, 1)
        for key in ViLineEditor.keys("w.") { editor.handle(key) }
        XCTAssertEqual(editor.text, "Xy Xy")
    }

    func testUTF16Selection() {
        var editor = ViLineEditor(text: "é😀b")
        editor.handle(.char("h"))
        XCTAssertEqual(editor.cursor, 1)
        XCTAssertEqual(editor.selectionUTF16.location, 1)
        XCTAssertEqual(editor.selectionUTF16.length, 2)
        editor.sync(text: "é😀b", utf16Cursor: 3)
        XCTAssertEqual(editor.cursor, 2)
        editor.handle(.char("a"))
        XCTAssertEqual(editor.selectionUTF16.location, 4)
        XCTAssertEqual(editor.selectionUTF16.length, 0)
    }

    func testInsertedText() {
        XCTAssertEqual(ViLineEditor.insertedText(from: Array("ab"), to: Array("aab")), ["a"])
        XCTAssertEqual(ViLineEditor.insertedText(from: Array("ab"), to: Array("abb")), ["b"])
        XCTAssertEqual(ViLineEditor.insertedText(from: Array(" bar"), to: Array("Xy bar")), ["X", "y"])
    }

    func testKeyNotation() {
        XCTAssertEqual(ViLineEditor.keys("ci(<Esc><CR><bs><C-r><lt>x<y"),
                       [.char("c"), .char("i"), .char("("), .escape, .enter, .backspace, .ctrl("r"), .char("<"), .char("x"), .char("<"), .char("y")])
    }
}
