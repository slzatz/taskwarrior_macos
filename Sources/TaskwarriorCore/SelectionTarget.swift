import Foundation

/// Bare commands that act on existing tasks get the selected task as their filter, like vim's
/// current line: `done` runs as `<uuid> done`, while `5 done` and `+x done` run as typed. Such a
/// line has no other meaning, since the app runs with `rc.allow.empty.filter=no`.
public enum SelectionTarget {
    static let commands: Set<String> = ["annotate", "append", "delete", "denotate", "done",
        "duplicate", "information", "modify", "prepend", "purge", "start", "stop"]

    /// The line names no task itself (only `rc.` overrides come before the command) and its
    /// command acts on existing tasks. The default command never does.
    public static func wantsTarget(_ parsed: ParsedCommand) -> Bool {
        guard let command = parsed.command, commands.contains(command.name) else { return false }
        return parsed.filter.allSatisfy { $0.hasPrefix("rc.") || $0.hasPrefix("rc:") }
    }

    /// `parsed` with `uuid` as its filter, just before the command word (after any overrides).
    public static func targeting(_ parsed: ParsedCommand, uuid: String) -> ParsedCommand {
        guard let index = parsed.commandIndex else { return parsed }
        var tokens = parsed.tokens
        tokens.insert(uuid, at: index)
        return ParsedCommand(tokens: tokens, commandIndex: index + 1, command: parsed.command)
    }
}
