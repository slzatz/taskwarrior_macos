import AppKit
import SwiftUI
import TaskwarriorCore

/// The current report drawn as native rows (styled after taskchamp's task cells):
/// description in the system font, then project / priority / tag badges and a short due date.
/// Follows the system appearance, unlike the verbatim text view.
struct TaskListView: View {
    @Environment(AppModel.self) private var model
    var tasks: [TaskItem]
    var generation: Int
    var preserveScroll: Bool

    @State private var selection: String?

    private var fontSize: Double { model.fontSize }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                List(selection: $selection) {
                    ForEach(tasks) { task in
                        TaskRow(task: task, fontSize: fontSize) { model.openVimangoNote(for: task) }
                            .tag(task.uuid)
                            .id(task.uuid)
                    }
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds(.disabled)
                .contextMenu(forSelectionType: String.self) { uuids in
                    if let task = task(for: uuids) { menu(for: task) }
                } primaryAction: { uuids in
                    if let task = task(for: uuids) { model.perform("information", on: task) }
                }
                .onKeyPress(.space) {
                    guard let task = task(for: selection.map { [$0] } ?? []), task.isPending else { return .ignored }
                    model.perform("done", on: task)
                    return .handled
                }
                .onKeyPress(.return) {
                    guard let task = task(for: selection.map { [$0] } ?? []) else { return .ignored }
                    model.perform("information", on: task)
                    return .handled
                }
                .onChange(of: generation) {
                    if !tasks.contains(where: { $0.uuid == selection }) { selection = nil }
                    if !preserveScroll, let first = tasks.first { proxy.scrollTo(first.uuid, anchor: .top) }
                }
                .overlay {
                    if tasks.isEmpty {
                        ContentUnavailableView("No matching tasks", systemImage: "checkmark.circle")
                    }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(model.listTitle)
                .font(.system(size: fontSize, weight: .semibold))
            Text(tasks.count == 1 ? "1 task" : "\(tasks.count) tasks")
                .font(.system(size: fontSize - 1))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .lineLimit(1)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func task(for uuids: Set<String>) -> TaskItem? {
        guard uuids.count == 1, let uuid = uuids.first else { return nil }
        return tasks.first { $0.uuid == uuid }
    }

    @ViewBuilder
    private func menu(for task: TaskItem) -> some View {
        if task.isPending {
            Button("Done") { model.perform("done", on: task) }
            Button(task.isActive ? "Stop" : "Start") { model.perform(task.isActive ? "stop" : "start", on: task) }
        }
        Button("Show Info") { model.perform("information", on: task) }
        Button(task.hasVimangoNote ? "Open vimango Note" : "Create vimango Note") { model.openVimangoNote(for: task) }
        Divider()
        Button("Copy UUID") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(task.uuid, forType: .string)
        }
        if !task.isDeleted {
            Divider()
            Button("Delete…", role: .destructive) { model.perform("delete", on: task) }
        }
    }
}

private struct TaskRow: View {
    let task: TaskItem
    let fontSize: Double
    let openNote: () -> Void

    private var hasDetails: Bool {
        task.project != nil || task.priority != nil || !task.tags.isEmpty || task.due != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(task.description)
                    .font(.system(size: fontSize + 1))
                    .lineLimit(2)
                    .strikethrough(task.isDeleted, color: .red)
                if task.isActive {
                    Image(systemName: "play.fill")
                        .font(.system(size: fontSize - 2))
                        .foregroundStyle(.tint)
                        .help("Active")
                }
                if task.isRecurring {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: fontSize - 2))
                        .foregroundStyle(.secondary)
                        .help("Recurring")
                }
                Spacer(minLength: 0)
                if task.hasVimangoNote {
                    // Same symbol and accent (indigo) as taskchamp's note button.
                    Image(systemName: "doc.text")
                        .font(.system(size: fontSize - 2))
                        .foregroundStyle(.indigo)
                        .help("Open the vimango note")
                        // A tap gesture, not a Button: List rows capture Button clicks row-wide.
                        .onTapGesture(perform: openNote)
                }
            }
            if hasDetails {
                HStack(spacing: 6) {
                    if let project = task.project {
                        Badge(text: project, color: .blue, fontSize: fontSize)
                    }
                    if let priority = task.priority, let color = priorityColor(priority) {
                        Badge(text: priority, color: color, fontSize: fontSize, tintedText: true)
                    }
                    ForEach(task.tags, id: \.self) { tag in
                        Badge(text: tag, color: .green, fontSize: fontSize)
                    }
                    Spacer()
                    if let due = task.due {
                        Text(DueText.format(due))
                            .font(.system(size: fontSize - 2))
                            .foregroundStyle(dueColor(due))
                    }
                }
                .lineLimit(1)
            }
        }
        // Separators start under the text on every row, not wherever SwiftUI guesses.
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        .padding(.vertical, 4)
        .opacity(task.isCompleted || task.isDeleted ? 0.45 : 1)
    }

    private func priorityColor(_ priority: String) -> Color? {
        switch priority {
        case "H": return .red
        case "M": return .orange
        case "L": return .green
        default: return nil
        }
    }

    private func dueColor(_ due: Date) -> Color {
        if task.isOverdue() { return .red }
        if Calendar.current.isDateInToday(due), task.isPending { return .orange }
        return .secondary
    }
}

/// Small tinted label for project, priority and tags (taskchamp's `TagBadge`).
private struct Badge: View {
    let text: String
    let color: Color
    let fontSize: Double
    /// Draw the text in the badge colour instead of secondary (used for priority).
    var tintedText = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(text)
            .font(.system(size: fontSize - 2))
            .foregroundStyle(tintedText ? AnyShapeStyle(color) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(colorScheme == .dark ? 0.25 : 0.12))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

/// Compact due date: "Today", "Tomorrow", "Yesterday" or "Oct 1"; the year only when it isn't
/// this year, and the time only when it isn't midnight (same rules as taskchamp).
enum DueText {
    static func format(_ due: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        var text: String
        if calendar.isDateInToday(due) {
            text = "Today"
        } else if calendar.isDateInTomorrow(due) {
            text = "Tomorrow"
        } else if calendar.isDateInYesterday(due) {
            text = "Yesterday"
        } else if calendar.isDate(due, equalTo: now, toGranularity: .year) {
            text = due.formatted(.dateTime.month(.abbreviated).day())
        } else {
            text = due.formatted(.dateTime.month(.abbreviated).day().year())
        }
        if due != calendar.startOfDay(for: due) {
            text += " " + due.formatted(date: .omitted, time: .shortened)
        }
        return text
    }
}
