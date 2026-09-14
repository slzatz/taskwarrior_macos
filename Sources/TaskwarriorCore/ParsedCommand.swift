import Foundation

/// A typed command line broken into taskwarrior's `[filter] command [arguments]` shape.
public struct ParsedCommand: Sendable, Equatable {
    /// The tokens passed to taskwarrior (a leading "task" word is removed).
    public let tokens: [String]
    /// Index of the command word within `tokens`, or nil if taskwarrior's default command applies.
    public let commandIndex: Int?
    /// The resolved command, or nil when the default command applies.
    public let command: CommandInfo?
    /// A best-effort description of an unresolvable command word (e.g. ambiguous abbreviation).
    public let unresolvedWord: String?

    public var filter: [String] {
        guard let index = commandIndex else { return tokens }
        return Array(tokens[..<index])
    }

    public var arguments: [String] {
        guard let index = commandIndex else { return [] }
        return Array(tokens[(index + 1)...])
    }

    /// How the command reads back to the user, e.g. `task 5 done`.
    public var displayString: String {
        tokens.isEmpty ? "task" : "task " + ShellTokenizer.join(tokens)
    }

    public init(tokens: [String], commandIndex: Int?, command: CommandInfo?, unresolvedWord: String? = nil) {
        self.tokens = tokens
        self.commandIndex = commandIndex
        self.command = command
        self.unresolvedWord = unresolvedWord
    }

    /// Parses a typed line. Taskwarrior picks the first argument that canonicalizes
    /// to a command name; everything before it is the filter.
    public static func parse(_ line: String, catalog: CommandCatalog) -> ParsedCommand {
        var tokens = ShellTokenizer.tokenize(line)
        if let first = tokens.first, first.lowercased() == "task" {
            tokens.removeFirst()
        }
        for (index, token) in tokens.enumerated() {
            if token.hasPrefix("rc.") || token.hasPrefix("rc:") { continue }
            if let info = catalog.resolve(token) {
                return ParsedCommand(tokens: tokens, commandIndex: index, command: info)
            }
        }
        return ParsedCommand(tokens: tokens, commandIndex: nil, command: nil)
    }

    /// The command that will actually run: the resolved one or taskwarrior's default.
    public func effectiveCommand(in catalog: CommandCatalog) -> CommandInfo? {
        command ?? catalog.resolvedDefault
    }
}
