import Foundation

/// A listing split into what the header menus change, the report and the typed project, and
/// the rest of the typed filter, which they keep. The menus never run anything themselves:
/// they build a new command line from this and run it like a typed one.
public struct ListingView: Equatable, Sendable {
    public var report: String
    /// The project the typed filter selects (`project:work.infra`); nil when it selects none,
    /// or when it can't be changed term by term (it has `or` or parentheses).
    public private(set) var project: String?
    /// The other typed words, `rc.` overrides included, in order.
    public private(set) var otherWords: [String]
    /// False when the typed filter has operators, so picking a project replaces all of it.
    public let isPlain: Bool

    /// - Parameter words: the typed filter, including words after the report name (`next +x`).
    public init(report: String, words: [String]) {
        self.report = report
        isPlain = FilterPins.isPlainConjunction(words)
        guard isPlain else {
            otherWords = words
            return
        }
        let projectWords = words.filter { FilterPins.isTerm(of: "project", $0) }
        let values = projectWords.compactMap { FilterPins.value(of: "project", in: $0) }
        if projectWords.count == 1, let value = values.first {
            // A single plain `project:x` is what the menu shows and replaces.
            project = value
            otherWords = words.filter { !FilterPins.isTerm(of: "project", $0) }
        } else {
            // Several, or `project:` / `project.not:x`, are left alone until a project is picked.
            otherWords = words
        }
    }

    /// The line to run: the kept words, then the project, then the report.
    public var tokens: [String] {
        otherWords + (project.map { ["project:\($0)"] } ?? []) + [report]
    }

    /// The typed words the header shows as plain text (everything but the project and overrides).
    public var filterText: String {
        otherWords.filter { !$0.hasPrefix("rc.") && !$0.hasPrefix("rc:") }.joined(separator: " ")
    }

    /// The listing without what `filterText` shows (`clear`, or the header's ✕): the report, the
    /// project and the overrides stay.
    public var cleared: ListingView {
        var copy = self
        copy.otherWords = otherWords.filter { $0.hasPrefix("rc.") || $0.hasPrefix("rc:") }
        return copy
    }

    public func with(report: String) -> ListingView {
        var copy = self
        copy.report = report
        return copy
    }

    /// The same listing narrowed to `project`, or to every project when nil. Every other
    /// project term goes; with operators the whole typed filter goes (overrides stay).
    public func with(project: String?) -> ListingView {
        var copy = self
        copy.project = project
        copy.otherWords = isPlain
            ? otherWords.filter { !FilterPins.isTerm(of: "project", $0) }
            : otherWords.filter { $0.hasPrefix("rc.") || $0.hasPrefix("rc:") }
        return copy
    }

    /// Reports the list can draw (`report.<name>.columns`), by name, with taskwarrior's
    /// column variants of `list` (`ls`, `long`, `minimal`) last: the list ignores columns,
    /// so they differ only in sort.
    public static func listableReports(config: [String: String]) -> (main: [String], variants: [String]) {
        let names = config.keys.compactMap { key -> String? in
            guard key.hasPrefix("report."), key.hasSuffix(".columns") else { return nil }
            return String(key.dropFirst("report.".count).dropLast(".columns".count))
        }.sorted()
        let variants: Set<String> = ["ls", "long", "minimal"]
        return (names.filter { !variants.contains($0) }, names.filter { variants.contains($0) })
    }
}

/// Projects as a hierarchy (`work.infra` under `work`), for nested menus.
public struct ProjectNode: Equatable, Sendable, Identifiable {
    /// The full name, used in `project:` (`work.infra`).
    public let name: String
    public let children: [ProjectNode]
    public var id: String { name }
    /// The last part of the name (`infra`).
    public var label: String { name.split(separator: ".").last.map(String.init) ?? name }

    public init(name: String, children: [ProjectNode] = []) {
        self.name = name
        self.children = children
    }

    /// Builds the tree from `task _projects`, adding parents that have no tasks of their own.
    /// Under a pinned project (the context's) only it and its subprojects are kept, as the menu's
    /// top level, since `_projects` ignores the context.
    public static func tree(_ projects: [String], under pinned: String? = nil) -> [ProjectNode] {
        var all = Set<String>()
        for project in projects where !project.isEmpty {
            var parts: [Substring] = []
            for part in project.split(separator: ".") {
                parts.append(part)
                all.insert(parts.joined(separator: "."))
            }
        }
        // `project:work` is a prefix match in taskwarrior, so `workshop` belongs too.
        if let pinned { all = all.filter { $0.hasPrefix(pinned) } }
        func parent(of name: String) -> String? {
            name.lastIndex(of: ".").map { String(name[..<$0]) }
        }
        func children(of node: String?) -> [ProjectNode] {
            all.filter { name in
                guard let node else { return parent(of: name).map { !all.contains($0) } ?? true }
                return parent(of: name) == node
            }
            .sorted()
            .map { ProjectNode(name: $0, children: children(of: $0)) }
        }
        let roots = children(of: nil)
        // The pinned project is what "All projects" already shows; offer what's inside it.
        if let pinned, roots.count == 1, roots[0].name == pinned {
            return roots[0].children
        }
        return roots
    }
}
