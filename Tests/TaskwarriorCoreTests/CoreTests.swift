import XCTest
@testable import TaskwarriorCore

final class TokenizerTests: XCTestCase {
    func testQuotesAndEscapes() {
        XCTAssertEqual(ShellTokenizer.tokenize(#"add "Buy milk" due:tomorrow"#), ["add", "Buy milk", "due:tomorrow"])
        XCTAssertEqual(ShellTokenizer.tokenize(#"add it\'s\ fine"#), ["add", "it's fine"])
        XCTAssertEqual(ShellTokenizer.tokenize("  5   done  "), ["5", "done"])
        XCTAssertEqual(ShellTokenizer.tokenize(""), [])
    }

    func testJoinRoundTrips() {
        let tokens = ["add", "Buy milk", "due:tomorrow"]
        XCTAssertEqual(ShellTokenizer.tokenize(ShellTokenizer.join(tokens)), tokens)
    }
}

final class ParsedCommandTests: XCTestCase {
    let catalog = CommandCatalog.fallback

    func testFilterCommandArguments() {
        let p = ParsedCommand.parse("task 5 done", catalog: catalog)
        XCTAssertEqual(p.tokens, ["5", "done"])
        XCTAssertEqual(p.command?.name, "done")
        XCTAssertEqual(p.filter, ["5"])
        XCTAssertEqual(p.arguments, [])
        XCTAssertEqual(p.displayString, "task 5 done")
    }

    func testAbbreviationAndAlias() {
        XCTAssertEqual(ParsedCommand.parse("nex", catalog: catalog).command?.name, "next")
        // Ambiguous prefixes (next/news/newest) are filter words to taskwarrior, not commands.
        XCTAssertNil(ParsedCommand.parse("ne", catalog: catalog).command)
        XCTAssertEqual(ParsedCommand.parse("info", catalog: catalog).command?.name, "information")
        XCTAssertEqual(ParsedCommand.parse("3 rm", catalog: catalog).command?.name, "delete")
        XCTAssertEqual(ParsedCommand.parse("sync", catalog: catalog).command?.name, "synchronize")
        // "d" is ambiguous and too short.
        XCTAssertNil(ParsedCommand.parse("d", catalog: catalog).command)
    }

    func testFilterOnlyUsesDefaultCommand() {
        let p = ParsedCommand.parse("project:work +urgent", catalog: catalog)
        XCTAssertNil(p.command)
        XCTAssertEqual(p.filter, ["project:work", "+urgent"])
        XCTAssertEqual(p.effectiveCommand(in: catalog)?.name, "next")
    }

    func testFirstCommandWordWins() {
        let p = ParsedCommand.parse("add list the groceries", catalog: catalog)
        XCTAssertEqual(p.command?.name, "add")
        XCTAssertEqual(p.arguments, ["list", "the", "groceries"])
    }

    func testOverridesAreNotCommands() {
        let p = ParsedCommand.parse("rc.context=none list", catalog: catalog)
        XCTAssertEqual(p.command?.name, "list")
        XCTAssertEqual(p.filter, ["rc.context=none"])
    }
}

final class DisplayPolicyTests: XCTestCase {
    let catalog = CommandCatalog.fallback

    func action(_ line: String) -> DisplayAction {
        DisplayPolicy.action(for: ParsedCommand.parse(line, catalog: catalog), catalog: catalog)
    }

    func testPolicies() {
        XCTAssertEqual(action("next"), .replaceDisplay(remember: true))
        XCTAssertEqual(action("project:work"), .replaceDisplay(remember: true))
        XCTAssertEqual(action("calendar"), .replaceDisplay(remember: true))
        XCTAssertEqual(action("5 info"), .replaceDisplay(remember: false))
        XCTAssertEqual(action("5 done"), .logAndRefresh)
        XCTAssertEqual(action("sync"), .logAndRefresh)
        XCTAssertEqual(action("context personal"), .logOnly)
        XCTAssertEqual(action("show"), .logOnly)
        XCTAssertEqual(action("export"), .logOnly)
        if case .refuse = action("5 edit") {} else { XCTFail("edit should be refused") }
    }

    func testConfirmation() {
        func req(_ line: String, bulk: Int = 3) -> ConfirmationPolicy.Requirement {
            ConfirmationPolicy.requirement(for: ParsedCommand.parse(line, catalog: catalog), catalog: catalog, bulkThreshold: bulk)
        }
        XCTAssertEqual(req("5 delete"), .countAbove(0))
        XCTAssertEqual(req("undo"), .always)
        XCTAssertEqual(req("project:x modify +y"), .countAbove(3))
        XCTAssertEqual(req("project:x modify +y", bulk: 0), .none)
        XCTAssertEqual(req("add foo"), .none)
        XCTAssertEqual(req("next"), .none)
    }
}

final class ANSIParserTests: XCTestCase {
    func testUnderlineAnd256Colours() {
        let runs = ANSIParser.parse("\u{1B}[4mID\u{1B}[0m \u{1B}[38;5;35;48;5;234m65\u{1B}[0m")
        XCTAssertEqual(runs.count, 3)
        XCTAssertEqual(runs[0].text, "ID")
        XCTAssertTrue(runs[0].style.underline)
        XCTAssertEqual(runs[1].text, " ")
        XCTAssertEqual(runs[1].style, .plain)
        XCTAssertEqual(runs[2].style.foreground, .indexed(35))
        XCTAssertEqual(runs[2].style.background, .indexed(234))
    }

    func testAdjacentRunsMerge() {
        let runs = ANSIParser.parse("a\u{1B}[0mb\u{1B}[1mc")
        XCTAssertEqual(runs.map(\.text), ["ab", "c"])
        XCTAssertTrue(runs[1].style.bold)
        XCTAssertEqual(ANSIParser.plainText(runs), "abc")
    }

    func testVerboseOverride() {
        XCTAssertEqual(TaskEnvironment.verboseOverride(from: "affected,override,context,sync"), "affected,sync")
        XCTAssertEqual(TaskEnvironment.verboseOverride(from: "off"), "nothing")
        XCTAssertFalse(TaskEnvironment.verboseOverride(from: "on").contains("override"))
    }
}
