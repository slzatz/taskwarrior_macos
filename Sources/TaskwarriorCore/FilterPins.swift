import Foundation

/// The project, priority and tags every task in a listing must have, read from the filters
/// taskwarrior applies to it: the context's read filter, the report's filter and the typed one.
/// Every row would repeat them (`work` on every row under the `work` context), so the list
/// leaves those badges out.
///
/// Taskwarrior ANDs the filter sources together, so each is read on its own. A source with
/// `or`, `xor`, a negation or parentheses pins nothing. That is always safe: a pin only hides
/// a badge, so a missed pin just shows one.
public struct FilterPins: Equatable, Sendable {
    /// A prefix, as `project:work` is in taskwarrior: it also matches `work.infra` and `workshop`.
    public var project: String?
    public var priority: String?
    public var tags: Set<String>

    public init(project: String? = nil, priority: String? = nil, tags: Set<String> = []) {
        self.project = project
        self.priority = priority
        self.tags = tags
    }

    /// Pins from filter sources, each already split into words.
    public init(sources: [[String]]) {
        var projects = Set<String>()
        var priorities = Set<String>()
        var tags = Set<String>()
        for words in sources where Self.isPlainConjunction(words) {
            for word in words where !word.hasPrefix("rc.") && !word.hasPrefix("rc:") {
                if word.hasPrefix("+"), word.count > 1 {
                    tags.insert(String(word.dropFirst()))
                } else if let value = Self.value(of: "project", in: word) {
                    projects.insert(value)
                } else if let value = Self.value(of: "priority", in: word) {
                    priorities.insert(value)
                }
            }
        }
        self.init(
            project: Self.narrowest(projects),
            priority: priorities.count == 1 ? priorities.first : nil,
            tags: tags
        )
    }

    /// Every `project:` term is a prefix match, so `work` and `work.infra` together pin
    /// `work.infra`. Values that aren't prefixes of one another can't both hold; pin neither.
    static func narrowest(_ projects: Set<String>) -> String? {
        guard let longest = projects.max(by: { $0.count < $1.count }),
              projects.allSatisfy({ longest.hasPrefix($0) }) else { return nil }
        return longest
    }

    /// The project badge's text: nil when it is the pinned project, the rest of the name for a
    /// subproject of it (`work.infra` → `infra` under `project:work`), the whole name otherwise.
    public func shownProject(_ project: String?) -> String? {
        guard let project else { return nil }
        guard let pinned = self.project else { return project }
        if project == pinned { return nil }
        if project.hasPrefix(pinned + ".") { return String(project.dropFirst(pinned.count + 1)) }
        return project
    }

    public func shownPriority(_ priority: String?) -> String? {
        priority == self.priority ? nil : priority
    }

    /// The tags that aren't pinned, by name so the first one shown is the same on every refresh.
    public func shownTags(_ tags: [String]) -> [String] {
        tags.filter { !self.tags.contains($0) }.sorted()
    }

    /// No operator but `and`, and no grouping.
    static func isPlainConjunction(_ words: [String]) -> Bool {
        !words.contains { word in
            ["or", "xor", "not"].contains(word.lowercased()) || word.hasPrefix("!")
                || word.contains("(") || word.contains(")")
        }
    }

    /// Modifiers under which every match shares the value as a prefix (`is` exactly).
    private static let pinningModifiers: Set<String> = ["is", "equals", "startswith", "left"]

    /// The value of `attribute:value` (or `=`), with taskwarrior's abbreviations (`pro:`, `pri:`;
    /// `pr` alone is ambiguous) and modifiers (`project.is:`); nil for another word, a modifier
    /// that doesn't pin (`project.not:`) or an empty value (`project:` means no project).
    static func value(of attribute: String, in word: String) -> String? {
        guard let (modifier, value) = term(of: attribute, word) else { return nil }
        if let modifier, !pinningModifiers.contains(modifier) { return nil }
        return value.isEmpty ? nil : value
    }

    /// True for any `attribute[.modifier]:value` word, whatever the modifier or value.
    static func isTerm(of attribute: String, _ word: String) -> Bool {
        term(of: attribute, word) != nil
    }

    private static func term(of attribute: String, _ word: String) -> (modifier: String?, value: String)? {
        guard let separator = word.firstIndex(where: { $0 == ":" || $0 == "=" }) else { return nil }
        let name = word[..<separator].lowercased().split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard let base = name.first, base.count >= 3, attribute.hasPrefix(base) else { return nil }
        return (name.count == 2 ? String(name[1]) : nil, String(word[word.index(after: separator)...]))
    }
}
