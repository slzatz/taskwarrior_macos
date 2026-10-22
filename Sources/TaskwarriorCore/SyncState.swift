import Foundation

/// What a `task sync` would do, for the status bar's cloud: send local changes up, bring the
/// server's down, both, or nothing; or that the last sync failed. Symbols as in taskchamp's
/// sync button, so the two apps read the same.
public struct SyncState: Equatable, Sendable {
    /// Tasks with changes the server doesn't have yet (tasks, not operations: one edit is
    /// several). Nil when the database can't be read.
    public var unsyncedTasks: Int?
    /// Whether the server has a version this replica hasn't pulled. Nil when unknown: not
    /// probed yet, the probe failed, or a backend the app can't probe.
    public var serverAhead: Bool?
    public var lastSyncFailed: Bool

    public init(unsyncedTasks: Int? = nil, serverAhead: Bool? = nil, lastSyncFailed: Bool = false) {
        self.unsyncedTasks = unsyncedTasks
        self.serverAhead = serverAhead
        self.lastSyncFailed = lastSyncFailed
    }

    private var hasLocalChanges: Bool { (unsyncedTasks ?? 0) > 0 }

    /// A sync would change something, or the last one failed.
    public var isDue: Bool { lastSyncFailed || serverAhead == true || hasLocalChanges }

    /// The SF Symbol. A checkmark only when both sides are known to be in step.
    public var symbol: String {
        if lastSyncFailed { return "exclamationmark.icloud" }
        switch (serverAhead == true, hasLocalChanges) {
        case (true, true): return "arrow.triangle.2.circlepath.icloud"
        case (true, false): return "icloud.and.arrow.down"
        case (false, true): return "icloud.and.arrow.up"
        case (false, false): return serverAhead == false && unsyncedTasks == 0 ? "checkmark.icloud" : "icloud"
        }
    }

    /// A tooltip, e.g. "3 tasks with unsynced changes · the server has changes".
    public var summary: String {
        var parts: [String] = []
        if lastSyncFailed { parts.append("the last sync failed") }
        if let unsyncedTasks, unsyncedTasks > 0 {
            parts.append(unsyncedTasks == 1 ? "1 task with unsynced changes" : "\(unsyncedTasks) tasks with unsynced changes")
        }
        if serverAhead == true { parts.append("the server has changes") }
        if parts.isEmpty {
            parts.append(serverAhead == false && unsyncedTasks == 0 ? "in sync with the server" : "no local changes; server not checked")
        }
        return parts.joined(separator: " · ") + ". Click to sync."
    }
}
