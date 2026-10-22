import SwiftUI
import TaskwarriorCore

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            Group {
                if let tasks = model.tasks {
                    TaskListView(tasks: tasks, generation: model.displayGeneration, preserveScroll: model.displayIsRefresh)
                } else {
                    // Esc leaves a one-off such as `information` for the list it came from.
                    // Taskwarrior's colours assume a black terminal, so this view stays dark.
                    TerminalTextView(
                        runs: model.display,
                        generation: model.displayGeneration,
                        fontSize: model.fontSize,
                        preserveScroll: model.displayIsRefresh,
                        onCommandLine: { model.focusCommandField() },
                        onLeave: { model.leaveTransientDisplay() },
                        onHelp: { model.helpOpen = true }
                    )
                    .background(Color(nsColor: TerminalPalette.background))
                }
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                model.displaySizeChanged(size)
            }
            .background(DisplayFocus(request: model.displayFocusRequest, showsList: model.tasks != nil))

            // The log shows ANSI-coloured output too, so the bottom of the window stays dark
            // even when the list follows a light system appearance.
            VStack(spacing: 0) {
                Divider()
                LogPane()
                Divider()

                CommandField(
                    text: $model.commandText,
                    fontSize: model.fontSize,
                    history: model.history,
                    focusRequest: model.focusRequest,
                    onSubmit: { model.submit() },
                    onLeave: { model.focusDisplay() }
                )
                .padding(8)
            }
            .background(Color(nsColor: TerminalPalette.headerBackground))
            .environment(\.colorScheme, .dark)
        }
        .frame(minWidth: 520, minHeight: 320)
        .sheet(isPresented: $model.helpOpen, onDismiss: { model.focusDisplay() }) {
            HelpView { model.helpOpen = false }
        }
        .alert(
            model.pendingConfirmation?.title ?? "Confirm",
            isPresented: Binding(
                get: { model.pendingConfirmation != nil },
                set: { if !$0 { model.pendingConfirmation = nil } }
            ),
            presenting: model.pendingConfirmation
        ) { confirmation in
            Button("Cancel", role: .cancel) { model.focusDisplay() }
            Button("Run", role: .destructive) {
                confirmation.proceed()
                model.focusDisplay()
            }
        } message: { confirmation in
            Text(confirmation.message)
        }
    }
}

/// Command output and status: the most recent message is always visible in the
/// header row; expanding shows the scrollable history.
struct LogPane: View {
    @Environment(AppModel.self) private var model

    private var logFontSize: Double { max(model.fontSize - 1, 9) }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    model.logExpanded.toggle()
                } label: {
                    Image(systemName: model.logExpanded ? "chevron.down" : "chevron.right")
                        .foregroundStyle(Color(nsColor: TerminalPalette.dimForeground))
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
                .help(model.logExpanded ? "Hide output" : "Show output")

                Text(model.statusLine.isEmpty ? "Output" : model.statusLine)
                    .font(.system(size: logFontSize, design: .monospaced))
                    .foregroundStyle(model.statusIsError ? Color.red : Color(nsColor: TerminalPalette.dimForeground))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                // A sync's spinner is the cloud's.
                if model.isRunning, !model.isSyncing {
                    ProgressView().controlSize(.small)
                }
                if model.syncConfigured {
                    SyncButton(fontSize: logFontSize)
                }
                Picker("Display", selection: $model.displayMode) {
                    Text("List").tag(DisplayMode.list)
                    Text("Raw").tag(DisplayMode.text)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .help("Show reports as a task list or as taskwarrior's raw output")
                Text(model.currentContext.isEmpty || model.currentContext == "none" ? "no context" : "context: \(model.currentContext)")
                    .font(.system(size: logFontSize, design: .monospaced))
                    .foregroundStyle(Color(nsColor: TerminalPalette.dimForeground))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: TerminalPalette.headerBackground))

            if model.logExpanded {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(model.log) { entry in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("› " + entry.command)
                                        .font(.system(size: logFontSize, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(entry.isError ? Color.red : Color(nsColor: TerminalPalette.dimForeground))
                                    if !entry.runs.isEmpty {
                                        Text(TerminalStyle.attributedString(entry.runs, fontSize: logFontSize))
                                            .textSelection(.enabled)
                                    }
                                }
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(entry.id)
                            }
                        }
                        .padding(8)
                    }
                    .frame(height: 150)
                    .background(Color(nsColor: TerminalPalette.logBackground))
                    .onChange(of: model.log.count) {
                        if let last = model.log.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                    .onAppear {
                        if let last = model.log.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
    }

}

/// The cloud in the status bar: what a `task sync` would do (`SyncState`), as in taskchamp.
/// Orange with a count of tasks to send up, a down arrow when the server has changes, an
/// exclamation when the last sync failed; a spinner while syncing. Clicking runs `sync` like a
/// typed one. Its width never changes, so the bar doesn't shift as the count comes and goes.
struct SyncButton: View {
    @Environment(AppModel.self) private var model
    let fontSize: Double

    var body: some View {
        let state = model.syncState
        Button {
            model.run(line: "sync")
        } label: {
            HStack(spacing: 3) {
                ZStack {
                    Image(systemName: "icloud").hidden()
                    if model.isSyncing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: state.symbol)
                    }
                }
                ZStack(alignment: .leading) {
                    Text(verbatim: "99+").hidden()
                    if !model.isSyncing, let count = state.unsyncedTasks, count > 0 {
                        Text(verbatim: count > 99 ? "99+" : String(count))
                    }
                }
                .monospacedDigit()
            }
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundStyle(state.isDue && !model.isSyncing ? Color.orange : Color(nsColor: TerminalPalette.dimForeground))
        }
        .buttonStyle(.plain)
        .disabled(model.isRunning)
        .help(model.isSyncing ? "Syncing…" : state.summary)
    }
}
