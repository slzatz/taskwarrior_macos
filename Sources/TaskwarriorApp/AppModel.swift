import SwiftUI
import Observation
import TaskwarriorCore

struct LogEntry: Identifiable {
    let id = UUID()
    let command: String
    let runs: [StyledRun]
    let isError: Bool
}

enum DisplayMode: String {
    /// Reports are drawn as native task rows; everything else falls back to text.
    case list
    /// Taskwarrior's own coloured output, verbatim.
    case text
}

struct Confirmation: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let proceed: @MainActor () -> Void
}

/// All application state. Views read from it; only `AppModel` talks to taskwarrior.
@MainActor
@Observable
final class AppModel {
    // MARK: Display
    private(set) var display: [StyledRun] = []
    /// Incremented whenever `display` changes so the AppKit text view knows to reload.
    private(set) var displayGeneration = 0
    /// True when the new display content is a refresh of the same view (keep scroll position).
    private(set) var displayIsRefresh = false
    /// The listing command that is re-run after modifications (e.g. `task project:work next`).
    private(set) var currentView: ParsedCommand?
    /// The current report's tasks when it is shown as a list; nil when `display` text is shown.
    private(set) var tasks: [TaskItem]? {
        didSet {
            if let uuid = editingUUID, tasks?.contains(where: { $0.uuid == uuid }) != true { editingUUID = nil }
        }
    }
    /// The listing behind the list, split into what the header menus change.
    private(set) var listing: ListingView?
    /// What the context and filters pin for every task in the list, so rows leave it out.
    private(set) var listPins = FilterPins()
    /// The task whose description is being edited in its row, if any.
    var editingUUID: String?
    /// The list's selected task. Kept while text is shown, so leaving `information` lands on it.
    var selectedUUID: String?
    /// The tasks last listed, in order, also while text is shown: what typed ids refer to, and
    /// where a task that leaves the list was (`ListLanding`).
    private var listed: [TaskItem] = []
    /// Where the next list lands, set by the queued work for a typed line; see `ListLanding`.
    private var pendingLanding = ListLanding.keep
    /// The text shown is a one-off (`information`), not the current view; Esc goes back to it.
    private(set) var displayIsTransient = false
    /// The task an `information` page shows, which bare commands act on there (`SelectionTarget`).
    private var shownTaskUUID: String?
    /// Every project (`task _projects`, which ignores the context), for the header's menu.
    private(set) var projects: [String] = []
    /// Defined contexts (`task _context`), for the header's menu.
    private(set) var contexts: [String] = []
    var displayMode: DisplayMode {
        didSet {
            guard displayMode != oldValue else { return }
            defaults.set(displayMode.rawValue, forKey: Keys.displayMode)
            refreshCurrentView()
        }
    }

    // MARK: Log / status
    private(set) var log: [LogEntry] = []
    /// One-line status shown in the output pane header (latest message from any command).
    private(set) var statusLine = ""
    private(set) var statusIsError = false
    var logExpanded: Bool { didSet { defaults.set(logExpanded, forKey: Keys.logExpanded) } }
    private(set) var currentContext = ""
    /// The current context's read filter, e.g. `project:work`; empty without a context.
    private var contextFilter = ""
    private(set) var isRunning = false
    var pendingConfirmation: Confirmation?
    /// The help sheet (`help`, `?`, Help menu).
    var helpOpen = false

    // MARK: Input
    var commandText = ""
    private(set) var history: [String] { didSet { defaults.set(Array(history.suffix(500)), forKey: Keys.history) } }
    private(set) var focusRequest = 0
    /// Bumped to give the list (or the text view) keyboard focus; see `DisplayFocus`.
    private(set) var displayFocusRequest = 0

    // MARK: Appearance / geometry
    var fontSize: Double {
        didSet {
            defaults.set(fontSize, forKey: Keys.fontSize)
            recomputeGeometry()
        }
    }
    static let defaultFontSize = 13.0
    /// Terminal geometry taskwarrior is told about, derived from the text view size.
    private(set) var columns = 0
    private(set) var rows = 0
    private var displaySize = CGSize.zero

    // MARK: Internals
    private let defaults = UserDefaults.standard
    private var runner: TaskRunner?
    private var environment: TaskEnvironment?
    private var catalog: CommandCatalog { environment?.catalog ?? .fallback }
    private var queueTail: Task<Void, Never>?
    private var queueGeneration = 0
    private var geometryRefresh: Task<Void, Never>?
    private var bootstrapped = false
    /// Links that arrived before `bootstrap` found taskwarrior (a link that launches the app
    /// does); handled once it has.
    private var pendingURLs: [URL] = []

    private enum Keys {
        static let fontSize = "fontSize"
        static let logExpanded = "logExpanded"
        static let history = "history"
        static let taskExecutable = "taskExecutable"
        static let displayMode = "displayMode"
    }

    init() {
        let stored = defaults.double(forKey: Keys.fontSize)
        fontSize = stored > 0 ? stored : Self.defaultFontSize
        logExpanded = defaults.object(forKey: Keys.logExpanded) as? Bool ?? true
        history = defaults.stringArray(forKey: Keys.history) ?? []
        displayMode = defaults.string(forKey: Keys.displayMode).flatMap(DisplayMode.init) ?? .list
    }

    // MARK: - Lifecycle

    func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true

        let preferred = defaults.string(forKey: Keys.taskExecutable)
        guard let executable = await Task.detached(operation: { TaskRunner.locate(preferred: preferred) }).value else {
            showMessage("Could not find the 'task' executable.\n\nInstall taskwarrior (e.g. brew install task) or set its path with:\n  defaults write \(Bundle.main.bundleIdentifier ?? "TaskwarriorApp") taskExecutable /path/to/task")
            return
        }
        let probe = TaskRunner(executable: executable)
        let loaded = await Task.detached(operation: { try? TaskEnvironment.load(using: probe) }).value
        guard let env = loaded else {
            showMessage("Found \(executable.path) but could not read its configuration.")
            return
        }
        environment = env
        currentContext = env.context
        contextFilter = env.config["context.\(env.context).read"] ?? env.config["context.\(env.context)"] ?? ""
        runner = TaskRunner(executable: executable, baseOverrides: env.baseOverrides)

        if let names = await quietLines(["_context"]) { contexts = names }

        // Wait briefly for the view to report its size so the first listing fits the window.
        for _ in 0..<25 where columns == 0 {
            try? await Task.sleep(for: .milliseconds(20))
        }
        // The initial view is whatever `task` alone shows (the user's default.command).
        enqueue(ParsedCommand.parse("", catalog: catalog), action: .replaceDisplay(remember: true))
        // The keyboard starts in the list, on its first task.
        enqueueWork { [weak self] in self?.focusDisplay() }
        let queued = pendingURLs
        pendingURLs = []
        queued.forEach(handle(url:))
    }

    // MARK: - Commands from the UI

    /// Runs the typed line. Like vim's `:` line, Return always goes back to the list, whatever
    /// ran; focus moves at once, so keys typed during a slow `sync` reach the list.
    func submit() {
        focusDisplay()
        let line = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        commandText = ""
        guard !line.isEmpty else { return }
        if history.last != line { history.append(line) }
        run(line: line)
    }

    func run(line: String) {
        if AppCommand(line: line) == .help {
            helpOpen = true
            return
        }
        guard runner != nil else {
            appendLog(command: line, text: "taskwarrior is not available.", isError: true)
            return
        }
        var parsed = ParsedCommand.parse(line, catalog: catalog)
        // `done` alone means the selected task, like an ex command on vim's current line.
        if SelectionTarget.wantsTarget(parsed) {
            guard let uuid = targetUUID else {
                appendLog(command: parsed.displayString, text: "No task selected. Select one in the list, or name it: 5 done, +home done.", isError: true)
                return
            }
            parsed = SelectionTarget.targeting(parsed, uuid: uuid)
        }
        let action = DisplayPolicy.action(for: parsed, catalog: catalog)
        let landing = ListLanding.intent(for: parsed, catalog: catalog, current: currentView, rows: listed)
        if case .refuse(let reason) = action {
            appendLog(command: parsed.displayString, text: reason, isError: true)
            return
        }
        let requirement = ConfirmationPolicy.requirement(for: parsed, catalog: catalog, bulkThreshold: environment?.bulkThreshold ?? 0)
        switch requirement {
        case .none:
            enqueue(parsed, action: action, landing: landing)
        case .always:
            enqueueWork { [weak self] in
                self?.ask(parsed, action: action, landing: landing, message: "Run “\(parsed.displayString)”?")
            }
        case .countAbove(let threshold):
            // Named by its description rather than a uuid nobody reads.
            let subject = namedTask(parsed).map { task in
                "\(parsed.effectiveCommand(in: catalog)?.name.capitalized ?? "Change") “\(task.description)”?"
            }
            enqueueWork { [weak self] in
                guard let self else { return }
                let count = await self.countMatches(filter: parsed.filter)
                if let count, count > threshold {
                    let noun = count == 1 ? "task" : "tasks"
                    let message = count == 1 ? subject : nil
                    self.ask(parsed, action: action, landing: landing, message: message ?? "“\(parsed.displayString)” will affect \(count) \(noun).")
                } else {
                    // At 0, taskwarrior reports "No matches" itself.
                    self.pendingLanding = landing
                    await self.execute(parsed, action: action)
                    self.pendingLanding = .keep
                }
            }
        }
    }

    // MARK: Header menus
    // Each builds a command line and runs it like a typed one, so it shows in the status line
    // and becomes the current view.

    /// Reports the header offers; see `ListingView.listableReports`.
    var reportChoices: (main: [String], variants: [String]) {
        ListingView.listableReports(config: environment?.config ?? [:])
    }

    /// What the context and report pin before anything is typed; the project menu works within it.
    var headerPins: FilterPins {
        let report = listing.map { environment?.config["report.\($0.report).filter"] ?? "" } ?? ""
        return FilterPins(sources: [contextFilter, report].map(ShellTokenizer.tokenize))
    }

    /// The projects the header offers: those the context and report allow, nested.
    var projectChoices: [ProjectNode] {
        let pins = headerPins
        return ProjectNode.tree(projects.filter { !pins.excludes(project: $0) }, under: pins.project)
    }

    func showReport(_ report: String) {
        guard let listing else { return }
        run(listing: listing.with(report: report))
    }

    /// Narrows the listing to `project`, or widens it to all projects when nil.
    func showProject(_ project: String?) {
        guard let listing else { return }
        run(listing: listing.with(project: project))
    }

    /// Switches context (`none` clears it) and shows the listing again. A context is picked
    /// here on purpose, so unlike a typed `task context` it refreshes, and drops the typed
    /// project, which belongs to the old context.
    func switchContext(_ name: String) {
        run(line: "context \(name)")
        guard let listing else { return }
        run(listing: listing.with(project: nil))
    }

    private func run(listing: ListingView) {
        run(line: ShellTokenizer.join(listing.tokens))
    }

    func refreshCurrentView() {
        guard let view = currentView else { return }
        enqueue(view, action: .replaceDisplay(remember: true))
    }

    func focusCommandField() { focusRequest += 1 }

    /// Gives the keyboard to the list, or to the text view when text is shown.
    func focusDisplay() { displayFocusRequest += 1 }

    /// Esc in the text view: from a one-off such as `information`, back to the current view,
    /// which lands on the task that was selected.
    func leaveTransientDisplay() {
        guard displayIsTransient else { return }
        refreshCurrentView()
    }

    /// Runs a command on one task from the list, e.g. `done` or `start`. Goes through the same
    /// path as a typed line so confirmation, logging and refresh rules all apply. The UUID is
    /// used because ids are renumbered by the refresh that follows each modification.
    func perform(_ command: String, on task: TaskItem) {
        run(line: "\(task.uuid) \(command)")
    }

    /// Replaces the task's description with `text`, from the row's inline editor. The text goes
    /// through as one `description:` argument, so words in it like `+x` or `due:` stay text.
    /// Nothing runs when it is empty or unchanged.
    func setDescription(_ text: String, of task: TaskItem) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != task.description else { return }
        perform("modify " + ShellTokenizer.join(["description:" + text]), on: task)
    }

    /// Opens (or has vimango create) the task's note via `vimango://task-note`, as taskchamp's
    /// note button does. The `vimango` annotation is added only once the URL has been taken, and
    /// only if the task doesn't carry it yet, through `perform` like any other row action.
    func openVimangoNote(for task: TaskItem) {
        guard let url = task.vimangoNoteURL else { return }
        Task {
            do {
                _ = try await NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration())
            } catch {
                appendLog(command: "vimango note", text: "Can't open vimango: \(error.localizedDescription)\nRun vimango_hybrid once so macOS knows it opens vimango:// links.", isError: true)
                return
            }
            if !task.hasVimangoNote {
                perform("annotate \(TaskItem.vimangoNoteAnnotation)", on: task)
            }
        }
    }

    /// Handles a link opened from outside, e.g. `taskchampdev://task/<uuid>` from vimango_hybrid's Open Task.
    func handle(url: URL) {
        guard runner != nil else {
            pendingURLs.append(url)
            return
        }
        switch TaskchampLink(url: url) {
        case .open(let uuid):
            run(line: "\(uuid) information")
        case .new:
            appendLog(command: url.absoluteString, text: "Creating a task from a vimango note isn't supported on the Mac yet.", isError: true)
        case nil:
            appendLog(command: url.absoluteString, text: "Not a link this app understands.", isError: true)
        }
    }

    /// Resolves once every queued command has finished (used by scripted runs).
    func waitUntilIdle() async {
        while true {
            let generation = queueGeneration
            guard let tail = queueTail else { return }
            await tail.value
            if queueGeneration == generation { return }
        }
    }
    func clearLog() { log.removeAll() }

    func adjustFontSize(by delta: Double) {
        fontSize = min(max(fontSize + delta, 8), 40)
    }

    func resetFontSize() { fontSize = Self.defaultFontSize }

    /// Called by the display view whenever its size changes.
    func displaySizeChanged(_ size: CGSize) {
        guard size != displaySize else { return }
        displaySize = size
        recomputeGeometry()
    }

    // MARK: - Execution

    private func ask(_ parsed: ParsedCommand, action: DisplayAction, landing: ListLanding, message: String) {
        let title = "Confirm \(parsed.effectiveCommand(in: catalog)?.name ?? "command")"
        if ProcessInfo.processInfo.environment["TASKWARRIOR_APP_DUMP"] == "1" {
            FileHandle.standardError.write(Data("confirm: \(title): \(message)\n".utf8))
        }
        pendingConfirmation = Confirmation(title: title, message: message) { [weak self] in
            self?.enqueue(parsed, action: action, landing: landing)
        }
    }

    private func enqueue(_ parsed: ParsedCommand, action: DisplayAction, landing: ListLanding = .keep) {
        enqueueWork { [weak self] in
            self?.pendingLanding = landing
            await self?.execute(parsed, action: action)
            // Unused when nothing was listed (a failed command): not for a later refresh.
            self?.pendingLanding = .keep
        }
    }

    /// Commands run strictly one after another so a slow `sync` cannot interleave with a listing.
    private func enqueueWork(_ work: @escaping @MainActor () async -> Void) {
        let previous = queueTail
        queueGeneration += 1
        queueTail = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    private func execute(_ parsed: ParsedCommand, action: DisplayAction) async {
        guard let runner else { return }
        isRunning = true
        defer { isRunning = false }

        if case .replaceDisplay(let remember) = action, displayMode == .list,
           let report = ReportQuery.listableReport(for: parsed, catalog: catalog, config: environment?.config ?? [:]),
           await showList(parsed, report: report, remember: remember) {
            return
        }

        let result = await runInBackground(runner, arguments: parsed.tokens, height: height(for: parsed))
        switch result {
        case .failure(let error):
            appendLog(command: parsed.displayString, text: error.localizedDescription, isError: true)
            return
        case .success(let output):
            switch action {
            case .replaceDisplay(let remember):
                displayIsRefresh = remember && currentView?.tokens == parsed.tokens
                display = ANSIParser.parse(output.primaryOutput)
                shownTaskUUID = remember || !output.succeeded ? nil : shownTask(by: parsed)
                // So Esc back to the list lands on it.
                if let shownTaskUUID { selectedUUID = shownTaskUUID }
                tasks = nil
                displayIsTransient = !remember
                displayGeneration += 1
                if remember { currentView = parsed }
                if !output.succeeded {
                    appendLog(command: parsed.displayString, text: output.stderr, isError: true)
                } else {
                    // Listings only update the status line (e.g. "Sync required."), never the log.
                    setStatus(command: parsed.displayString, text: output.stderr, isError: false)
                }
            case .logAndRefresh:
                appendLog(command: parsed.displayString, text: output.combinedOutput, isError: !output.succeeded)
                if output.succeeded, let view = currentView {
                    await execute(view, action: .replaceDisplay(remember: true))
                }
            case .logOnly:
                appendLog(command: parsed.displayString, text: output.combinedOutput, isError: !output.succeeded)
            case .refuse:
                break
            }
            if let category = parsed.effectiveCommand(in: catalog)?.category, category == .context || category == .config {
                await refreshContextName()
            }
        }
    }

    /// Shows a report as task rows: the report run with only a uuid column gives exactly the
    /// rows and order the CLI would show (context, filter, limit, sort), then those tasks are
    /// exported. Returns false when the text view should be used instead (e.g. a filter error).
    private func showList(_ parsed: ParsedCommand, report: String, remember: Bool) async -> Bool {
        guard let runner else { return false }
        let listing = await runInBackground(runner, arguments: parsed.tokens, height: height(for: parsed),
                                            extra: ReportQuery.uuidListingOverrides(report: report))
        guard case .success(let output) = listing else { return false }
        let uuids = ReportQuery.parseUUIDs(output.stdout)
        var items: [TaskItem] = []
        if uuids.isEmpty {
            // "No matches." exits non-zero; any other failure is shown verbatim as text.
            guard output.succeeded || output.combinedOutput.contains("No matches") else { return false }
        } else {
            let exported = await runInBackground(runner, arguments: ReportQuery.exportArguments(uuids: uuids), height: 0, extra: ["rc.verbose=nothing"])
            guard case .success(let json) = exported, json.succeeded,
                  let decoded = try? TaskItem.decodeExport(json.stdout) else { return false }
            items = ReportQuery.ordered(decoded, by: uuids)
        }
        displayIsRefresh = remember && currentView?.tokens == parsed.tokens
        let newRows = items.map(\.uuid)
        selectedUUID = pendingLanding.resolve(oldRows: listed.map(\.uuid), newRows: newRows, selected: selectedUUID)
        pendingLanding = .keep
        listed = items
        tasks = items
        shownTaskUUID = nil
        displayIsTransient = false
        // Words after a report's name filter it too (`next +finance`).
        let typed = parsed.filter + parsed.arguments
        self.listing = ListingView(report: report, words: typed)
        listPins = FilterPins(sources: listingFilters(report: report, typed: typed))
        // Cheap (about 13 ms), and any modification may have added a project.
        if let names = await quietLines(["_projects"]) { projects = names }
        displayGeneration += 1
        if remember { currentView = parsed }
        let note = uuids.isEmpty ? output.combinedOutput : output.stderr
        setStatus(command: parsed.displayString, text: note, isError: false)
        return true
    }

    /// The filters taskwarrior ANDs for a listing: the report's own, the typed one, and the
    /// context's unless the report opts out of it or an `rc.context` override changes it.
    private func listingFilters(report: String, typed: [String]) -> [[String]] {
        let config = environment?.config ?? [:]
        var sources = [ShellTokenizer.tokenize(config["report.\(report).filter"] ?? ""), typed]
        let ignoresContext = ["0", "no", "off", "false"].contains(config["report.\(report).context"]?.lowercased() ?? "")
        let overridden = typed.contains { $0.hasPrefix("rc.context") || $0.hasPrefix("rc:context") }
        if !ignoresContext, !overridden {
            sources.append(ShellTokenizer.tokenize(contextFilter))
        }
        return sources
    }

    private func runInBackground(_ runner: TaskRunner, arguments: [String], height: Int, extra: [String] = []) async -> Result<TaskResult, Error> {
        let overrides = ["rc.defaultwidth=\(max(columns, 40))", "rc.defaultheight=\(height)"] + extra
        return await Task.detached(priority: .userInitiated) {
            Result { try runner.run(arguments, overrides: overrides) }
        }.value
    }

    /// No page limit for reports, the window's rows for graphs (`DisplayPolicy.height`).
    private func height(for parsed: ParsedCommand) -> Int {
        DisplayPolicy.height(for: parsed, catalog: catalog, windowRows: max(rows, 10))
    }

    private func countMatches(filter: [String]) async -> Int? {
        guard let runner else { return nil }
        let quiet = TaskRunner(executable: runner.executable, baseOverrides: ["rc.verbose=nothing", "rc.confirmation=off"])
        let result = await Task.detached { try? quiet.run(filter + ["count"]) }.value
        guard let result, result.succeeded else { return nil }
        return Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Output lines of an internal command such as `_projects`, or nil if it failed.
    private func quietLines(_ arguments: [String]) async -> [String]? {
        guard let runner else { return nil }
        let quiet = TaskRunner(executable: runner.executable, baseOverrides: ["rc.verbose=nothing"])
        let result = await Task.detached { try? quiet.run(arguments) }.value
        guard let result, result.succeeded else { return nil }
        return result.stdout.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
    }

    private func refreshContextName() async {
        guard let runner else { return }
        if let names = await quietLines(["_context"]) { contexts = names }
        let quiet = TaskRunner(executable: runner.executable, baseOverrides: ["rc.verbose=nothing"])
        let result = await Task.detached { try? quiet.run(["_get", "rc.context"]) }.value
        guard let result, result.succeeded else { return }
        currentContext = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        // Read now rather than from the startup config, which a `context define` makes stale.
        // `_get` prints nothing for a missing key; `context.<name>` is the pre-2.6 spelling.
        var filter = ""
        if !currentContext.isEmpty, currentContext != "none" {
            for key in ["rc.context.\(currentContext).read", "rc.context.\(currentContext)"] where filter.isEmpty {
                let value = await Task.detached { try? quiet.run(["_get", key]) }.value
                filter = value?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
        }
        contextFilter = filter
    }

    // MARK: - Helpers

    /// The task a bare command acts on: the list's selection, or the task an `information`
    /// page shows; nil anywhere else, where a selection would be one the user can't see.
    private var targetUUID: String? {
        tasks != nil ? selectedUUID : shownTaskUUID
    }

    /// The one listed task a line's filter names: by its uuid, or by id while the list is shown
    /// (the text view's ids may have been renumbered since the last list).
    private func namedTask(_ parsed: ParsedCommand) -> TaskItem? {
        guard let named = ListLanding.targets(of: parsed.filter, in: listed), named.count == 1,
              let task = listed.first(where: { $0.uuid == named[0] }),
              tasks != nil || parsed.filter == [task.uuid] else { return nil }
        return task
    }

    /// The task an `information` line shows when it names one: a uuid (a vimango link's task
    /// need not be listed) or a listed task.
    private func shownTask(by parsed: ParsedCommand) -> String? {
        guard parsed.effectiveCommand(in: catalog)?.name == "information" else { return nil }
        if parsed.filter.count == 1, let only = parsed.filter.first, UUID(uuidString: only) != nil {
            return only.lowercased()
        }
        return namedTask(parsed)?.uuid
    }

    private func appendLog(command: String, text: String, isError: Bool) {
        let trimmed = text.trimmingCharacters(in: .newlines)
        log.append(LogEntry(command: command, runs: ANSIParser.parse(trimmed), isError: isError))
        if log.count > 400 { log.removeFirst(log.count - 400) }
        setStatus(command: command, text: trimmed, isError: isError)
    }

    private func setStatus(command: String, text: String, isError: Bool) {
        let plain = ANSIParser.plainText(ANSIParser.parse(text))
        let firstLine = plain.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        statusLine = firstLine.isEmpty ? command : "\(command)  →  \(firstLine)"
        statusIsError = isError
    }

    private func showMessage(_ text: String) {
        display = [StyledRun(text: text)]
        tasks = nil
        shownTaskUUID = nil
        displayIsTransient = false
        displayGeneration += 1
        displayIsRefresh = false
    }

    private func recomputeGeometry() {
        guard displaySize.width > 0 else { return }
        let metrics = TerminalFont.metrics(size: fontSize)
        let inset = TerminalTextView.inset
        // Legacy (always-visible) scrollers take width away from the text; overlay ones do not.
        let scrollerWidth = NSScroller.preferredScrollerStyle == .legacy
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        let usableWidth = displaySize.width - 2 * inset - scrollerWidth
        let newColumns = max(Int(usableWidth / metrics.charWidth) - 1, 20)
        let newRows = max(Int((displaySize.height - 2 * inset) / metrics.lineHeight), 5)
        guard newColumns != columns || newRows != rows else { return }
        let first = columns == 0
        let widthChanged = newColumns != columns
        columns = newColumns
        rows = newRows
        // Only graphs draw to the height; reports aren't page-limited.
        guard !first, let view = currentView, widthChanged || height(for: view) != 0 else { return }
        // Debounce window resizing / font zooming, then re-run the listing at the new size.
        geometryRefresh?.cancel()
        geometryRefresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.refreshCurrentView()
        }
    }
}
