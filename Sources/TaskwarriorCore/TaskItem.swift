import Foundation

/// One task as `task export` reports it. Only the fields the list view uses are decoded;
/// unknown keys (UDAs, `mask`, `imask`, …) are ignored.
public struct TaskItem: Decodable, Sendable, Identifiable, Equatable {
    public struct Annotation: Decodable, Sendable, Equatable {
        public let entry: Date?
        public let description: String
    }

    public let uuid: String
    /// Working-set id; 0 (or absent) for completed and deleted tasks.
    public let number: Int
    public let description: String
    public let status: String
    public let project: String?
    public let priority: String?
    public let tags: [String]
    public let due: Date?
    public let scheduled: Date?
    public let start: Date?
    public let wait: Date?
    public let until: Date?
    public let entry: Date?
    public let urgency: Double
    public let depends: [String]
    public let recur: String?
    public let annotations: [Annotation]

    public var id: String { uuid }
    public var isActive: Bool { start != nil && status == "pending" }
    public var isRecurring: Bool { recur != nil }
    public var isCompleted: Bool { status == "completed" }
    public var isDeleted: Bool { status == "deleted" }
    public var isPending: Bool { status == "pending" || status == "waiting" }
    /// vimango links a note to a task by annotating it with exactly this text (as taskchamp checks).
    public static let vimangoNoteAnnotation = "vimango"
    public var hasVimangoNote: Bool { annotations.contains { $0.description == Self.vimangoNoteAnnotation } }

    /// Hidden until `wait`. Taskwarrior 3 exports these as `pending` with a future `wait`.
    public func isWaiting(now: Date = Date()) -> Bool {
        guard isPending else { return false }
        return status == "waiting" || (wait.map { $0 > now } ?? false)
    }

    /// Not to be started before `scheduled` (once it passes, the task is ready and unmarked).
    public func isScheduledLater(now: Date = Date()) -> Bool {
        guard let scheduled, isPending else { return false }
        return scheduled > now
    }

    public func isOverdue(now: Date = Date()) -> Bool {
        guard let due, isPending else { return false }
        return due < now
    }

    enum CodingKeys: String, CodingKey {
        case uuid, id, description, status, project, priority, tags, due, scheduled, start, wait, until
        case entry, urgency, depends, recur, annotations
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        number = try c.decodeIfPresent(Int.self, forKey: .id) ?? 0
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "pending"
        project = try c.decodeIfPresent(String.self, forKey: .project)
        priority = try c.decodeIfPresent(String.self, forKey: .priority)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        due = try c.decodeIfPresent(Date.self, forKey: .due)
        scheduled = try c.decodeIfPresent(Date.self, forKey: .scheduled)
        start = try c.decodeIfPresent(Date.self, forKey: .start)
        wait = try c.decodeIfPresent(Date.self, forKey: .wait)
        until = try c.decodeIfPresent(Date.self, forKey: .until)
        entry = try c.decodeIfPresent(Date.self, forKey: .entry)
        urgency = try c.decodeIfPresent(Double.self, forKey: .urgency) ?? 0
        // Taskwarrior 2.x exported depends as a comma-separated string; 3.x uses an array.
        if let list = try? c.decodeIfPresent([String].self, forKey: .depends) {
            depends = list
        } else if let joined = try? c.decodeIfPresent(String.self, forKey: .depends) {
            depends = joined.split(separator: ",").map(String.init)
        } else {
            depends = []
        }
        recur = try c.decodeIfPresent(String.self, forKey: .recur)
        annotations = try c.decodeIfPresent([Annotation].self, forKey: .annotations) ?? []
    }

    /// Decodes the JSON array printed by `task export`.
    public static func decodeExport(_ text: String) throws -> [TaskItem] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let date = parseDate(raw) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(raw)"))
            }
            return date
        }
        return try decoder.decode([TaskItem].self, from: Data(text.utf8))
    }

    /// Parses taskwarrior's `20261012T040000Z` timestamps (always UTC).
    public static func parseDate(_ raw: String) -> Date? {
        let digits = Array(raw.utf8)
        guard digits.count == 16, digits[8] == UInt8(ascii: "T"), digits[15] == UInt8(ascii: "Z") else { return nil }
        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for byte in digits[range] {
                guard byte >= 48, byte <= 57 else { return nil }
                value = value * 10 + Int(byte - 48)
            }
            return value
        }
        guard let year = number(0..<4), let month = number(4..<6), let day = number(6..<8),
              let hour = number(9..<11), let minute = number(11..<13), let second = number(13..<15) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return utcCalendar.date(from: components)
    }

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
}
