import SwiftUI
import Observation
import TaskwarriorCore

struct LogEntry: Identifiable {
    let id = UUID()
    let command: String
    let runs: [StyledRun]
    let isError: Bool
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

    // MARK: Log / status
    private(set) var log: [LogEntry] = []
    /// One-line status shown in the output pane header (latest message from any command).
    private(set) var statusLine = ""
    private(set) var statusIsError = false
    var logExpanded: Bool { didSet { defaults.set(logExpanded, forKey: Keys.logExpanded) } }
    private(set) var currentContext = ""
    private(set) var isRunning = false
    var pendingConfirmation: Confirmation?

    // MARK: Input
    var commandText = ""
    private(set) var history: [String] { didSet { defaults.set(Array(history.suffix(500)), forKey: Keys.history) } }
    private(set) var focusRequest = 0

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

    private enum Keys {
        static let fontSize = "fontSize"
        static let logExpanded = "logExpanded"
        static let history = "history"
        static let taskExecutable = "taskExecutable"
    }

    init() {
        let stored = defaults.double(forKey: Keys.fontSize)
        fontSize = stored > 0 ? stored : Self.defaultFontSize
        logExpanded = defaults.object(forKey: Keys.logExpanded) as? Bool ?? true
        history = defaults.stringArray(forKey: Keys.history) ?? []
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
        runner = TaskRunner(executable: executable, baseOverrides: env.baseOverrides)

        // Wait briefly for the view to report its size so the first listing fits the window.
        for _ in 0..<25 where columns == 0 {
            try? await Task.sleep(for: .milliseconds(20))
        }
        // The initial view is whatever `task` alone shows (the user's default.command).
        enqueue(ParsedCommand.parse("", catalog: catalog), action: .replaceDisplay(remember: true))
    }

    // MARK: - Commands from the UI

    func submit() {
        let line = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        commandText = ""
        guard !line.isEmpty else { return }
        if history.last != line { history.append(line) }
        run(line: line)
    }

    func run(line: String) {
        guard runner != nil else {
            appendLog(command: line, text: "taskwarrior is not available.", isError: true)
            return
        }
        let parsed = ParsedCommand.parse(line, catalog: catalog)
        let action = DisplayPolicy.action(for: parsed, catalog: catalog)
        if case .refuse(let reason) = action {
            appendLog(command: parsed.displayString, text: reason, isError: true)
            return
        }
        let requirement = ConfirmationPolicy.requirement(for: parsed, catalog: catalog, bulkThreshold: environment?.bulkThreshold ?? 0)
        switch requirement {
        case .none:
            enqueue(parsed, action: action)
        case .always:
            enqueueWork { [weak self] in
                self?.ask(parsed, action: action, message: "Run “\(parsed.displayString)”?")
            }
        case .countAbove(let threshold):
            enqueueWork { [weak self] in
                guard let self else { return }
                let count = await self.countMatches(filter: parsed.filter)
                if let count, count > threshold {
                    let noun = count == 1 ? "task" : "tasks"
                    self.ask(parsed, action: action, message: "“\(parsed.displayString)” will affect \(count) \(noun).")
                } else if count == 0 {
                    // Let taskwarrior report "No matches" itself.
                    await self.execute(parsed, action: action)
                } else {
                    await self.execute(parsed, action: action)
                }
            }
        }
    }

    func refreshCurrentView() {
        guard let view = currentView else { return }
        enqueue(view, action: .replaceDisplay(remember: true))
    }

    func focusCommandField() { focusRequest += 1 }

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

    private func ask(_ parsed: ParsedCommand, action: DisplayAction, message: String) {
        let title = "Confirm \(parsed.effectiveCommand(in: catalog)?.name ?? "command")"
        if ProcessInfo.processInfo.environment["TASKWARRIOR_APP_DUMP"] == "1" {
            FileHandle.standardError.write(Data("confirm: \(title): \(message)\n".utf8))
        }
        pendingConfirmation = Confirmation(title: title, message: message) { [weak self] in
            self?.enqueue(parsed, action: action)
        }
    }

    private func enqueue(_ parsed: ParsedCommand, action: DisplayAction) {
        enqueueWork { [weak self] in await self?.execute(parsed, action: action) }
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

        let result = await runInBackground(runner, arguments: parsed.tokens)
        switch result {
        case .failure(let error):
            appendLog(command: parsed.displayString, text: error.localizedDescription, isError: true)
            return
        case .success(let output):
            switch action {
            case .replaceDisplay(let remember):
                displayIsRefresh = remember && currentView?.tokens == parsed.tokens
                display = ANSIParser.parse(output.primaryOutput)
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

    private func runInBackground(_ runner: TaskRunner, arguments: [String]) async -> Result<TaskResult, Error> {
        let geometry = ["rc.defaultwidth=\(max(columns, 40))", "rc.defaultheight=\(max(rows, 10))"]
        return await Task.detached(priority: .userInitiated) {
            Result { try runner.run(arguments, overrides: geometry) }
        }.value
    }

    private func countMatches(filter: [String]) async -> Int? {
        guard let runner else { return nil }
        let quiet = TaskRunner(executable: runner.executable, baseOverrides: ["rc.verbose=nothing", "rc.confirmation=off"])
        let result = await Task.detached { try? quiet.run(filter + ["count"]) }.value
        guard let result, result.succeeded else { return nil }
        return Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func refreshContextName() async {
        guard let runner else { return }
        let quiet = TaskRunner(executable: runner.executable, baseOverrides: ["rc.verbose=nothing"])
        let result = await Task.detached { try? quiet.run(["_get", "rc.context"]) }.value
        if let result, result.succeeded {
            currentContext = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // MARK: - Helpers

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
        columns = newColumns
        rows = newRows
        guard !first, currentView != nil else { return }
        // Debounce window resizing / font zooming, then re-run the listing at the new size.
        geometryRefresh?.cancel()
        geometryRefresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.refreshCurrentView()
        }
    }
}
