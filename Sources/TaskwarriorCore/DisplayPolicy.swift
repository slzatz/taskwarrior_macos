import Foundation

/// What the app does with a command's output.
public enum DisplayAction: Sendable, Equatable {
    /// Output replaces the main task display. If `remember` is true the command
    /// becomes the "current view" that is re-run after modifications.
    case replaceDisplay(remember: Bool)
    /// Output goes to the log pane, then the current view is re-run.
    case logAndRefresh
    /// Output goes to the log pane only; the display is left alone.
    case logOnly
    /// The command cannot be run from the app.
    case refuse(String)
}

/// Central table mapping taskwarrior command categories to display behaviour.
/// Adjust here when the rules change; nothing else needs to know.
public enum DisplayPolicy {
    /// Metadata commands whose output is a multi-line report worth showing in the main view.
    static let metadataShownInDisplay: Set<String> = ["information", "projects", "tags", "stats"]

    public static func action(for parsed: ParsedCommand, catalog: CommandCatalog) -> DisplayAction {
        guard let command = parsed.effectiveCommand(in: catalog) else {
            // Unknown default command: let taskwarrior decide and show whatever comes back.
            return .replaceDisplay(remember: true)
        }
        switch command.category {
        case .report, .graphs:
            return .replaceDisplay(remember: true)
        case .metadata:
            return metadataShownInDisplay.contains(command.name)
                ? .replaceDisplay(remember: false)
                : .logOnly
        case .operation:
            if command.name == "edit" {
                return .refuse("'edit' opens a terminal editor and cannot run inside the app.")
            }
            return .logAndRefresh
        case .migration:
            return command.name == "export" ? .logOnly : .logAndRefresh
        case .misc:
            if command.name == "execute" {
                return .refuse("'execute' runs an external command and is not supported in the app.")
            }
            return .logOnly
        case .context, .config, .internal, .unknown:
            return .logOnly
        }
    }
}

/// Decides when the app should ask before running a command, since taskwarrior's
/// own yes/no prompts are disabled.
public enum ConfirmationPolicy {
    public static let alwaysConfirm: Set<String> = ["delete", "purge", "undo"]

    public enum Requirement: Sendable, Equatable {
        case none
        /// Confirm unconditionally (no filter count needed, e.g. undo).
        case always
        /// Count the tasks matched by the filter; confirm when the count is above the threshold.
        case countAbove(Int)
    }

    /// - Parameter bulkThreshold: taskwarrior's `bulk` setting; 0 disables bulk confirmation.
    public static func requirement(for parsed: ParsedCommand, catalog: CommandCatalog, bulkThreshold: Int) -> Requirement {
        guard let command = parsed.effectiveCommand(in: catalog) else { return .none }
        if alwaysConfirm.contains(command.name) {
            return parsed.filter.isEmpty ? .always : .countAbove(0)
        }
        guard command.category == .operation, bulkThreshold > 0, !parsed.filter.isEmpty else { return .none }
        switch command.name {
        case "add", "log":
            return .none
        default:
            return .countAbove(bulkThreshold)
        }
    }
}
