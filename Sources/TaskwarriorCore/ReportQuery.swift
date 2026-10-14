import Foundation

/// Builds the queries behind the structured list view.
///
/// `task export <report>` applies a report's filter and sort but ignores the context, so it
/// cannot reproduce what the report shows. Instead the report itself is run with its columns
/// replaced by `uuid`, which respects context, filter, `limit:` and sort, and the resulting
/// UUIDs are then exported.
public enum ReportQuery {
    /// The report a listing command runs, or nil when its output is not a task list
    /// (graphs, metadata, `timesheet`, anything without `report.<name>.columns`).
    public static func listableReport(for parsed: ParsedCommand, catalog: CommandCatalog, config: [String: String]) -> String? {
        guard let command = parsed.effectiveCommand(in: catalog), command.category == .report else { return nil }
        guard let columns = config["report.\(command.name).columns"], !columns.isEmpty else { return nil }
        return command.name
    }

    /// Overrides that turn `report` into one UUID per line, in report order. Placed after the
    /// app's base overrides, so these win. `footnote` and `sync` are kept for the status line.
    public static func uuidListingOverrides(report: String) -> [String] {
        [
            "rc._forcecolor=off",
            "rc.verbose=footnote,sync",
            "rc.report.\(report).columns=uuid",
            "rc.report.\(report).labels=UUID",
        ]
    }

    /// Arguments for exporting exactly these tasks. Never call with an empty list:
    /// an export with no filter returns every task.
    public static func exportArguments(uuids: [String]) -> [String] {
        precondition(!uuids.isEmpty, "an empty filter would export everything")
        return uuids + ["export"]
    }

    /// UUID lines from the listing; anything else (footnotes, blank lines) is ignored.
    public static func parseUUIDs(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return isUUID(trimmed) ? trimmed.lowercased() : nil
        }
    }

    /// Exported tasks in the order the report listed them.
    public static func ordered(_ items: [TaskItem], by uuids: [String]) -> [TaskItem] {
        let byUUID = Dictionary(items.map { ($0.uuid.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        return uuids.compactMap { byUUID[$0] }
    }

    static func isUUID(_ s: String) -> Bool {
        guard s.count == 36 else { return false }
        for (i, ch) in s.enumerated() {
            if [8, 13, 18, 23].contains(i) {
                guard ch == "-" else { return false }
            } else {
                guard ch.isHexDigit else { return false }
            }
        }
        return true
    }
}
