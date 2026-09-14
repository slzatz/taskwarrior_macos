import Foundation

/// The category taskwarrior itself assigns to a command (from `task _zshcommands`).
public enum CommandCategory: String, Sendable, Equatable {
    case report, graphs, operation, metadata, config, context, migration, misc, `internal`
    case unknown
}

public struct CommandInfo: Sendable, Equatable, Hashable {
    public let name: String
    public let category: CommandCategory
    public let summary: String

    public init(name: String, category: CommandCategory, summary: String = "") {
        self.name = name
        self.category = category
        self.summary = summary
    }
}

/// Knows every command taskwarrior accepts (built-in, custom reports, aliases)
/// and how taskwarrior canonicalizes an abbreviated command word.
public struct CommandCatalog: Sendable {
    public let commands: [String: CommandInfo]
    /// alias name -> first word of its expansion (e.g. "rm" -> "delete")
    public let aliases: [String: String]
    public let defaultCommand: String
    public let abbreviationMinimum: Int

    public init(commands: [CommandInfo],
                aliases: [String: String] = [:],
                defaultCommand: String = "next",
                abbreviationMinimum: Int = 2) {
        self.commands = Dictionary(uniqueKeysWithValues: commands.map { ($0.name, $0) })
        self.aliases = aliases
        self.defaultCommand = defaultCommand
        self.abbreviationMinimum = max(1, abbreviationMinimum)
    }

    /// Mirrors taskwarrior's canonicalization: exact name, then alias, then a
    /// unique prefix of at least `abbreviationMinimum` characters.
    public func resolve(_ token: String) -> CommandInfo? {
        if let exact = commands[token] { return exact }
        if let target = aliases[token], let info = commands[target] { return info }
        guard token.count >= abbreviationMinimum, Self.looksLikeCommandWord(token) else { return nil }
        let matches = commands.keys.filter { $0.hasPrefix(token) }
        if matches.count == 1, let only = matches.first { return commands[only] }
        return nil
    }

    /// The command taskwarrior runs when the user gives only a filter (or nothing).
    public var resolvedDefault: CommandInfo? { resolve(defaultCommand) }

    static func looksLikeCommandWord(_ token: String) -> Bool {
        guard let first = token.unicodeScalars.first else { return false }
        guard CharacterSet.letters.contains(first) || first == "_" else { return false }
        return token.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "." || $0 == "-"
        }
    }

    /// Parses the output of `task _zshcommands` ("name:category:description" per line).
    public static func parseZshCommands(_ text: String) -> [CommandInfo] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count >= 2 else { return nil }
            let category = CommandCategory(rawValue: String(parts[1])) ?? .unknown
            let summary = parts.count > 2 ? String(parts[2]) : ""
            return CommandInfo(name: String(parts[0]), category: category, summary: summary)
        }
    }

    /// Used when taskwarrior cannot be queried; matches taskwarrior 3.x's built-ins.
    public static let fallback: CommandCatalog = {
        func group(_ category: CommandCategory, _ names: String) -> [CommandInfo] {
            names.split(separator: " ").map { CommandInfo(name: String($0), category: category) }
        }
        var all: [CommandInfo] = []
        all += group(.operation, "add annotate append delete denotate done duplicate edit log modify prepend purge start stop undo")
        all += group(.metadata, "commands count ids information projects stats tags uuids")
        all += group(.config, "columns config reports show udas")
        all += group(.context, "context")
        all += group(.internal, "_aliases _columns _commands _config _context _get _ids _projects _show _tags _udas _unique _urgency _uuids _version _zshattributes _zshcommands _zshids _zshuuids")
        all += group(.migration, "export import import-v2 synchronize")
        all += group(.misc, "calc colors diagnostics execute help logo news version")
        all += group(.graphs, "burndown.annual burndown.daily burndown.monthly burndown.weekly calendar ghistory.annual ghistory.daily ghistory.monthly ghistory.weekly history.annual history.daily history.monthly history.weekly summary")
        all += group(.report, "active all blocked blocking completed list long ls minimal newest next oldest overdue ready recurring timesheet unblocked waiting")
        return CommandCatalog(
            commands: all,
            aliases: ["rm": "delete", "burndown": "burndown.weekly", "ghistory": "ghistory.monthly", "history": "history.monthly"]
        )
    }()
}
