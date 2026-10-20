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

final class TaskItemTests: XCTestCase {
    let sample = """
    [
    {"id":3,"description":"Call the office","due":"20261012T040000Z","entry":"20261012T090255Z","modified":"20261012T090306Z","priority":"H","project":"work","status":"pending","uuid":"598b5414-e410-49f4-8376-014443da82b2","annotations":[{"entry":"20261012T090306Z","description":"note"}],"tags":["phone"],"start":"20261013T080000Z","urgency":17.6462},
    {"id":0,"description":"Old thing","end":"20261001T000000Z","entry":"20260901T000000Z","status":"completed","uuid":"d8082a49-32b7-4fe7-bbe4-a9aa8ff3eed6","depends":["598b5414-e410-49f4-8376-014443da82b2"],"recur":"weekly","urgency":0,"myuda":"x"}
    ]
    """

    func testDecodeExport() throws {
        let items = try TaskItem.decodeExport(sample)
        XCTAssertEqual(items.count, 2)
        let first = items[0]
        XCTAssertEqual(first.number, 3)
        XCTAssertEqual(first.project, "work")
        XCTAssertEqual(first.priority, "H")
        XCTAssertEqual(first.tags, ["phone"])
        XCTAssertEqual(first.annotations.map(\.description), ["note"])
        XCTAssertFalse(first.hasVimangoNote)
        XCTAssertTrue(first.isActive)
        XCTAssertEqual(first.due, TaskItem.parseDate("20261012T040000Z"))
        XCTAssertTrue(first.isOverdue(now: TaskItem.parseDate("20261012T050000Z")!))
        XCTAssertFalse(first.isOverdue(now: TaskItem.parseDate("20261012T030000Z")!))

        let second = items[1]
        XCTAssertTrue(second.isCompleted)
        XCTAssertFalse(second.isActive)
        XCTAssertTrue(second.isRecurring)
        XCTAssertEqual(second.depends.count, 1)
        XCTAssertNil(second.due)
    }

    func testVimangoNote() throws {
        let json = #"[{"uuid":"598b5414-e410-49f4-8376-014443da82b2","description":"x","annotations":[{"entry":"20261012T090306Z","description":"called"},{"entry":"20261012T090307Z","description":"vimango"}]}]"#
        XCTAssertTrue(try TaskItem.decodeExport(json)[0].hasVimangoNote)
    }

    func testVimangoNoteURL() throws {
        let items = try TaskItem.decodeExport(sample)
        let url = try XCTUnwrap(items[0].vimangoNoteURL)
        XCTAssertEqual(url.scheme, "vimango")
        XCTAssertEqual(url.host, "task-note")
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.map(\.name), ["uuid", "title", "project"])
        XCTAssertEqual(query.map(\.value), ["598b5414-e410-49f4-8376-014443da82b2", "Call the office", "work"])

        let json = #"[{"uuid":"598b5414-e410-49f4-8376-014443da82b2","description":"Plan & pack?"}]"#
        let bare = try XCTUnwrap(TaskItem.decodeExport(json)[0].vimangoNoteURL)
        let bareQuery = try XCTUnwrap(URLComponents(url: bare, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(bareQuery.map(\.name), ["uuid", "title"])
        XCTAssertEqual(bareQuery[1].value, "Plan & pack?")
    }

    func testTaskchampLink() {
        let uuid = "598b5414-e410-49f4-8376-014443da82b2"
        func link(_ string: String) -> TaskchampLink? { URL(string: string).flatMap(TaskchampLink.init(url:)) }
        XCTAssertEqual(link("taskchampdev://task/\(uuid)"), .open(uuid: uuid))
        XCTAssertEqual(link("taskchampdev://task/\(uuid.uppercased())"), .open(uuid: uuid))
        XCTAssertEqual(link("taskchampdev://task/new?uuid=\(uuid)&title=x"), .new)
        XCTAssertNil(link("taskchampdev://task/not-a-uuid"))
        XCTAssertNil(link("taskchampdev://task/"))
        XCTAssertNil(link("taskchampdev://filter/\(uuid)"))
        XCTAssertNil(link("taskchamp://task/\(uuid)"))
        XCTAssertNil(link("taskchampdev://task/\(uuid)/extra"))
    }

    func testParseDate() {
        let date = TaskItem.parseDate("20261012T040506Z")
        XCTAssertEqual(date?.timeIntervalSince1970, 1_791_777_906)
        XCTAssertNil(TaskItem.parseDate("2026-10-12"))
        XCTAssertNil(TaskItem.parseDate("20261012X040506Z"))
    }
}

final class ReportQueryTests: XCTestCase {
    let catalog = CommandCatalog.fallback
    let config = ["report.next.columns": "id,description", "report.list.columns": "id,description"]

    private func report(_ line: String) -> String? {
        ReportQuery.listableReport(for: ParsedCommand.parse(line, catalog: catalog), catalog: catalog, config: config)
    }

    func testListableReports() {
        XCTAssertEqual(report(""), "next")
        XCTAssertEqual(report("project:work"), "next")
        XCTAssertEqual(report("ne"), "next")          // ambiguous word is a filter; default runs
        XCTAssertEqual(report("+home list"), "list")
        XCTAssertNil(report("1 information"))
        XCTAssertNil(report("burndown"))
        XCTAssertNil(report("timesheet"))             // a report, but not a column report
        XCTAssertNil(report("1 done"))
    }

    func testParseAndOrderUUIDs() throws {
        let a = "598b5414-e410-49f4-8376-014443da82b2"
        let b = "D8082A49-32B7-4FE7-BBE4-A9AA8FF3EED6"
        let listing = "\n\(b)\n\(a)\n\nSync required.\n"
        let uuids = ReportQuery.parseUUIDs(listing)
        XCTAssertEqual(uuids, [b.lowercased(), a])

        let items = try TaskItem.decodeExport(TaskItemTests().sample)
        XCTAssertEqual(ReportQuery.ordered(items, by: uuids).map(\.number), [0, 3])
        XCTAssertEqual(ReportQuery.exportArguments(uuids: [a]), [a, "export"])
    }
}

final class FilterPinsTests: XCTestCase {
    private func pins(_ sources: String...) -> FilterPins {
        FilterPins(sources: sources.map(ShellTokenizer.tokenize))
    }

    func testContextReportAndTypedFilter() {
        let p = pins("project:work", "status:pending -WAITING project.not:fact limit:page", "+finance pri:H")
        XCTAssertEqual(p, FilterPins(project: "work", priority: "H", tags: ["finance"], projectExclusions: ["not:fact"]))
    }

    func testAbbreviationsAndModifiers() {
        XCTAssertEqual(pins("pro:work").project, "work")
        XCTAssertEqual(pins("proj.is:work").project, "work")
        XCTAssertEqual(pins("project=work").project, "work")
        XCTAssertEqual(pins("priority.equals:M").priority, "M")
        // "pr" is ambiguous; .not and .has don't pin; an empty value means "no project".
        XCTAssertNil(pins("pr:work").project)
        XCTAssertNil(pins("project.not:work").project)
        XCTAssertNil(pins("project.has:wor").project)
        XCTAssertNil(pins("project:").project)
        XCTAssertNil(pins("due:tomorrow description:pro").project)
        XCTAssertEqual(pins("-home +work").tags, ["work"])
        XCTAssertEqual(pins("rc.context=none +x").tags, ["x"])
    }

    func testOperatorsPinNothingInTheirSource() {
        XCTAssertEqual(pins("project:a or project:b"), FilterPins())
        XCTAssertEqual(pins("(project:a +x)"), FilterPins())
        XCTAssertEqual(pins("!+x"), FilterPins())
        XCTAssertEqual(pins("not +x"), FilterPins())
        // Sources are ANDed, so the plain one still pins.
        XCTAssertEqual(pins("project:a or +x", "project:work"), FilterPins(project: "work"))
        XCTAssertEqual(pins("project:a and +x").project, "a")
    }

    func testProjectExclusions() {
        let p = pins("project.not:Hom project.isnt:work", "project.hasnt:tmp")
        XCTAssertTrue(p.excludes(project: "Homework"))
        XCTAssertTrue(p.excludes(project: "Home.Garden"))
        XCTAssertTrue(p.excludes(project: "work"))
        XCTAssertFalse(p.excludes(project: "work.infra"))
        XCTAssertTrue(p.excludes(project: "a.tmp.b"))
        XCTAssertFalse(p.excludes(project: "meadow"))
        // Only guaranteed exclusions: not inside an or.
        XCTAssertFalse(pins("project.not:fact or +x").excludes(project: "fact"))
    }

    func testConflictingValuesPinNeither() {
        XCTAssertNil(pins("project:work", "project:home").project)
        // Both are prefix matches, so the narrower one holds (the context plus a subproject).
        XCTAssertEqual(pins("project:work", "project:work.infra").project, "work.infra")
        XCTAssertEqual(pins("project:work", "project.is:work").project, "work")
    }

    func testShownBadges() {
        let p = FilterPins(project: "work", priority: "H", tags: ["finance"])
        XCTAssertNil(p.shownProject("work"))
        XCTAssertEqual(p.shownProject("work.infra"), "infra")
        // project:work also matches workshop, which isn't a subproject.
        XCTAssertEqual(p.shownProject("workshop"), "workshop")
        XCTAssertNil(p.shownProject(nil))
        XCTAssertEqual(FilterPins().shownProject("work.infra"), "work.infra")
        XCTAssertNil(p.shownPriority("H"))
        XCTAssertEqual(p.shownPriority("L"), "L")
        XCTAssertEqual(p.shownTags(["review", "finance", "a"]), ["a", "review"])
    }
}

final class ListingViewTests: XCTestCase {
    func testSplitsTheTypedProject() {
        let view = ListingView(report: "next", words: ["+finance", "pro:work.infra", "rc.verbose=0"])
        XCTAssertEqual(view.project, "work.infra")
        XCTAssertEqual(view.otherWords, ["+finance", "rc.verbose=0"])
        XCTAssertEqual(view.filterText, "+finance")
        XCTAssertEqual(view.tokens, ["+finance", "rc.verbose=0", "project:work.infra", "next"])
    }

    func testMenusChangeOnlyTheirPart() {
        let view = ListingView(report: "next", words: ["+finance", "project:work"])
        XCTAssertEqual(view.with(report: "ready").tokens, ["+finance", "project:work", "ready"])
        XCTAssertEqual(view.with(project: "home").tokens, ["+finance", "project:home", "next"])
        XCTAssertEqual(view.with(project: nil).tokens, ["+finance", "next"])
    }

    func testOtherProjectTermsAreReplacedWhenPicking() {
        let view = ListingView(report: "next", words: ["project.not:fact", "+x"])
        XCTAssertNil(view.project)
        XCTAssertEqual(view.filterText, "project.not:fact +x")
        XCTAssertEqual(view.with(project: "work").tokens, ["+x", "project:work", "next"])
        XCTAssertNil(ListingView(report: "next", words: ["project:a", "project:b"]).project)
    }

    func testOperatorsAreReplacedWholeByAProject() {
        let view = ListingView(report: "next", words: ["(project:a", "or", "+x)", "rc.context=none"])
        XCTAssertNil(view.project)
        XCTAssertEqual(view.with(project: "b").tokens, ["rc.context=none", "project:b", "next"])
        XCTAssertEqual(view.with(report: "all").tokens, ["(project:a", "or", "+x)", "rc.context=none", "all"])
    }

    func testListableReports() {
        let config = ["report.next.columns": "id", "report.ls.columns": "id", "report.facts.columns": "id",
                      "report.next.filter": "x", "report.burndown.daily.description": "graph"]
        let reports = ListingView.listableReports(config: config)
        XCTAssertEqual(reports.main, ["facts", "next"])
        XCTAssertEqual(reports.variants, ["ls"])
    }

    func testProjectTree() {
        let tree = ProjectNode.tree(["work.infra.db", "home", "work"])
        XCTAssertEqual(tree.map(\.name), ["home", "work"])
        XCTAssertEqual(tree[1].children.map(\.name), ["work.infra"])
        XCTAssertEqual(tree[1].children[0].children.map(\.label), ["db"])
        // Under the work context only work's insides, as the top level.
        let pinned = ProjectNode.tree(["personal", "work", "work.infra", "work.web"], under: "work")
        XCTAssertEqual(pinned.map(\.name), ["work.infra", "work.web"])
        XCTAssertEqual(ProjectNode.tree(["work", "workshop"], under: "work").map(\.name), ["work", "workshop"])
        XCTAssertEqual(ProjectNode.tree(["work.infra.db", "work.web"], under: "work.infra").map(\.name), ["work.infra.db"])
    }
}
