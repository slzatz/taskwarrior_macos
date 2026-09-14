import Foundation

/// A snapshot of the user's taskwarrior configuration that the app needs:
/// the command catalog, aliases, and the handful of rc settings that affect behaviour.
public struct TaskEnvironment: Sendable {
    public var catalog: CommandCatalog
    public var context: String
    public var bulkThreshold: Int
    /// The user's `verbose` setting, with the noise the app does not want removed.
    public var verboseOverride: String
    /// Raw `name=value` pairs from `task _show`.
    public var config: [String: String]

    /// Overrides applied to every command the app runs.
    public var baseOverrides: [String] {
        [
            "rc.confirmation=off",          // the app asks its own questions
            "rc.allow.empty.filter=no",     // never let "task delete" hit everything
            "rc._forcecolor=on",            // keep taskwarrior's colours without a tty
            "rc.verbose=\(verboseOverride)",
        ]
    }

    public static func load(using runner: TaskRunner) throws -> TaskEnvironment {
        // No overrides here: `_show` reports the *effective* configuration, so an
        // rc.verbose override would be read back as the user's own setting.
        let bare = TaskRunner(executable: runner.executable, baseOverrides: [])
        let commandsResult = try bare.run(["_zshcommands"])
        let showResult = try bare.run(["_show"])
        let config = parseShow(showResult.stdout)

        var commands = CommandCatalog.parseZshCommands(commandsResult.stdout)
        if commands.isEmpty { commands = Array(CommandCatalog.fallback.commands.values) }

        var aliases: [String: String] = [:]
        for (key, value) in config where key.hasPrefix("alias.") {
            let name = String(key.dropFirst("alias.".count))
            if let first = value.split(separator: " ").first { aliases[name] = String(first) }
        }
        if aliases.isEmpty { aliases = CommandCatalog.fallback.aliases }

        let catalog = CommandCatalog(
            commands: commands,
            aliases: aliases,
            defaultCommand: config["default.command"].flatMap { $0.isEmpty ? nil : $0 } ?? "next",
            abbreviationMinimum: Int(config["abbreviation.minimum"] ?? "") ?? 2
        )
        return TaskEnvironment(
            catalog: catalog,
            context: config["context"] ?? "",
            bulkThreshold: Int(config["bulk"] ?? "") ?? 3,
            verboseOverride: verboseOverride(from: config["verbose"] ?? "on"),
            config: config
        )
    }

    /// Parses `task _show` output: one `name=value` per line.
    public static func parseShow(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            result[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        return result
    }

    /// Every verbosity token taskwarrior 3 knows; used to expand `verbose=on`.
    static let allVerboseTokens = [
        "affected", "blank", "context", "default", "edit", "footnote", "header", "label",
        "new-id", "new-uuid", "news", "override", "project", "recur", "special", "sync", "unwait",
    ]
    /// Tokens that only add noise inside the app: override messages (we always pass
    /// overrides) and the "Context 'x' set" line (the status bar shows the context).
    static let suppressedVerboseTokens: Set<String> = ["override", "context"]

    public static func verboseOverride(from value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let tokens: [String]
        switch trimmed {
        case "", "on", "yes", "1", "true":
            tokens = allVerboseTokens
        case "off", "no", "0", "false", "nothing":
            return "nothing"
        default:
            tokens = trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        let kept = tokens.filter { !suppressedVerboseTokens.contains($0) && !$0.isEmpty }
        return kept.isEmpty ? "nothing" : kept.joined(separator: ",")
    }
}
