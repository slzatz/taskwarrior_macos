import AppKit
import SwiftUI
import TaskwarriorCore

/// The current report drawn as native one-line rows (styled after taskchamp's task cells):
/// description in the system font, its project / priority / tag badges, and a short due date.
/// Follows the system appearance, unlike the verbatim text view.
struct TaskListView: View {
    @Environment(AppModel.self) private var model
    var tasks: [TaskItem]
    var generation: Int
    var preserveScroll: Bool

    @State private var selection: String?
    /// Takes focus back from a row's description editor when it closes, so the keys work again.
    @FocusState private var listFocused: Bool

    private var fontSize: Double { model.fontSize }

    /// Digits in the widest id, so the id column fits it; 0 when no task has one
    /// (completed and deleted tasks), which leaves the column out.
    private var idDigits: Int {
        let widest = tasks.map(\.number).max() ?? 0
        return widest > 0 ? String(widest).count : 0
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                List(selection: $selection) {
                    ForEach(tasks) { task in
                        TaskRow(task: task, pins: model.listPins, idDigits: idDigits, fontSize: fontSize,
                                isEditing: model.editingUUID == task.uuid,
                                commit: { text in
                                    endEditing(task)
                                    model.setDescription(text, of: task)
                                },
                                cancel: { endEditing(task) }) {
                            model.openVimangoNote(for: task)
                        }
                            .tag(task.uuid)
                            .id(task.uuid)
                    }
                }
                .listStyle(.inset)
                .focused($listFocused)
                .alternatingRowBackgrounds(.disabled)
                .contextMenu(forSelectionType: String.self) { uuids in
                    if let task = task(for: uuids) { menu(for: task) }
                } primaryAction: { uuids in
                    if let task = task(for: uuids) { model.perform("information", on: task) }
                }
                // While a description is edited its keys belong to the text field.
                .onKeyPress(.space) {
                    guard model.editingUUID == nil,
                          let task = task(for: selection.map { [$0] } ?? []), task.isPending else { return .ignored }
                    model.perform("done", on: task)
                    return .handled
                }
                .onKeyPress(.return) {
                    guard model.editingUUID == nil, let task = task(for: selection.map { [$0] } ?? []) else { return .ignored }
                    model.perform("information", on: task)
                    return .handled
                }
                .onKeyPress(keys: ["e"]) { press in
                    guard press.modifiers.isEmpty, model.editingUUID == nil,
                          let task = task(for: selection.map { [$0] } ?? []), !task.isDeleted else { return .ignored }
                    model.editingUUID = task.uuid
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

    /// Report ▾ · context ▾ · project ▾, then the rest of the typed filter and the count.
    /// The menus run a new command line through the model, like a typed one.
    private var header: some View {
        HStack(spacing: 6) {
            if let listing = model.listing {
                reportMenu(listing)
                separator
                contextMenu
                // Only when it can narrow the list (a context pinning a project with no
                // subprojects leaves nothing), or to clear a typed project.
                if listing.project != nil || !model.projectChoices.isEmpty {
                    separator
                    projectMenu(listing)
                }
                if !listing.filterText.isEmpty {
                    separator
                    Text(listing.filterText)
                        .font(.system(size: fontSize, weight: .semibold))
                        .truncationMode(.middle)
                }
            }
            Text(tasks.count == 1 ? "1 task" : "\(tasks.count) tasks")
                .font(.system(size: fontSize - 1))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .lineLimit(1)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var separator: some View {
        Text("·").foregroundStyle(.secondary)
    }

    private func reportMenu(_ listing: ListingView) -> some View {
        let reports = model.reportChoices
        return Menu {
            ForEach(reports.main, id: \.self) { checkItem($0, isOn: $0 == listing.report) { model.showReport($0) } }
            if !reports.variants.isEmpty {
                Section("Same tasks as list, other sort") {
                    ForEach(reports.variants, id: \.self) { checkItem($0, isOn: $0 == listing.report) { model.showReport($0) } }
                }
            }
        } label: {
            menuLabel(listing.report)
        }
        .headerMenuStyle()
        .help("Report")
    }

    private var contextMenu: some View {
        let current = model.currentContext == "none" ? "" : model.currentContext
        return Menu {
            checkItem("No context", isOn: current.isEmpty) { _ in model.switchContext("none") }
            Divider()
            ForEach(model.contexts, id: \.self) { checkItem($0, isOn: $0 == current) { model.switchContext($0) } }
        } label: {
            menuLabel(current.isEmpty ? "no context" : current, dimmed: current.isEmpty)
        }
        .headerMenuStyle()
        .help("Context (changes it for the command line too)")
    }

    private func projectMenu(_ listing: ListingView) -> some View {
        Menu {
            checkItem("All projects", isOn: listing.project == nil) { _ in model.showProject(nil) }
            Divider()
            ProjectMenuItems(nodes: model.projectChoices, selected: listing.project) { model.showProject($0) }
        } label: {
            if let project = listing.project {
                // Relative to the context, as the rows are (`infra` under `work`).
                menuLabel(model.headerPins.shownProject(project) ?? project)
            } else {
                menuLabel("all projects", dimmed: true)
            }
        }
        .headerMenuStyle()
        .help("Project")
    }

    private func menuLabel(_ text: String, dimmed: Bool = false) -> some View {
        Text(text)
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundStyle(dimmed ? .secondary : .primary)
    }

    /// A menu item with a checkmark when it is the current choice.
    private func checkItem(_ title: String, isOn: Bool, action: @escaping (String) -> Void) -> some View {
        Toggle(title, isOn: Binding(get: { isOn }, set: { _ in action(title) }))
    }

    /// Closes `task`'s editor unless another row's has opened since (its focus loss comes late).
    private func endEditing(_ task: TaskItem) {
        guard model.editingUUID == task.uuid else { return }
        model.editingUUID = nil
        listFocused = true
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
        if !task.isDeleted {
            Button("Edit Description") {
                selection = task.uuid
                model.editingUUID = task.uuid
            }
        }
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

/// Projects as nested menus. A project with subprojects is a submenu that starts with the
/// project itself, since a submenu's own title can't be picked.
private struct ProjectMenuItems: View {
    let nodes: [ProjectNode]
    let selected: String?
    let pick: (String) -> Void

    var body: some View {
        ForEach(nodes) { node in
            if node.children.isEmpty {
                item(node)
            } else {
                Menu(node.label) {
                    item(node)
                    Divider()
                    // Type-erased: a view can't contain its own opaque type.
                    AnyView(ProjectMenuItems(nodes: node.children, selected: selected, pick: pick))
                }
            }
        }
    }

    private func item(_ node: ProjectNode) -> some View {
        Toggle(node.label, isOn: Binding(get: { node.name == selected }, set: { _ in pick(node.name) }))
    }
}

private extension View {
    /// A borderless pull-down that reads as part of the header text.
    func headerMenuStyle() -> some View {
        menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.visible)
            .fixedSize()
    }
}

private struct TaskRow: View {
    let task: TaskItem
    /// What the context and filters pin. Every row would repeat it, so it gets no badge.
    let pins: FilterPins
    let idDigits: Int
    let fontSize: Double
    /// The description is a vi-mode field (`ViLineField`): Return commits, Esc in normal mode or
    /// clicking elsewhere cancels.
    let isEditing: Bool
    let commit: (String) -> Void
    let cancel: () -> Void
    let openNote: () -> Void

    /// By name, so the one tag a row has room for is the same on every refresh.
    private var tags: [String] { pins.shownTags(task.tags) }

    /// One line, as in taskchamp: the description and its icons, followed by its badges, then
    /// the due date and note slot at the right edge. The badges and the right edge are laid out
    /// first, so a long description is what gets cut short; its tooltip has the full text.
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if idDigits > 0 {
                idColumn
            }
            if isEditing {
                editor
            } else {
                Text(task.description)
                    .font(.system(size: fontSize + 1))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .strikethrough(task.isDeleted, color: .red)
                    .help(task.description)
            }
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
            badges
                .layoutPriority(1)
            Spacer(minLength: 8)
            trailing
                .layoutPriority(1)
        }
        // Separators start under the text on every row, not wherever SwiftUI guesses.
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        .padding(.vertical, 2)
        .opacity(task.isCompleted || task.isDeleted ? 0.45 : 1)
    }

    private var editor: some View {
        ViLineField(initialText: task.description, fontSize: fontSize + 1, onCommit: commit, onCancel: cancel)
    }

    /// The id for typing commands (`5 done`), right-aligned in a column as wide as the widest
    /// id; blank for a task without one. Row actions still use the uuid, since ids renumber.
    private var idColumn: some View {
        ZStack(alignment: .trailing) {
            Text(String(repeating: "0", count: idDigits)).hidden()
            if task.number > 0 {
                Text(String(task.number)).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: fontSize).monospacedDigit())
        .accessibilityLabel(task.number > 0 ? "Task \(task.number)" : "")
    }

    private var badges: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if let project = pins.shownProject(task.project) {
                Badge(text: project, color: .blue, fontSize: fontSize, maxWidth: 120)
            }
            if let priority = pins.shownPriority(task.priority), let color = priorityColor(priority) {
                Badge(text: priority, color: color, fontSize: fontSize, tintedText: true)
            }
            // Room for one tag; the rest are counted, and named in the count's tooltip.
            if let tag = tags.first {
                Badge(text: tag, color: .green, fontSize: fontSize, maxWidth: 120)
            }
            if tags.count > 1 {
                Badge(text: "+\(tags.count - 1)", color: .green, fontSize: fontSize)
                    .help(tags.dropFirst().joined(separator: ", "))
            }
        }
    }

    /// The due date and note slot, a column at the right edge.
    private var trailing: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let due = task.due {
                Text(DueText.format(due))
                    .font(.system(size: fontSize - 2))
                    .foregroundStyle(dueColor(due))
                    .lineLimit(1)
            } else if let scheduled = task.scheduled {
                // Without a due date, when it's scheduled (the facts report's "Next" column),
                // marked so it doesn't read as a due date.
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Image(systemName: "calendar")
                    Text(DueText.format(scheduled))
                }
                .font(.system(size: fontSize - 2))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help("Scheduled")
            }
            noteSlot
        }
    }

    /// The note icon, or an invisible placeholder of the same width, so dates end at the same
    /// place on every row.
    @ViewBuilder
    private var noteSlot: some View {
        // Same symbol and accent (indigo) as taskchamp's note button.
        let glyph = Image(systemName: "doc.text").font(.system(size: fontSize - 2))
        if task.hasVimangoNote {
            glyph
                .foregroundStyle(.indigo)
                .help("Open the vimango note")
                // A tap gesture, not a Button: List rows capture Button clicks row-wide.
                .onTapGesture(perform: openNote)
        } else {
            glyph
                .hidden()
                .accessibilityHidden(true)
        }
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
    /// Caps a long name at this width; otherwise the badge is as wide as its text.
    var maxWidth: CGFloat?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(text)
            .font(.system(size: fontSize - 2))
            .lineLimit(1)
            // Its own width up to the cap, never stretched to fill the row.
            .frame(maxWidth: maxWidth)
            .fixedSize()
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
