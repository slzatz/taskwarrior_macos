import Foundation

/// Which task the list selects after a command, so the keyboard carries on from a sensible row.
/// `intent` is worked out when the line is run, from the list as it was; `resolve` once the list
/// has been refreshed.
public enum ListLanding: Sendable, Equatable {
    /// The tasks the command named (`5 done`, `<uuid> modify …`), in list order.
    case tasks([String])
    /// A task the command creates (`add`, `log`, `duplicate`).
    case newTask
    /// A different listing: its first row.
    case top
    /// Whatever was selected.
    case keep

    static let creating: Set<String> = ["add", "log", "duplicate"]

    /// - Parameters:
    ///   - current: the listing the list shows, so re-running it keeps the selection.
    ///   - rows: the tasks listed when the line was typed, which its ids refer to.
    public static func intent(for parsed: ParsedCommand, catalog: CommandCatalog, current: ParsedCommand?, rows: [TaskItem]) -> ListLanding {
        let sameView = parsed.tokens == current?.tokens
        guard let command = parsed.effectiveCommand(in: catalog) else { return sameView ? .keep : .top }
        switch command.category {
        case .report, .graphs:
            return sameView ? .keep : .top
        case .operation:
            if creating.contains(command.name) { return .newTask }
            return targets(of: parsed.filter, in: rows).map(ListLanding.tasks) ?? .keep
        default:
            return .keep
        }
    }

    /// The listed tasks a filter of only ids (`5`, `5,7`, `3-5`) and uuids (whole or the 8-digit
    /// short form) names, in list order; nil for any other filter, or when none of them is listed.
    static func targets(of filter: [String], in rows: [TaskItem]) -> [String]? {
        guard !filter.isEmpty else { return nil }
        var ids = Set<Int>()
        var uuids: [String] = []
        for piece in filter.flatMap({ $0.split(separator: ",").map(String.init) }) {
            if let id = Int(piece), id > 0 {
                ids.insert(id)
            } else if let range = idRange(piece) {
                ids.formUnion(range)
            } else if isUUID(piece) {
                uuids.append(piece.lowercased())
            } else {
                return nil
            }
        }
        let named = rows.filter { row in
            (row.number > 0 && ids.contains(row.number)) || uuids.contains { row.uuid.hasPrefix($0) }
        }
        return named.isEmpty ? nil : named.map(\.uuid)
    }

    private static func idRange(_ piece: String) -> ClosedRange<Int>? {
        let ends = piece.split(separator: "-", omittingEmptySubsequences: false)
        guard ends.count == 2, let low = Int(ends[0]), let high = Int(ends[1]), 0 < low, low <= high else { return nil }
        return low...high
    }

    private static func isUUID(_ piece: String) -> Bool {
        guard piece.count == 8 || piece.count == 36 else { return false }
        return piece.allSatisfy { $0.isHexDigit || $0 == "-" } && piece.first != "-"
    }

    /// The uuid to select in the refreshed list; nil only when it is empty.
    /// - Parameters:
    ///   - oldRows: the uuids listed before, in order (for the row that takes a task's place).
    ///   - selected: the selection before.
    public func resolve(oldRows: [String], newRows: [String], selected: String?) -> String? {
        guard let first = newRows.first else { return nil }
        let listed = Set(newRows)
        switch self {
        case .top:
            return first
        case .keep:
            guard let selected else { return first }
            return ListLanding.tasks([selected]).resolve(oldRows: oldRows, newRows: newRows, selected: nil)
        case .newTask:
            let old = Set(oldRows)
            return newRows.first { !old.contains($0) }
                ?? ListLanding.keep.resolve(oldRows: oldRows, newRows: newRows, selected: selected)
        case .tasks(let uuids):
            if let still = uuids.first(where: listed.contains) { return still }
            // Gone (done, deleted, filtered out): the next row that stayed, else the one before.
            guard let start = uuids.compactMap(oldRows.firstIndex(of:)).min() else { return first }
            let gone = Set(uuids)
            return oldRows[start...].first { !gone.contains($0) && listed.contains($0) }
                ?? oldRows[..<start].last { listed.contains($0) }
                ?? first
        }
    }
}
