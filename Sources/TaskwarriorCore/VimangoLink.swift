import Foundation

/// The task ↔ note link shared with taskchamp and VimNotes on iOS. The task's uuid is the link:
/// the note carries it in its synced `taskwarrior_uuid` column (vimango's side, which finds or
/// creates the note), and the task carries a `vimango` annotation once it has a note.
public extension TaskItem {
    /// Asks vimango for this task's note, which it finds by the uuid or creates:
    /// `vimango://task-note?uuid=<uuid>&title=<description>[&project=<project>]`, as taskchamp sends.
    var vimangoNoteURL: URL? {
        var components = URLComponents()
        components.scheme = "vimango"
        components.host = "task-note"
        components.queryItems = [
            URLQueryItem(name: "uuid", value: uuid),
            URLQueryItem(name: "title", value: description),
        ]
        if let project, !project.isEmpty {
            components.queryItems?.append(URLQueryItem(name: "project", value: project))
        }
        return components.url
    }
}

/// A `taskchampdev://task/…` link back to a note's task, as vimango_hybrid's `:task` / File > Open
/// Task sends it (older notes carried it in their text). The scheme is the personal taskchamp
/// build's; this app claims it on the Mac so the same link works on both.
public enum TaskchampLink: Equatable, Sendable {
    /// Show task `uuid` (lowercased, as taskwarrior writes it).
    case open(uuid: String)
    /// `task/new?…`: a note asking for a task to be created. Not supported here yet.
    case new

    public static let scheme = "taskchampdev"

    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, url.host?.lowercased() == "task" else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count == 1 else { return nil }
        if components[0] == "new" {
            self = .new
        } else if let uuid = UUID(uuidString: components[0]) {
            self = .open(uuid: uuid.uuidString.lowercased())
        } else {
            return nil
        }
    }
}
